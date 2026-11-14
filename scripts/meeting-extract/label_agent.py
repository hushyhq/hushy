"""Label meeting-extract chunks with Claude subagents instead of Codex: shard files out, answer files back in.

    PY=.build/finetune-venv/bin/python
    $PY scripts/meeting-extract/label_agent.py export --stage cal-test
    $PY scripts/meeting-extract/label_agent.py check  .build/public-data/meeting-extract/shards/cal-test/shard-007.answer.json
    $PY scripts/meeting-extract/label_agent.py ingest --stage cal-test
    $PY scripts/meeting-extract/label_agent.py status

export  writes shards/<stage>/shard-NNN.md (prompt v2 rules, then about 25 chunks) and shards/manifest.json.
        An agent reads one shard and writes shard-NNN.answer.json: {chunk id: [records]}, the Codex reply shape.
check   runs the validator on answer files and prints every dropped record with its reason; writes nothing.
ingest  validates answer files with the same filter_records as label_codex.py and appends rows to
        labels/<stage>-v2.jsonl. Ids already in that file are skipped, so a rerun is safe. Ids missing from an
        answer are reported, not treated as empty. Only public corpus text is ever exported.
status  per shard: answered or not, chunks already labelled.
"""
import argparse
import json
import sys
from collections import Counter
from pathlib import Path
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).parent))
from common import DATA_ROOT  # noqa: E402
from label_codex import (PROMPT_VERSION, RULES, append_row, filter_records, labelled_row,  # noqa: E402
                         load_rows, parse_reply, render_chunk)

SHARDS = DATA_ROOT / "shards"
MANIFEST = SHARDS / "manifest.json"
LABELS = DATA_ROOT / "labels"
FINAL = DATA_ROOT / "final"
GOLD_INPUTS = [FINAL / "gold-human.jsonl", FINAL / "held-r10d-overlap.jsonl"]
CHARS_PER_TOKEN = 3.5  # conservative: English transcripts run nearer 4
LABEL_SOURCE = f"sonnet subagent, prompt {PROMPT_VERSION}"
GOLD_TAG = "agent"

# The same stages and inputs as run_labels.sh. The text sent to an agent never includes gold records.
STAGES = {
    "cal-test": dict(input=GOLD_INPUTS, ids=LABELS / "cal-test.ids", tier="calibration"),
    "elitr": dict(input=[FINAL / "input-only.jsonl"], sources=["elitr"], tier="input-only"),
    "meetingbank": dict(input=[FINAL / "input-only.jsonl"], sources=["meetingbank"], tier="input-only"),
    "meetingbank-s300": dict(input=[FINAL / "input-only.jsonl"], sources=["meetingbank"],
                             ids=LABELS / "meetingbank-s300.ids", tier="input-only"),
    "qmsum": dict(input=[FINAL / "input-only.jsonl"], sources=["qmsum-committee"], tier="input-only"),
    "notsofar": dict(input=[FINAL / "input-only.jsonl", FINAL / "held-r10d-overlap.jsonl"], sources=["notsofar"],
                     tier="input-only"),
}

AGENT_HEAD = """You label meeting transcripts for training a small note-taking model. This file holds {n} transcript
chunks, listed below. For each chunk, list the records a careful minute-taker would write down. Read every chunk
yourself and judge it yourself: do not write a script that picks records, and do not read any other file in the
repository.

Answer file: {answer}
Write one JSON object to it: keys are the chunk ids exactly as given, values are lists of records. A chunk with
nothing to record gets []. Every chunk id in this file must be a key.

Reading: this file is long, and one Read call returns only part of it. Keep reading with offset and limit until you
reach the line "END OF SHARD". Label every chunk. Check the answer before you finish:
    {py} {script} check {answer}
It prints each record the validator would drop and why (most often a quote that is not copied character for
character from one transcript line). Fix the answer file and run check again until the drops are 0 or you are sure
a remaining drop is right. Then reply with one line: the answer path, chunks answered, records written.
"""


def stage_rows(stage: str) -> list:
    cfg = STAGES[stage]
    args = SimpleNamespace(input=cfg["input"], sources=cfg.get("sources"),
                           ids=cfg.get("ids"))
    rows = load_rows(args)
    return sorted(rows, key=lambda r: (r["source"], r["meeting_id"], r["chunk_index"]))


