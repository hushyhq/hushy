#!/usr/bin/env python3
"""Builds the readable side-by-side file for the pilot (typed, spoken, checks), plus the funnel counts.

    python3 scripts/retrain_pilot_report.py --typed P.typed.jsonl --spoken P.spoken.jsonl --meaning P.meaning.jsonl \\
        --out Evals/runs/retrain/pilot60.md --scratch-dir DIR
Groups, rules drafts and per-group pieces are not in it: they need the app's own code (see the last section).
"""

import argparse
import json
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))

import api_judge  # noqa: E402
import api_judge_guard as guard  # noqa: E402


def stage_of(row):
    """The first step a passage fell out at, or 'kept'."""
    if row["plan_problems"]:
        return "spoken_plan"
    if row["failed_checks"]:
        return "spoken_checks"
    status = row["meaning"]["status"]
    return "kept" if status == "agree" else ("meaning_missing" if status == "no_second_typed" else "meaning")


def funnel(typed_rows, spoken_rows, meaning_rows):
    kept_typed = [r for r in typed_rows if not r["problems"]]
    by_id = {r["id"]: r for r in meaning_rows}
    stages = [stage_of(r) for r in by_id.values()]
    return {"planned": len(typed_rows), "typed_kept": len(kept_typed), "spoken_written": len(spoken_rows),
            "fell_out_spoken_plan": stages.count("spoken_plan"), "fell_out_spoken_checks": stages.count("spoken_checks"),
            "fell_out_meaning": stages.count("meaning"), "no_second_typed": stages.count("meaning_missing"),
            "kept_after_step_3": stages.count("kept")}


def block(row):
    slot = row["slot"]
    lines = [f"### {row['id']} · {slot['kind']} · {slot['profile']} · {slot['surface']} · "
             f"{row['spoken_words']} spoken words · planted: {', '.join(slot['plants']) or 'none'}",
             f"status: **{stage_of(row)}**", "", "typed:", "", "> " + row["typed"].replace("\n\n", "\n>\n> "), "",
             "spoken:", "", "> " + row["spoken"], ""]
    if row["plants"]:
        lines += ["planted corrections: " + "; ".join(
            f"{p['kind']}: \"{p['said_first']}\" -> \"{p['ended_on']}\"" for p in row["plants"]), ""]
    if row["plan_problems"] or row["failed_checks"]:
        lines += [f"plan findings: {row['plan_problems'] or 'none'}; failed relation checks: "
                  f"{row['failed_checks'] or 'none'}", ""]
    if row["meaning"]["status"] != "agree":
        lines += [f"meaning check: {row['meaning']['status']} {row['meaning']['problems']} "
                  f"{json.dumps(row['meaning'].get('detail', {}))}", ""]
        if row.get("second_typed"):
            lines += ["typed again from the spoken text alone:", "", "> " + row["second_typed"].replace("\n\n", "\n>\n> "), ""]
    return lines


def render(typed_rows, spoken_rows, meaning_rows, cost):
    counts = funnel(typed_rows, spoken_rows, meaning_rows)
    out = ["# Pilot: typed first, then spoken (steps 1 to 3 of 7)", "",
           "Invented text. Written by the pilot scripts; nothing here comes from a real person.", "",
           "## Counts at each step", "", "```", json.dumps(counts, indent=1), "```", "", f"API spend so far: {cost}", "",
           "## Not done: groups, rules drafts, per-group pieces", "",
           "The app cuts a dictation into groups with `TextSegmentation.groups` and builds each group's rules draft "
           "with `TextCleaner`. No command prints the groups (with each group's `continuesSentence` flag) and "
           "their rules drafts as data without running the language model; `murmur-eval try` prints group texts "
           "as a Swift array and calls the model, and `finetune prepare` gives a rules draft for text it is handed "
           "but does not cut. Writing the cuts in Python would be a guess, so steps 4 to 6 (groups, per-group "
           "targets, the group-level checks, the production guard verdicts) are not here.", "",
           "## Passages", ""]
    for row in meaning_rows:
        out += block(row)
    return "\n".join(out) + "\n"


def main(argv=None):
    cli = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    cli.add_argument("--typed", required=True)
    cli.add_argument("--spoken", required=True)
    cli.add_argument("--meaning", required=True)
    cli.add_argument("--out", required=True)
    cli.add_argument("--cost", default="see the ledger")
    cli.add_argument("--scratch-dir", action="append", default=[])
    args = cli.parse_args(argv)
    scratch = guard.scratch_roots(args.scratch_dir)
    typed, spoken, meaning = (api_judge.read_json_or_lines(guard.safe_input(p, scratch))
                              for p in (args.typed, args.spoken, args.meaning))
    target = guard.safe_output(args.out, scratch)
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(render(typed, spoken, meaning, args.cost), encoding="utf-8")
    print(json.dumps(funnel(typed, spoken, meaning)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
