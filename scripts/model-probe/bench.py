"""Prefix-cached tool-call latency probe for small MLX models.

Usage: pip install mlx-lm (0.31.3 used); HF_HOME=<scratch> [MODE=json] python bench.py <hf-repo> [label]
MODE=json asks for compact one-line JSON instead of the model's native tool-call format.
Measures: load time, prefix prefill (uncached) time, per-request TTFT and total latency with
the ~1,500-word system prompt + 10 tool schemas cached, peak GPU memory, process RSS, and a
zero-shot tool-choice probe on 24 hand-written utterances (NOT an eval set).
"""
import copy, json, re, resource, statistics, sys, time

import mlx.core as mx
from mlx_lm import load
from mlx_lm.generate import generate_step
from mlx_lm.models.cache import make_prompt_cache
from mlx_lm.sample_utils import make_sampler

REPO = sys.argv[1]
LABEL = sys.argv[2] if len(sys.argv) > 2 else REPO
MAX_TOKENS = 96
SYSTEM = open("system.txt").read()
TOOLS = json.load(open("tools.json"))
CASES = json.load(open("cases.json"))
TOOL_NAMES = [t["function"]["name"] for t in TOOLS]


import os
MODE = os.environ.get("MODE", "native")
COMPACT = SYSTEM.replace("Respond with a single tool call in the required format and nothing else, or with the single word NONE.", "Respond with one line of JSON and nothing else: {\"tool\":\"<name>\",\"args\":{...}} with only the arguments you filled, or {\"tool\":\"none\"}.") + "\n\nTools (JSON schema):\n" + json.dumps([t["function"] for t in TOOLS])


def render(tok, user):
    if MODE == "json":
        msgs = [{"role": "system", "content": COMPACT}, {"role": "user", "content": user}]
        kw = dict(add_generation_prompt=True, tokenize=False)
    else:
        msgs = [{"role": "system", "content": SYSTEM}, {"role": "user", "content": user}]
        kw = dict(tools=TOOLS, add_generation_prompt=True, tokenize=False)
    try:
        return tok.apply_chat_template(msgs, enable_thinking=False, **kw)
    except TypeError:
        return tok.apply_chat_template(msgs, **kw)


def lcp(a, b):
    n = 0
    for x, y in zip(a, b):
        if x != y:
            break
        n += 1
    return n


def pct(xs, p):
    xs = sorted(xs)
    k = max(0, min(len(xs) - 1, int(round(p / 100 * (len(xs) - 1)))))
    return xs[k]


def parse_tool(text):
    t = text.strip()
    m = re.search(r'"tool"\s*:\s*"([a-zA-Z_]+)"', t)
    if m:
        return "NONE" if m.group(1).lower() == "none" else m.group(1)
    if t.upper().startswith("NONE"):
        return "NONE"
    m = re.search(r"<function=([a-zA-Z_]+)>", t)  # Qwen3.5 XML
    if m:
        return m.group(1)
    m = re.search(r'"name"\s*:\s*"([a-zA-Z_]+)"', t)  # JSON
    if m:
        return m.group(1)
    m = re.search(r"\[?\s*([a-zA-Z_]+)\s*\(", t)  # pythonic (LFM)
    if m and m.group(1) in TOOL_NAMES:
        return m.group(1)
    for n in TOOL_NAMES:
        if n in t:
            return n
    return "UNPARSED"


def run_request(model, tok, base_cache, suffix_tokens, sampler):
    cache = copy.deepcopy(base_cache)
    t0 = time.perf_counter()
    ttft = None
    out = []
    eos = set(getattr(tok, "eos_token_ids", []) or [tok.eos_token_id])
    for i, (token, _) in enumerate(
        generate_step(mx.array(suffix_tokens), model, prompt_cache=cache, max_tokens=MAX_TOKENS, sampler=sampler)
    ):
        token = int(token)
        if i == 0:
            ttft = time.perf_counter() - t0
        if token in eos:
            break
        out.append(token)
    total = time.perf_counter() - t0
    return ttft, total, len(out), tok.decode(out)