def estimate_tokens(text: str) -> int:
    return round(len(text) / CHARS_PER_TOKEN)


def pack(rows: list, chunks: int, max_tokens: int, overhead: int) -> list:
    """Consecutive rows (so a shard sees whole meetings) until the chunk count or the token budget is reached."""
    shards, current, used = [], [], overhead
    for row in rows:
        cost = estimate_tokens(render_chunk(row))
        if current and (len(current) >= chunks or used + cost > max_tokens):
            shards.append(current)
            current, used = [], overhead
        current.append(row)
        used += cost
    if current:
        shards.append(current)
    return shards


def shard_text(stage: str, number: int, rows: list) -> str:
    answer = SHARDS / stage / f"shard-{number:03d}.answer.json"
    head = AGENT_HEAD.format(n=len(rows), answer=answer, script=Path(__file__).resolve(),
                             py=DATA_ROOT.parents[1] / "finetune-venv" / "bin" / "python")
    listing = "Chunk ids in this file:\n" + "\n".join(f"- {r['id']}" for r in rows) + "\n"
    body = "\n".join(render_chunk(r) for r in rows)
    return f"{head}{RULES}\n{listing}\n{body}\n=== END OF SHARD ===\n"


def read_manifest() -> dict:
    return json.loads(MANIFEST.read_text()) if MANIFEST.exists() else {"shards": []}


def export(args) -> None:
    rows = stage_rows(args.stage)
    overhead = estimate_tokens(AGENT_HEAD + RULES) + 60 * 25
    shards = pack(rows, args.chunks, args.max_tokens, overhead)
    out_dir = SHARDS / args.stage
    out_dir.mkdir(parents=True, exist_ok=True)
    entries = []
    for number, shard_rows in enumerate(shards, 1):
        text = shard_text(args.stage, number, shard_rows)
        path = out_dir / f"shard-{number:03d}.md"
        path.write_text(text, encoding="utf-8")
        entries.append({"stage": args.stage, "shard": path.name, "path": str(path),
                        "answer_path": str(path.with_suffix("")) + ".answer.json", "chunks": len(shard_rows),
                        "tokens_estimate": estimate_tokens(text), "ids": [r["id"] for r in shard_rows]})
    for stale in out_dir.glob("shard-*.md"):
        if stale.name not in {e["shard"] for e in entries}:
            stale.unlink()
    manifest = read_manifest()
    manifest["shards"] = [e for e in manifest["shards"] if e["stage"] != args.stage] + entries
    manifest["shards"].sort(key=lambda e: (e["stage"], e["shard"]))
    manifest["note"] = (f"tokens_estimate is characters / {CHARS_PER_TOKEN}; prompt {PROMPT_VERSION}; "
                        "answers go to answer_path as {chunk id: [records]}")
    MANIFEST.write_text(json.dumps(manifest, indent=1))
    tokens = [e["tokens_estimate"] for e in entries]
    print(f"{args.stage}: {len(rows)} chunks in {len(entries)} shards, chunks/shard {min(e['chunks'] for e in entries)}"
          f"-{max(e['chunks'] for e in entries)}, tokens/shard {min(tokens)}-{max(tokens)} (estimate)")


def done_ids(out: Path) -> set:
    return {json.loads(line)["id"] for line in open(out, encoding="utf-8")} if out.exists() else set()


def load_answer(path: Path):
    if not path.exists():
        return None, "no answer file"
    parsed = parse_reply(path.read_text(encoding="utf-8"))
    return (parsed, None) if parsed is not None else (None, "answer is not a JSON object")


