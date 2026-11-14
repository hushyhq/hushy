#!/usr/bin/env python3
"""Speech-first pilot, steps a to d: notes, then speech from the notes, (typed-writer-v2 in between), then the
independent check of the typed text against the notes. Groups and per-group targets are retrain_groups.py.

    python3 scripts/retrain_speech.py plan   --out PLAN
    python3 scripts/retrain_speech.py notes  --plan PLAN --out P --scratch-dir D --invented-or-public --max-dollars 2
    python3 scripts/retrain_speech.py speech --notes P.notes.jsonl --pool POOL --out P --max-dollars 3
    python3 scripts/retrain_writer.py write --passages P.for_writer.jsonl --out P.w ...      # typed-writer-v2
    python3 scripts/retrain_speech.py facts  --speech P.speech.jsonl --writer P.w --out P
"""

import argparse
import json
from pathlib import Path
import re
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))

import api_judge  # noqa: E402
import api_judge_client as client_module  # noqa: E402
import api_judge_guard as guard  # noqa: E402
import retrain_pilot as pilot  # noqa: E402
import retrain_pilot_steps as pilot_steps  # noqa: E402
import retrain_speech_plan as planner  # noqa: E402
import retrain_speech_steps as steps  # noqa: E402
import retrain_writer as writer  # noqa: E402
from api_judge_guard import GuardError  # noqa: E402

NOTES_BRIEF = guard.EVALS / "judge" / "SPEECH-NOTES-INSTRUCTIONS.md"
SPOKEN_BRIEF = guard.EVALS / "judge" / "SPEECH-SPOKEN-INSTRUCTIONS.md"


def notes_problems(slot, notes):
    wanted = {steps.FACT_KIND_FOR_FLAG[k] for k, on in slot["facts"].items() if on}
    got = {f["kind"] for f in notes["facts"]}
    found = [f"notes:missing_fact_kind:{k}" for k in sorted(wanted - got)]
    found += [f"notes:unwanted_fact_kind:{k}" for k in sorted(got - wanted - {"name", "file"})]
    if len(notes["points"]) > slot["points"] + 2:
        found.append("notes:too_many_points")
    return found


def run_notes(args):
    scratch = guard.scratch_roots(args.scratch_dir)
    pilot.check_run_flags(args)
    slots = pilot.read_lines(args.plan, scratch)[: args.limit or None]
    outcome = pilot.call_step(args, scratch, slots, steps.notes_card, steps.notes_schema(), steps.validate_notes,
                              steps.NotesRunner, NOTES_BRIEF, "Write the notes.")
    if outcome is None:
        return 0
    results, dollars, fatal = outcome
    rows, failed = [], []
    for slot, result in zip(slots, results):
        if not result["written"]:
            failed.append({"id": slot["id"], "status": result["status"], "error": result["error"]})
            continue
        notes = result["written"]
        rows.append({"id": slot["id"], "slot": slot, "notes": notes, "problems": notes_problems(slot, notes),
                     "dollars": round(result["usage"]["dollars"], 6)})
    pilot.write_lines(guard.safe_output(f"{args.out}.notes.jsonl", scratch), rows)
    pilot.write_lines(guard.safe_output(f"{args.out}.notes_failed.jsonl", scratch), failed)
    kept = [r for r in rows if not r["problems"]]
    print(f"notes: {len(slots)} planned, {len(rows)} written, {len(failed)} call failures, {len(kept)} kept; ${dollars:.4f}")
    return 2 if fatal else 0


def run_speech(args):
    scratch = guard.scratch_roots(args.scratch_dir)
    pilot.check_run_flags(args)
    pool = pilot.read_lines(args.pool, scratch)
    rows_in = [r for r in pilot.read_lines(args.notes, scratch) if not r["problems"]][: args.limit or None]
    for row in rows_in:
        row["exemplars"] = steps.pick_exemplars(pool, row["slot"]["seed"])
    outcome = pilot.call_step(args, scratch, rows_in, lambda r: steps.spoken_card(r["slot"], r["notes"], r["exemplars"]),
                              steps.spoken_schema(), steps.validate_spoken, steps.SpokenRunner, SPOKEN_BRIEF,
                              "Write the spoken version.")
    if outcome is None:
        return 0
    results, dollars, fatal = outcome
    rows, failed = [], []
    for source, result in zip(rows_in, results):
        if not result["written"]:
            failed.append({"id": source["id"], "status": result["status"], "error": result["error"]})
            continue
        spoken, plants = result["written"]["spoken"], result["written"]["plants"]
        problems = pilot_steps.spoken_problems(source["slot"], spoken, plants) \
            + steps.recogniser_problems(source["slot"], spoken, source["notes"])
        rows.append({"id": source["id"], "slot": source["slot"], "notes": source["notes"],
                     "exemplars": source["exemplars"], "spoken": spoken, "plants": plants,
                     "spoken_words": len(spoken.split()), "problems": problems,
                     "dollars": round(result["usage"]["dollars"], 6)})
    good = [r for r in rows if not r["problems"]]
    pilot.write_lines(guard.safe_output(f"{args.out}.speech.jsonl", scratch), rows)
    pilot.write_lines(guard.safe_output(f"{args.out}.speech_failed.jsonl", scratch), failed)
    pilot.write_lines(guard.safe_output(f"{args.out}.for_writer.jsonl", scratch),
                      [{"id": r["id"], "spoken": r["spoken"]} for r in good])
    counts = {}
    for r in rows:
        for name in r["problems"]:
            key = re.sub(r"\d+", "N", ":".join(name.split(":")[:2]))
            counts[key] = counts.get(key, 0) + 1
    print(f"speech: {len(rows_in)} notes in, {len(rows)} spoken written, {len(failed)} call failures, "
          f"{len(good)} pass the plan and recogniser checks; ${dollars:.4f}")
    print(f"  findings (a row can have several): {json.dumps(dict(sorted(counts.items())))}")
    return 2 if fatal else 0