def main():
    t0 = time.perf_counter()
    model, tok = load(REPO)
    load_s = time.perf_counter() - t0
    sampler = make_sampler(temp=0.0)

    a = tok.encode(render(tok, "AAAA first probe"), add_special_tokens=False)
    b = tok.encode(render(tok, "zzzz other probe"), add_special_tokens=False)
    n_prefix = lcp(a, b)
    prefix = a[:n_prefix]

    # Uncached cost: prefill the whole prefix once (this is what Apple FM pays every call).
    def prefill():
        cache = make_prompt_cache(model)
        arr = mx.array(prefix)
        for i in range(0, len(prefix), 512):
            model(arr[i:i + 512][None], cache=cache)
            mx.eval([c.state for c in cache])
        return cache
    prefill()  # warm-up / kernel compile
    mx.reset_peak_memory()
    t0 = time.perf_counter()
    base_cache = prefill()
    prefill_s = time.perf_counter() - t0
    prefill_peak = mx.get_peak_memory() / 1e9
    mx.reset_peak_memory()

    # Warm-up (kernel compile) then timed runs.
    rows = []
    for rep in range(2):
        for c in CASES:
            full = tok.encode(render(tok, c["u"]), add_special_tokens=False)
            assert full[:n_prefix] == prefix, "prefix mismatch"
            suffix = full[n_prefix:]
            ttft, total, ntok, text = run_request(model, tok, base_cache, suffix, sampler)
            if rep == 1:
                rows.append(dict(case=c, ttft=ttft, total=total, ntok=ntok, suffix=len(suffix), text=text))

    peak_gb = mx.get_peak_memory() / 1e9
    rss_gb = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1e9  # bytes on macOS
    ok = 0
    fires_on_neg = 0
    negs = 0
    for r in rows:
        got = parse_tool(r["text"])
        want = r["case"]["tool"].split("|")
        r["got"] = got
        ok += got in want
        if "NONE" in want and "escalate_to_agent" not in want:
            negs += 1
            fires_on_neg += got in TOOL_NAMES  # a real tool call on a mention; prose/refusals are not fires
    pos = [r for r in rows if r["ntok"] > 3]
    ptots = [r["total"] * 1000 for r in pos]
    ttfts = [r["ttft"] * 1000 for r in rows]
    tots = [r["total"] * 1000 for r in rows]
    res = dict(
        label=LABEL, repo=REPO, load_s=round(load_s, 2), prefix_tokens=n_prefix,
        uncached_prefix_prefill_ms=round(prefill_s * 1000), prefill_tok_s=round(n_prefix / prefill_s),
        suffix_tokens_mean=round(statistics.mean(r["suffix"] for r in rows), 1),
        out_tokens_mean=round(statistics.mean(r["ntok"] for r in rows), 1),
        ttft_p50_ms=round(pct(ttfts, 50)), ttft_p95_ms=round(pct(ttfts, 95)),
        total_p50_ms=round(pct(tots, 50)), total_p95_ms=round(pct(tots, 95)),
        peak_gpu_prefill_gb=round(prefill_peak, 2), peak_gpu_request_gb=round(peak_gb, 2),
        weights_gb=round(sum(v.nbytes for _, v in __import__('mlx.utils', fromlist=['tree_flatten']).tree_flatten(model.parameters())) / 1e9, 2),
        cache_gb=round(sum(sum(x.nbytes for x in (c.state if isinstance(c.state, (list, tuple)) else [c.state]) if x is not None) for c in base_cache) / 1e9, 3),
        calls_n=len(pos), call_total_p50_ms=round(pct(ptots, 50)) if pos else None, call_total_p95_ms=round(pct(ptots, 95)) if pos else None,
        call_out_tokens_mean=round(statistics.mean(r['ntok'] for r in pos), 1) if pos else None,
        decode_tok_s=round(statistics.median((r['ntok'] - 1) / (r['total'] - r['ttft']) for r in pos)) if pos else None, max_rss_gb=round(rss_gb, 2),
        tool_choice_correct=f"{ok}/{len(rows)}", false_fires_on_negatives=f"{fires_on_neg}/{negs}",
    )
    print(json.dumps(res, indent=1))
    with open(f"out_{LABEL}.json", "w") as f:
        json.dump(dict(summary=res, rows=[{k: v for k, v in r.items() if k != "case"} | {"u": r["case"]["u"], "want": r["case"]["tool"]} for r in rows]), f, indent=1)


if __name__ == "__main__":
    main()
