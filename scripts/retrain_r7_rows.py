#!/usr/bin/env python3
"""Round 7 rows: read hand-written source files, screen them, and apply the app's own output guard.

    retrain_r7_rows.py parse  --src DIR --out DIR      src/*.txt -> rows.jsonl, guard-input.jsonl
    retrain_r7_rows.py filter --out DIR [--verdicts F] guard verdicts -> cases.jsonl, labels.jsonl, round7-rows.jsonl

Source files are plain text, one row per block, invented by hand (nothing is copied from any benchmark or probe):

    S: the spoken side, lowercase and unpunctuated like a recogniser's output
    T: what the person meant, as typed; a literal \\n in T is a line break

File names set the kind: a* sound-alikes and unknown words, b* number corrections, c* prompts for AI apps,
d* long-range corrections. `#` lines are comments. The guard verdicts come from the test-only harness
`IntentTargetGuardCheckTests` (see docs/retrain/round7.md); a target the app's guard would refuse is dropped.
"""
import argparse
from collections import Counter
import json
from pathlib import Path
import re
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import retrain_public_screen as screening  # noqa: E402

KINDS = {"a": "sound-alike", "b": "number-correction", "c": "ai-prompt", "d": "long-range"}
ROW_SYSTEM_PREFIX = "Write what the speaker meant"


def parse_file(path):
    """Blocks start at an `S:` line. A `T:` line follows; its text runs to the next `S:` line, so a blank line
    inside the target is a paragraph break, and a literal \\n is a line break too."""
    rows, spoken, target = [], None, None
    def close():
        if spoken is None:
            return
        text = "\n".join(target).strip() if target is not None else ""
        if not spoken or not text:
            raise ValueError(f"{path.name}: block needs both S and T near {spoken[:60]!r}")
        rows.append({"spoken": spoken, "target": text.replace("\\n", "\n")})
    for line in path.read_text(encoding="utf-8").splitlines():
        if line.startswith("#") and target is None:
            continue
        if line.startswith("S: "):
            close()
            spoken, target = line[3:].strip(), None
        elif line.startswith("T: ") and spoken is not None and target is None:
            target = [line[3:].rstrip()]
        elif target is not None:
            target.append(line.rstrip())
        elif line.strip():
            raise ValueError(f"{path.name}: unexpected line {line[:60]!r}")
    close()
    return rows


def probe_words(paths):
    """Every word or phrase the frozen misheard probe hears wrongly (its `heard` field), lower-cased."""
    found = set()
    for path in paths:
        for row in read_jsonl(path):
            if row.get("heard"):
                found.add(row["heard"].lower())
    return sorted(found)


def mentions(text, phrases):
    flat = " " + re.sub(r"[^a-z0-9']+", " ", text.lower()) + " "
    return [p for p in phrases if " " + p + " " in flat]


def parse(src, out, probes=()):
    """A row is dropped when its spoken side contains a word or phrase the frozen misheard probe hears wrongly (the
    probe is held out: not the same mishearing in another sentence either; a common word the probe also uses, such as
    "flower", costs the rows that say it). The number and prompt probes have no such words;
    the 8-word overlap index at assemble time covers their sentences."""
    watched = probe_words(probes)
    rows, seen, screened_out = [], set(), []
    counts, dropped = Counter(), Counter()
    for path in sorted(Path(src).glob("*.txt")):
        kind = path.name[0]
        if kind not in KINDS:
            raise ValueError(f"{path.name}: file name must start with a, b, c or d")
        for item in parse_file(path):
            key = re.sub(r"\W+", " ", item["spoken"].lower()).strip()
            if key in seen:
                dropped["duplicate_spoken"] += 1
                continue
            seen.add(key)
            reason = screening.label_reason(item["spoken"], item["target"])
            hit = mentions(item["spoken"], watched)
            if hit:
                reason = "probe_word"
                item = {**item, "probe_words": hit}
            if reason:
                dropped[reason] += 1
                screened_out.append({"kind": KINDS[kind], "reason": reason, **item})
                continue
            counts[kind] += 1
            rows.append({"id": f"r7{kind}{counts[kind]:03d}", "kind": KINDS[kind], **item})
    out = Path(out)
    out.mkdir(parents=True, exist_ok=True)
    write_jsonl(out / "rows.jsonl", rows)
    write_jsonl(out / "screened-out.jsonl", screened_out)
    write_jsonl(out / "guard-input.jsonl", [{"id": r["id"], "spoken": r["spoken"], "target": r["target"]} for r in rows])
    print(json.dumps({"parsed": len(rows), "by_kind": {KINDS[k]: n for k, n in sorted(counts.items())},
                      "dropped_before_guard": dict(dropped)}))