def overturned(row, other):
    """A writer quarantine whose only reason is the writer's negation count, which counts a phrase said twice in a
    restart twice, is overturned when the pilot's own negation rule (typed text is the truth) finds nothing wrong."""
    if other["writer_route"] != "quarantine" or set(other["quarantine_reasons"]) != {"check:negation"}:
        return False
    return pilot_steps.negation_faithful(row["spoken"], other["typed"], row["plants"])["ok"]


def run_facts(args):
    scratch = guard.scratch_roots(args.scratch_dir)
    if not args.invented_or_public:
        raise writer.WriterError("pass --invented-or-public")
    second = {}
    for suffix in ("accepted", "quarantine", "not_typed"):
        path = Path(f"{args.writer}.{suffix}.jsonl")
        if path.exists():
            for row in pilot.read_lines(path, scratch):
                second[row["id"]] = {**row, "writer_route": suffix}
    out = []
    for row in pilot.read_lines(args.speech, scratch):
        other = second.get(row["id"])
        entry = {"id": row["id"], "route": "speech_first", "slot": row["slot"], "notes": row["notes"],
                 "spoken": row["spoken"], "plants": row["plants"]}
        if row["problems"]:
            stage, detail = "spoken_checks", row["problems"]
        elif other is None:
            stage, detail = "writer_missing", []
        elif other["writer_route"] != "accepted" and not overturned(row, other):
            stage, detail = "writer_" + other["writer_route"], other["quarantine_reasons"]
            entry["typed"] = other["typed"]
        else:
            entry["typed"] = other["typed"]
            entry["writer_route_overturned"] = other["writer_route"] != "accepted"
            entry["writer_unsure"] = other["unsure"]
            verdict = steps.check_against_notes(row["notes"], row["plants"], other["typed"])
            entry["notes_check"] = verdict
            stage = "kept" if verdict["ok"] else "notes_check"
            detail = verdict["failed"]
        out.append({**entry, "stage": stage, "detail": detail})
    pilot.write_lines(guard.safe_output(f"{args.out}.facts.jsonl", scratch), out)
    counts = {}
    for r in out:
        counts[r["stage"]] = counts.get(r["stage"], 0) + 1
    print(f"facts: {len(out)} rows -> {json.dumps(dict(sorted(counts.items())))}")
    return 0


def parser():
    cli = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = cli.add_subparsers(dest="command", required=True)
    plan = commands.add_parser("plan")
    plan.add_argument("--out", required=True)
    plan.add_argument("--seed", type=int, default=11)
    plan.add_argument("--count", type=int, help="scale plan with this many passages")
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--scratch-dir", action="append", default=[])
    common.add_argument("--invented-or-public", action="store_true")
    common.add_argument("--out", required=True)
    calls = argparse.ArgumentParser(add_help=False, parents=[common])
    calls.add_argument("--model", default=writer.DEFAULT_MODEL)
    calls.add_argument("--max-dollars", type=float, default=2.0)
    calls.add_argument("--scale-run", action="store_true", help="use the explicit total cap instead of the pilot ceiling")
    calls.add_argument("--dry-run", action="store_true")
    calls.add_argument("--limit", type=int)
    calls.add_argument("--state-dir", default=str(pilot.STATE))
    calls.add_argument("--key-file", default=guard.DEFAULT_KEY_FILE)
    calls.add_argument("--base-url", default=f"https://{client_module.API_HOST}")
    calls.add_argument("--workers", type=int, default=4)
    calls.add_argument("--max-tokens", type=int, default=6_000)
    calls.add_argument("--effort", choices=("low", "medium", "high", "xhigh", "max"))
    calls.add_argument("--est-output-tokens", type=int, default=1_200)
    calls.add_argument("--max-retries", type=int, default=5)
    calls.add_argument("--timeout", type=float, default=300.0)
    client_module.add_prompt_cache_flag(calls)
    notes = commands.add_parser("notes", parents=[calls])
    notes.add_argument("--plan", required=True)
    speech = commands.add_parser("speech", parents=[calls])
    speech.add_argument("--notes", required=True)
    speech.add_argument("--pool", required=True, help="capped meeting passages (JSONL with spoken) for manner examples")
    facts = commands.add_parser("facts", parents=[common])
    facts.add_argument("--speech", required=True)
    facts.add_argument("--writer", required=True)
    return cli


def run_plan(args):
    slots = planner.scale_plan(args.count, args.seed) if args.count else planner.plan(args.seed)
    pilot.write_lines(args.out, slots)
    print(json.dumps(planner.summary(slots)))
    return 0


def main(argv=None):
    args = parser().parse_args(argv)
    handlers = {"plan": run_plan, "notes": run_notes, "speech": run_speech, "facts": run_facts}
    try:
        return handlers[args.command](args)
    except (writer.WriterError, GuardError, api_judge.JudgeError, OSError, KeyError) as exc:
        print(f"retrain-speech: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
