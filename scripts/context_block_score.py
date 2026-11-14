"""Score use of the "About this person" block on Evals/context-block-dev.jsonl: string checks, no judge.

    python3 scripts/context_block_score.py <cases.jsonl> name=<outputs.jsonl>... [-v]

Invented dev text; never trained on. A case passes when the output contains every `present` string
(case-sensitive: the corrected spelling or the habit's form, plus content that must survive) and none of
the `absent` strings (case-insensitive: the mis-heard form, or something that leaked from the block).
Run each model twice, with the block and without it: the "use it" kinds should pass only with the block,
the "leave it alone" kinds should pass both ways."""
import collections, json, sys

USE = ("words-fix", "before-fix", "edits-habit", "screen-fix", "mixed-fix", "style-habit")

def verdict(case, text):
    text = text.replace("\u2019", "'").replace("\u2018", "'"); low = text.lower()
    return [f"lost '{p}'" for p in case["present"] if p not in text] + \
           [f"has '{a}'" for a in case.get("absent", []) if a.lower() in low]

cases = [json.loads(line) for line in open(sys.argv[1])]
verbose = "-v" in sys.argv
for spec in (a for a in sys.argv[2:] if a != "-v"):
    name, path = spec.split("=", 1); out = {r["id"]: r["text"] for r in map(json.loads, open(path))}
    fails = {c["id"]: verdict(c, out.get(c["id"], "")) for c in cases}
    by = collections.defaultdict(lambda: [0, 0])
    for c in cases: by[c["kind"]][0] += not fails[c["id"]]; by[c["kind"]][1] += 1
    use = [c for c in cases if c["kind"] in USE]; leave = [c for c in cases if c["kind"] not in USE]
    ok = lambda group: sum(not fails[c["id"]] for c in group)
    print(f"{name}: uses the block {ok(use)} of {len(use)} | leaves it alone {ok(leave)} of {len(leave)}")
    print("  " + " ".join(f"{k} {a}/{b}" for k, (a, b) in by.items()))
    if verbose:
        for cid, why in fails.items():
            if why: print(f"  {cid}: {'; '.join(why)}")