def process_answer(path: Path, rows_by_id: dict, entry: dict, done: set, out: Path, args, totals: Counter) -> None:
    parsed, problem = load_answer(path)
    if problem:
        print(f"{path.name}: {problem}")
        totals["bad_answers"] += 1
        return
    missing = [i for i in entry["ids"] if i not in parsed]
    unknown = [i for i in parsed if i not in entry["ids"]]
    skipped = [i for i in entry["ids"] if i in parsed and i in done]
    for chunk_id in entry["ids"]:
        if chunk_id not in parsed or chunk_id in done:
            continue
        row = rows_by_id[chunk_id]
        labelled = labelled_row(row, parsed[chunk_id], args.label_source, GOLD_TAG, STAGES[entry["stage"]]["tier"],
                                {"shard": entry["shard"]})
        stats = labelled["notes"]["labeller"]
        if args.dry_run or args.verbose:
            for d in stats["dropped_records"]:
                print(f"  DROP {chunk_id} {d['reason']}: {json.dumps(d['record'], ensure_ascii=False)[:260]}")
        else:
            append_row(out, labelled)
            done.add(chunk_id)
        totals["rows"] += 1
        totals["records"] += len(labelled["output"])
        totals["raw_records"] += stats["raw_records"]
        totals["drops"] += sum(stats["dropped"].values())
        totals.update({f"drop:{k}": v for k, v in stats["dropped"].items()})
    totals["missing_ids"] += len(missing)
    totals["unknown_ids"] += len(unknown)
    totals["already_labelled"] += len(skipped)
    print(f"{path.name}: {len(entry['ids']) - len(missing)} of {len(entry['ids'])} chunks answered"
          + (f", missing {missing}" if missing else "") + (f", unknown {unknown}" if unknown else "")
          + (f", {len(skipped)} already labelled" if skipped else ""))


def answer_files(args) -> list:
    if args.answers:
        return [Path(p).resolve() for p in args.answers]
    return sorted((SHARDS / args.stage).glob("shard-*.answer.json"))


def ingest(args) -> int:
    manifest = {(e["stage"], e["shard"]): e for e in read_manifest()["shards"]}
    totals, rows_cache, dones = Counter(), {}, {}
    for path in answer_files(args):
        stage, shard = path.parent.name, path.name.replace(".answer.json", ".md")
        entry = manifest.get((stage, shard))
        if entry is None:
            print(f"{path}: not in the manifest (run export first)")
            totals["bad_answers"] += 1
            continue
        if stage not in rows_cache:
            rows_cache[stage] = {r["id"]: r for r in stage_rows(stage)}
            dones[stage] = done_ids(LABELS / f"{stage}-{PROMPT_VERSION}.jsonl")
        out = LABELS / f"{stage}-{PROMPT_VERSION}.jsonl"
        out.parent.mkdir(exist_ok=True)
        process_answer(path, rows_cache[stage], entry, dones[stage], out, args, totals)
    summary = {k: v for k, v in sorted(totals.items())}
    print(("DRY RUN, nothing written. " if args.dry_run else "") + json.dumps(summary))
    return 1 if totals["bad_answers"] else 0


def status(args) -> None:
    for entry in read_manifest()["shards"]:
        answer = Path(entry["answer_path"])
        done = done_ids(LABELS / f"{entry['stage']}-{PROMPT_VERSION}.jsonl")
        labelled = sum(i in done for i in entry["ids"])
        print(f"{entry['stage']:11} {entry['shard']}  {entry['chunks']:2} chunks  ~{entry['tokens_estimate']:6} tokens  "
              f"answer {'yes' if answer.exists() else 'no ':3}  labelled {labelled}/{entry['chunks']}")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="mode", required=True)
    ex = sub.add_parser("export")
    ex.add_argument("--stage", required=True, choices=sorted(STAGES))
    ex.add_argument("--chunks", type=int, default=25, help="most chunks per shard")
    ex.add_argument("--max-tokens", type=int, default=75000, help="most estimated tokens per shard")
    ing = sub.add_parser("ingest")
    ing.add_argument("--stage", choices=sorted(STAGES))
    ing.add_argument("--answers", nargs="*", help="answer files; default all answers of --stage")
    chk = sub.add_parser("check")
    chk.add_argument("answers", nargs="+", help="answer files to validate; nothing is written")
    for p in (ing, chk):
        p.add_argument("--label-source", default=LABEL_SOURCE)
        p.add_argument("--dry-run", action="store_true")
        p.add_argument("--verbose", action="store_true")
    sub.add_parser("status")
    args = ap.parse_args()
    if args.mode == "export":
        export(args)
        return 0
    if args.mode == "status":
        status(args)
        return 0
    if args.mode == "check":
        args.dry_run, args.stage = True, None
    elif not (args.stage or args.answers):
        ap.error("give --stage or --answers")
    return ingest(args)


if __name__ == "__main__":
    sys.exit(main())
