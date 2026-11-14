#!/usr/bin/env python3
"""The 60-passage pilot, steps 1 to 3: typed text first, then the spoken version, then an independent meaning check.

Steps 4 onward (the app's own groups and rules drafts) need a Swift command that does not exist yet;
see Evals/judge/README.md. Everything sent to the API is invented here. Same client, key handling,
ledger, cache and path guards as the example writer.

    python3 scripts/retrain_pilot.py plan   --out Evals/runs/retrain/pilot/plan.jsonl
    python3 scripts/retrain_pilot.py typed  --plan P --out PREFIX --scratch-dir DIR --invented-or-public --max-dollars 2
    python3 scripts/retrain_pilot.py spoken --typed PREFIX.typed.jsonl --out PREFIX2 ... --max-dollars 3
    python3 scripts/retrain_writer.py write --passages PREFIX2.for_writer.jsonl ...   # the independent check
    python3 scripts/retrain_pilot.py meaning --spoken PREFIX2.spoken.jsonl --writer WPREFIX --out PREFIX3
    (add --dry-run to any call step: counts and estimated cost, nothing sent, key not opened)
"""

import argparse
import json
from pathlib import Path
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parent))

import api_judge  # noqa: E402
import api_judge_client as client_module  # noqa: E402
import api_judge_guard as guard  # noqa: E402
import retrain_pilot_plan as planner  # noqa: E402
import retrain_pilot_steps as steps  # noqa: E402
import retrain_writer as writer  # noqa: E402
from api_judge_guard import GuardError  # noqa: E402
from retrain_pilot_meaning import compare_typed  # noqa: E402

PILOT_CAP_DOLLARS = 15.0
TYPED_BRIEF = guard.EVALS / "judge" / "PILOT-TYPED-INSTRUCTIONS.md"
SPOKEN_BRIEF = guard.EVALS / "judge" / "PILOT-SPOKEN-INSTRUCTIONS.md"
STATE = guard.EVALS / "runs" / "retrain" / "pilot" / "state"


def write_lines(path, rows):
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    Path(path).write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in rows), encoding="utf-8")


def read_lines(path, scratch):
    return api_judge.read_json_or_lines(guard.safe_input(path, scratch))


# ---- the shared call step --------------------------------------------------------------------------

def budget_for_step(max_dollars, ledger, scale_run=False):
    spent = ledger.total_dollars()
    cap = max_dollars if scale_run else min(max_dollars, PILOT_CAP_DOLLARS)
    if spent >= cap:
        raise writer.WriterError(f"the cumulative cap of ${cap:.2f} is spent (ledger ${spent:.2f})")
    return api_judge.Budget(cap, spent=spent, ledger=ledger)


def call_step(args, scratch, items, build_user, schema, validate, runner_cls, brief_path, closing):
    """Makes one call per item. Returns (results, dollars, fatal) or prints a dry run and returns None."""
    instructions = guard.safe_input(brief_path, scratch).read_text(encoding="utf-8")
    version = steps.version_of(instructions)
    state = guard.check_path(args.state_dir, scratch, "state folder")
    cache, ledger = steps.StepCache(state / "cache", validate), api_judge.Ledger(state / "ledger.jsonl")
    tasks = []
    for item in items:
        body = steps.request_body(args.model, instructions, steps.user_message(build_user(item), closing), schema,
                                  args.max_tokens, args.effort)
        tasks.append({"passage": {"id": item["id"]}, "body": body, "key": api_judge.cache_key(args.model, version, body)})
    if args.dry_run:
        pending = [t for t in tasks if cache.get(t["key"]) is None]
        typical = sum(client_module.estimate_cost(args.model, t["body"], args.est_output_tokens) for t in pending)
        worst = sum(client_module.reservation_cost(args.model, t["body"]) for t in pending)
        spent = ledger.dry_run_total_dollars()
        cap = args.max_dollars if getattr(args, "scale_run", False) else (
            min(args.max_dollars, PILOT_CAP_DOLLARS) if args.max_dollars is not None else PILOT_CAP_DOLLARS)
        print(f"retrain-pilot dry run: {len(tasks)} items, {len(pending)} calls to make, model {args.model}: "
              f"typical ${typical:.2f} at {args.est_output_tokens} output tokens each, "
              f"worst case reservation ${worst:.2f} (input estimate {client_module.INPUT_RESERVATION_MARGIN:g}x); "
              f"ledger so far ${spent:.2f} of the ${cap:.2f} cap, remaining ${max(0.0, cap - spent):.2f} "
              f"(may be stale). "
              f"Nothing sent; the key file was not opened.")
        if pending:
            print(client_module.cache_prefix_line(args.model, pending[0]["body"], len(pending),
                                                  client_module.prompt_cache_on(args)))
        return None
    budget = budget_for_step(args.max_dollars, ledger, getattr(args, "scale_run", False))
    runner = runner_cls(args, cache, ledger, budget, api_judge.LazyClient(args))
    done = iter(range(1, len(tasks) + 1))

    def one(task):
        outcome = runner.execute(task)
        print(f"[{next(done)}/{len(tasks)}] {task['passage']['id']} {outcome['status']}"
              f"{' $%.4f' % outcome['usage']['dollars'] if outcome['usage']['dollars'] else ''}", file=sys.stderr)
        return outcome
    results = api_judge.map_warm_first(one, tasks, args.workers, lambda task: cache.get(task["key"]) is None,
                                       client_module.prompt_cache_on(args))
    dollars = sum(r["usage"]["dollars"] for r in results)
    print(f"retrain-pilot: ${dollars:.4f} this step (cumulative cap ${budget.cap:.2f}); "
          f"${ledger.total_dollars():.4f} in the shared ledger", file=sys.stderr)
    print(f"retrain-pilot: {client_module.cache_share_line(results)}", file=sys.stderr)
    return results, dollars, runner.fatal


