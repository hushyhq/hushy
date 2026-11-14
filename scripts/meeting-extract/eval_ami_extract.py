"""Score the meeting-extract adapter on the AMI scorecard sets with the existing scorer, no Swift change.

    PY=.build/finetune-venv/bin/python
    $PY scripts/meeting-extract/eval_ami_extract.py generate --model <mlx model dir> [--adapter <mlx adapter dir>] \
        --set test --out records-test.json [--limit 1]
    $PY scripts/meeting-extract/eval_ami_extract.py digest --records records-test.json --set test --out digest-test.json
    python3 scripts/meeting-eval/score_public.py --gold <meet-model>/.build/meetings-hillclimb/sets/ami-test.json \
        --run extract=digest-test.json

generate: chunk each meeting like the training rows (about 1,800 words at turn boundaries), prompt with build_sft's
system and user turns, decode greedily with mlx_lm, parse {"records": [...]}. Records are kept only if the quote is
copied from one turn, the owner is a speaker label and the due words occur in the chunk (the app's DigestGrounding
rules), so the adapter is scored on what the app would show.
digest: records -> the `murmur-eval meeting --out` shape that score_public.py reads (summary with "- Decided:" lines,
actionItems "Owner: task - due", actionDetails). open_question and change records go to the summary as plain bullets;
the scorer counts decisions and actions only.
AMI scorecard transcripts carry no timestamps, while the AMI and ICSI training rows do; the eval prompt follows the
scorecard, so this is a small known mismatch.
"""
import argparse
import json
import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from build_sft import SYSTEM, user_turn  # noqa: E402
from common import REPO_ROOT, Turn, chunk_turns, render  # noqa: E402

SETS = Path(os.environ.get("HUSHY_MEETING_SETS", REPO_ROOT / ".build/meetings-hillclimb/sets"))
MAX_NEW_TOKENS = 1500
KIND_OF_MEETING = "product design team meeting (role-play scenario)"


def meetings(name: str) -> list:
    return json.loads((SETS / f"ami-{name}.json").read_text())["meetings"]


def turns_of(meeting: dict) -> list:
    out = []
    for line in meeting["transcript"].split("\n"):
        speaker, sep, text = line.partition(": ")
        if sep and text.strip():
            out.append(Turn(speaker, None, text.strip()))
    return out


def chunk_rows(meeting: dict) -> list:
    speakers = sorted({p["label"] for p in meeting["people"]})
    chunks = chunk_turns(turns_of(meeting))
    return [{"input": {"meeting": {"title": meeting["title"], "kind": KIND_OF_MEETING, "speakers": speakers,
                                   "minutes": int(meeting["minutes"]), "chunk": f"{i} of {len(chunks)}"},
                       "transcript": render(chunk)}}
            for i, chunk in enumerate(chunks, 1)]


def grounded(record: dict, transcript: str, speakers: list) -> bool:
    lines = transcript.split("\n")
    if not any(record.get("quote") and record["quote"] in line for line in lines):
        return False
    if record.get("owner") is not None and record["owner"] not in speakers:
        return False
    return record.get("due") is None or record["due"].lower() in transcript.lower()


def parse_records(text: str) -> list:
    start, end = text.find("{"), text.rfind("}")
    try:
        records = json.loads(text[start:end + 1])["records"]
    except (ValueError, KeyError, TypeError):
        return []
    return [r for r in records if isinstance(r, dict) and r.get("kind") in ("decision", "action", "open_question", "change")]


def generate(args) -> None:
    from mlx_lm import generate as mlx_generate, load
    from mlx_lm.sample_utils import make_sampler
    model, tokenizer = load(args.model, adapter_path=args.adapter)
    out, started = [], time.time()
    for meeting in meetings(args.set)[:args.limit]:
        kept, dropped, raw_count, begun = [], [], 0, time.time()
        for row in chunk_rows(meeting):
            prompt = tokenizer.apply_chat_template(
                [{"role": "system", "content": SYSTEM}, {"role": "user", "content": user_turn(row)}],
                tokenize=False, add_generation_prompt=True, enable_thinking=False)
            text = mlx_generate(model, tokenizer, prompt=prompt, max_tokens=MAX_NEW_TOKENS, sampler=make_sampler(temp=0.0))
            records = parse_records(text)
            raw_count += len(records)
            speakers = row["input"]["meeting"]["speakers"]
            for r in records:
                (kept if grounded(r, row["input"]["transcript"], speakers) else dropped).append(r)
        out.append({"id": meeting["id"], "records": kept, "dropped": dropped, "raw_records": raw_count, "seconds": round(time.time() - begun, 1)})
        print(f"{meeting['id']}: {len(kept)} of {raw_count} records grounded, {out[-1]['seconds']} s", flush=True)
    Path(args.out).write_text(json.dumps({"model": args.model, "adapter": args.adapter, "meetings": out}, indent=1))
    print(f"wrote {args.out} in {time.time() - started:.0f} s")


def digest_of(entry: dict, meeting: dict) -> dict:
    by_kind = {k: [r for r in entry["records"] if r["kind"] == k] for k in ("decision", "action", "open_question", "change")}
    summary = [f"- {r['text']}" for r in by_kind["open_question"] + by_kind["change"]]
    summary += [f"- Decided: {r['text']}" for r in by_kind["decision"]]
    details = [{"owner": r.get("owner") or "", "task": r["text"], "due": r.get("due") or "", "quote": r["quote"]}
               for r in by_kind["action"]]
    items = [f"{d['owner']}: {d['task']}" + (f" — {d['due']}" if d["due"] else "") if d["owner"] else d["task"]
             for d in details]
    return {"id": meeting["id"], "title": meeting["title"], "minutes": meeting["minutes"], "words": meeting["words"],
            "summary": "\n".join(summary), "actionItems": items, "actionDetails": details,
            "calls": len(chunk_rows(meeting)), "milliseconds": entry.get("seconds", 0) * 1000, "note": "meeting-extract adapter"}


def digest(args) -> None:
    entries = {m["id"]: m for m in json.loads(Path(args.records).read_text())["meetings"]}
    gold = [m for m in meetings(args.set) if m["id"] in entries]
    Path(args.out).write_text(json.dumps([digest_of(entries[m["id"]], m) for m in gold], indent=1))
    print(f"wrote {args.out}: {len(gold)} meetings")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    g = sub.add_parser("generate")
    g.add_argument("--model", required=True)
    g.add_argument("--adapter")
    g.add_argument("--set", choices=["dev", "test", "long"], default="test")
    g.add_argument("--out", required=True)
    g.add_argument("--limit", type=int)
    g.set_defaults(fn=generate)
    d = sub.add_parser("digest")
    d.add_argument("--records", required=True)
    d.add_argument("--set", choices=["dev", "test", "long"], default="test")
    d.add_argument("--out", required=True)
    d.set_defaults(fn=digest)
    args = ap.parse_args()
    args.fn(args)


if __name__ == "__main__":
    main()
