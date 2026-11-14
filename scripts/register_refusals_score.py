#!/usr/bin/env python3
"""Scores Evals/register-refusals-dev.jsonl against an `murmur-eval intent-app` output.

    python3 -I scripts/register_refusals_score.py --cases Evals/register-refusals-dev.jsonl --run out.jsonl [--show]

Per row: `ok` when every `must_contain` substring is in the pasted text and no `must_not_contain` one is; `register` says
whether the register answer was used (not asked again without the line: `stages[0].registerDropped` false) and whether
the row ended on the model's answer at all. Prints counts per kind; with --show, every failing row. Invented text only.
"""
import argparse
import json


def read_jsonl(path):
    with open(path, encoding="utf-8") as handle:
        return [json.loads(line) for line in handle if line.strip()]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--cases", required=True)
    parser.add_argument("--run", required=True)
    parser.add_argument("--show", action="store_true")
    args = parser.parse_args()
    cases = {row["id"]: row for row in read_jsonl(args.cases)}
    kinds = {}
    for row in read_jsonl(args.run):
        case = cases.get(row["id"])
        if case is None:
            continue
        text = row["text"].lower()
        ok = all(word in text for word in case.get("must_contain", [])) and not any(
            word in text for word in case.get("must_not_contain", []))
        stage = row["stages"][0] if row.get("stages") else {}
        registered = row.get("usedModel") and not stage.get("registerDropped")
        tally = kinds.setdefault(case["kind"], {"rows": 0, "ok": 0, "register_kept": 0, "model_used": 0})
        tally["rows"] += 1
        tally["ok"] += ok
        tally["register_kept"] += bool(registered)
        tally["model_used"] += bool(row.get("usedModel"))
        if args.show and not ok:
            print("FAIL", row["id"], "|", row["text"].replace("\n", " / "))
    for kind, tally in sorted(kinds.items()):
        print(f"{kind:11} rows={tally['rows']:3} ok={tally['ok']:3} register_answer_kept={tally['register_kept']:3} model_used={tally['model_used']:3}")


if __name__ == "__main__":
    main()