def check_run_flags(args):
    if not args.invented_or_public:
        raise writer.WriterError("pass --invented-or-public to state that the input is invented or public-corpus text")
    writer.validate_spend_cap(args)
    client_module.price_for(args.model)


# ---- step 1: typed -------------------------------------------------------------------------------

def run_typed(args):
    scratch = guard.scratch_roots(args.scratch_dir)
    check_run_flags(args)
    slots = read_lines(args.plan, scratch)[: args.limit or None]
    outcome = call_step(args, scratch, slots, lambda s: steps.typed_card(s), steps.typed_schema(), steps.validate_typed,
                        steps.TypedRunner, TYPED_BRIEF, "Write the message.")
    if outcome is None:
        return 0
    results, dollars, fatal = outcome
    rows, failed = [], []
    for slot, result in zip(slots, results):
        if not result["written"]:
            failed.append({"id": slot["id"], "status": result["status"], "error": result["error"]})
            continue
        typed = result["written"]["typed"]
        rows.append({"id": slot["id"], "slot": slot, "typed": typed, "typed_words": len(typed.split()),
                     "problems": steps.typed_problems(slot, typed), "dollars": round(result["usage"]["dollars"], 6)})
    dupes = steps.near_duplicates([r for r in rows if not r["problems"]])
    for later, earlier, score in dupes:
        next(r for r in rows if r["id"] == later)["problems"].append(f"near_duplicate_of:{earlier}:{score}")
    write_lines(guard.safe_output(f"{args.out}.typed.jsonl", scratch), rows)
    write_lines(guard.safe_output(f"{args.out}.typed_failed.jsonl", scratch), failed)
    kept = [r for r in rows if not r["problems"]]
    print(f"typed: {len(slots)} planned, {len(rows)} written, {len(failed)} call failures, "
          f"{len(rows) - len(kept)} set aside ({sum(1 for r in rows if any(p.startswith('near_duplicate') for p in r['problems']))} "
          f"near-duplicates), {len(kept)} kept; ${dollars:.4f}")
    return 2 if fatal else 0


# ---- step 2: spoken ------------------------------------------------------------------------------

def run_spoken(args):
    scratch = guard.scratch_roots(args.scratch_dir)
    check_run_flags(args)
    typed_rows = [r for r in read_lines(args.typed, scratch) if not r["problems"]][: args.limit or None]
    outcome = call_step(args, scratch, typed_rows, lambda r: steps.spoken_card(r["slot"], r["typed"]),
                        steps.spoken_schema(), steps.validate_spoken, steps.SpokenRunner, SPOKEN_BRIEF,
                        "Write the spoken version.")
    if outcome is None:
        return 0
    results, dollars, fatal = outcome
    rows, failed = [], []
    for source, result in zip(typed_rows, results):
        if not result["written"]:
            failed.append({"id": source["id"], "status": result["status"], "error": result["error"]})
            continue
        spoken, plants = result["written"]["spoken"], result["written"]["plants"]
        failed_checks, outcome_checks = steps.spoken_vs_typed(source["slot"], spoken, source["typed"], plants)
        plan_problems = steps.spoken_problems(source["slot"], spoken, plants)
        rows.append({"id": source["id"], "slot": source["slot"], "typed": source["typed"], "spoken": spoken,
                     "plants": plants, "spoken_words": len(spoken.split()), "plan_problems": plan_problems,
                     "failed_checks": failed_checks, "checks": outcome_checks,
                     "dollars": round(result["usage"]["dollars"], 6)})
    good = [r for r in rows if not r["plan_problems"] and not r["failed_checks"]]
    write_lines(guard.safe_output(f"{args.out}.spoken.jsonl", scratch), rows)
    write_lines(guard.safe_output(f"{args.out}.spoken_failed.jsonl", scratch), failed)
    write_lines(guard.safe_output(f"{args.out}.for_writer.jsonl", scratch),
                [{"id": r["id"], "spoken": r["spoken"]} for r in good])
    counts = {}
    for r in rows:
        for name in [n.split("_")[0] for n in r["plan_problems"]] + [f"check:{n}" for n in r["failed_checks"]]:
            counts[name] = counts.get(name, 0) + 1
    print(f"spoken: {len(typed_rows)} typed in, {len(rows)} spoken written, {len(failed)} call failures, "
          f"{len(good)} pass the plan and relation checks; ${dollars:.4f}")
    print(f"  findings (a row can have several): {json.dumps(dict(sorted(counts.items())))}")
    return 2 if fatal else 0