def write_jsonl(path, rows):
    path.write_text("".join(json.dumps(r, ensure_ascii=False, separators=(",", ":")) + "\n" for r in rows),
                    encoding="utf-8")


def read_jsonl(path):
    return [json.loads(line) for line in Path(path).read_text(encoding="utf-8").splitlines() if line.strip()]


def message_row(system, row):
    return {"id": f"{row['id']}-intent0", "passage": f"intent:{row['id']}", "arm": "intent", "source": "intent_rewrite",
            "messages": [{"role": "system", "content": system},
                         {"role": "user", "content": f"Transcript: {row['spoken']}\nOutput:"},
                         {"role": "assistant", "content": json.dumps({"text": row["target"]}, ensure_ascii=False,
                                                                       separators=(",", ":"))}]}


def filter_rows(out, verdicts_path, system_path):
    out = Path(out)
    rows = read_jsonl(out / "rows.jsonl")
    verdicts = {v["id"]: v for v in read_jsonl(verdicts_path)} if verdicts_path else {}
    kept, refused = [], []
    for row in rows:
        verdict = verdicts.get(row["id"])
        if verdict is None and verdicts_path:
            raise ValueError(f"no guard verdict for {row['id']}")
        if verdict and verdict["verdict"] != "accepted":
            refused.append({**row, "reason": verdict["reason"]})
        else:
            kept.append(row)
    by_reason = Counter(r["reason"] for r in refused)
    by_kind_reason = {}
    for r in refused:
        by_kind_reason.setdefault(r["kind"], Counter())[r["reason"]] += 1
    write_jsonl(out / "refused.jsonl", refused)
    write_jsonl(out / "cases.jsonl", [{"id": r["id"], "spoken": r["spoken"], "meeting": r["id"], "licence": "own invented rows"}
                                            for r in kept])
    write_jsonl(out / "labels.jsonl", [{"id": r["id"], "text": r["target"]} for r in kept])
    if system_path:
        system = Path(system_path).read_text(encoding="utf-8")
        write_jsonl(out / "round7-rows.jsonl", [message_row(system, r) for r in kept])
    print(json.dumps({"rows": len(rows), "kept": len(kept), "refused": len(refused),
                      "refused_by_reason": dict(by_reason.most_common()),
                      "kept_by_kind": dict(Counter(r["kind"] for r in kept)),
                      "refused_by_kind": {k: dict(v) for k, v in by_kind_reason.items()}}))


def main(argv=None):
    cli = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    cli.add_argument("command", choices=["parse", "filter"])
    cli.add_argument("--src", help="parse: folder of a*.txt, b*.txt, c*.txt, d*.txt")
    cli.add_argument("--out", required=True, help="folder for rows.jsonl, guard-input.jsonl and the filtered files")
    cli.add_argument("--probe-words", nargs="*", help="parse: misheard probe file(s); rows using a word it tests are dropped")
    cli.add_argument("--verdicts", help="filter: JSONL from the guard harness (id, verdict, reason)")
    cli.add_argument("--system", help="filter: file holding the exact system prompt of the base data's intent rows")
    args = cli.parse_args(argv)
    try:
        if args.command == "parse":
            if not args.src:
                cli.error("parse needs --src")
            parse(args.src, args.out, args.probe_words or ())
        else:
            filter_rows(args.out, args.verdicts, args.system)
    except (ValueError, OSError) as error:
        sys.exit(f"error: {error}")


if __name__ == "__main__":
    main()