# ---- step 3: meaning -----------------------------------------------------------------------------

def run_meaning(args):
    scratch = guard.scratch_roots(args.scratch_dir)
    if not args.invented_or_public:
        raise writer.WriterError("pass --invented-or-public")
    spoken_rows = read_lines(args.spoken, scratch)
    second = {}
    for suffix in ("accepted", "quarantine", "not_typed"):
        path = Path(f"{args.writer}.{suffix}.jsonl")
        if path.exists():
            for row in read_lines(path, scratch):
                second[row["id"]] = {**row, "writer_route": suffix}
    out = []
    for row in spoken_rows:
        other = second.get(row["id"])
        if other is None:
            out.append({**row, "meaning": {"status": "no_second_typed", "problems": []}})
            continue
        verdict = compare_typed(row["typed"], other["typed"])
        flags = list(verdict["problems"])
        if any(item["kind"] == "meaning" for item in other["unsure"]):
            flags.append("writer_marked_meaning_unsure")
        if not other["usable"]:
            flags.append("writer_marked_unusable")
        out.append({**row, "second_typed": other["typed"], "second_route": other["writer_route"],
                    "second_unsure": other["unsure"],
                    "meaning": {"status": "agree" if not flags else "disagree", "problems": flags,
                                "detail": verdict["detail"]}})
    write_lines(guard.safe_output(f"{args.out}.meaning.jsonl", scratch), out)
    agree = sum(1 for r in out if r["meaning"]["status"] == "agree")
    print(f"meaning: {len(out)} compared, {agree} agree, {len(out) - agree} set aside "
          f"({sum(1 for r in out if r['meaning']['status'] == 'no_second_typed')} had no second typed text)")
    return 0


def run_plan(args):
    slots = planner.plan(args.seed)
    write_lines(args.out, slots)
    print(json.dumps(planner.summary(slots)))
    return 0


def parser():
    cli = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = cli.add_subparsers(dest="command", required=True)
    plan = commands.add_parser("plan", help="write the 60-slot plan")
    plan.add_argument("--out", required=True)
    plan.add_argument("--seed", type=int, default=7)
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--scratch-dir", action="append", default=[])
    common.add_argument("--invented-or-public", action="store_true")
    common.add_argument("--out", required=True)
    calls = argparse.ArgumentParser(add_help=False, parents=[common])
    calls.add_argument("--model", default=writer.DEFAULT_MODEL)
    calls.add_argument("--max-dollars", type=float, help="required cumulative live cap (the pilot cap is $15 in all)")
    calls.add_argument("--dry-run", action="store_true")
    calls.add_argument("--limit", type=int)
    calls.add_argument("--state-dir", default=str(STATE))
    calls.add_argument("--key-file", default=guard.DEFAULT_KEY_FILE)
    calls.add_argument("--base-url", default=f"https://{client_module.API_HOST}")
    calls.add_argument("--workers", type=int, default=4)
    calls.add_argument("--max-tokens", type=int, default=6_000)
    calls.add_argument("--effort", choices=("low", "medium", "high", "xhigh", "max"))
    calls.add_argument("--est-output-tokens", type=int, default=1_200)
    calls.add_argument("--max-retries", type=int, default=5)
    calls.add_argument("--timeout", type=float, default=300.0)
    client_module.add_prompt_cache_flag(calls)
    typed = commands.add_parser("typed", parents=[calls])
    typed.add_argument("--plan", required=True)
    spoken = commands.add_parser("spoken", parents=[calls])
    spoken.add_argument("--typed", required=True)
    meaning = commands.add_parser("meaning", parents=[common])
    meaning.add_argument("--spoken", required=True)
    meaning.add_argument("--writer", required=True, help="prefix of the example writer's outputs for these spoken texts")
    return cli


def main(argv=None):
    args = parser().parse_args(argv)
    handlers = {"plan": run_plan, "typed": run_typed, "spoken": run_spoken, "meaning": run_meaning}
    try:
        return handlers[args.command](args)
    except (writer.WriterError, GuardError, api_judge.JudgeError, OSError, KeyError) as exc:
        print(f"retrain-pilot: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
