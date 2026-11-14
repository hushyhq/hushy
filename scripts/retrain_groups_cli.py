#!/usr/bin/env python3
"""Pilot steps 4 to 7: merge the two routes, per-group targets (API), group-level checks, rows for both arms.

    retrain_groups_cli.py merge   --facts S.facts.jsonl --typed-first P.meaning.jsonl --out SRC
    (run `murmur-eval finetune groups --in SRC.groups_in.jsonl --out GROUPS`, through scripts/mac-heavy.sh)
    retrain_groups_cli.py targets --sources SRC.sources.jsonl --groups GROUPS --out T ... --max-dollars N
    retrain_groups_cli.py prepare-in --sources SRC.sources.jsonl --targets T.targets.jsonl --out PREP
    (run `murmur-eval finetune prepare --in PREP.prepare_in.jsonl --out PREP.prepare_out.jsonl`)
    retrain_groups_cli.py assemble --sources ... --groups ... --targets ... --prepare PREP.prepare_out.jsonl --out OUT
"""

import argparse
import json
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))

import api_judge  # noqa: E402
import api_judge_client as client_module  # noqa: E402
import api_judge_guard as guard  # noqa: E402
import retrain_groups as groups_lib  # noqa: E402
import retrain_pilot as pilot  # noqa: E402
import retrain_writer as writer  # noqa: E402
from api_judge_guard import GuardError  # noqa: E402

TARGETS_BRIEF = guard.EVALS / "judge" / "GROUP-TARGETS-INSTRUCTIONS.md"
PROMPTS = guard.EVALS / "finetune-prompts"
TYPED_FIRST_KEPT = 15


def pick_typed_first(rows, count=TYPED_FIRST_KEPT):
    """Heavy rows first, then moderate; only rows that passed every earlier step and have no code punctuation in the
    speech; spread over families by taking them round-robin."""
    good = [r for r in rows if r["meaning"]["status"] == "agree" and not r["plan_problems"] and not r["failed_checks"]
            and "_" not in r["spoken"]]
    good.sort(key=lambda r: {"heavy": 0, "moderate": 1, "clean": 2}[r["slot"]["profile"]])
    by_family, order = {}, []
    for row in good:
        by_family.setdefault(row["slot"]["family"], []).append(row)
    while len(order) < count and any(by_family.values()):
        for family in sorted(by_family):
            if by_family[family] and len(order) < count:
                order.append(by_family[family].pop(0))
    return order


def source_row(row, route):
    slot = row["slot"]
    return {"id": row["id"], "route": route, "family": slot["family"], "kind": slot["kind"],
            "band": slot.get("band"), "profile": slot["profile"], "surface": slot["surface"],
            "spoken": row["spoken"], "typed": row["typed"], "plants": row["plants"]}


def run_merge(args):
    scratch = guard.scratch_roots(args.scratch_dir)
    speech = [source_row(r, "speech_first") for r in pilot.read_lines(args.facts, scratch) if r["stage"] == "kept"]
    typed_first = [source_row(r, "typed_first") for r in pick_typed_first(pilot.read_lines(args.typed_first, scratch))]
    sources = speech + typed_first
    pilot.write_lines(guard.safe_output(f"{args.out}.sources.jsonl", scratch), sources)
    pilot.write_lines(guard.safe_output(f"{args.out}.groups_in.jsonl", scratch),
                      [{"id": r["id"], "text": r["spoken"]} for r in sources])
    print(f"merge: {len(speech)} speech-first + {len(typed_first)} typed-first = {len(sources)} passages")
    return 0


def run_targets(args):
    scratch = guard.scratch_roots(args.scratch_dir)
    pilot.check_run_flags(args)
    sources = pilot.read_lines(args.sources, scratch)[: args.limit or None]
    by_id = {g["id"]: g for g in pilot.read_lines(args.groups, scratch)}
    items = [{**s, "group_row": by_id[s["id"]]} for s in sources if s["id"] in by_id]
    outcome = pilot.call_step(args, scratch, items, lambda r: groups_lib.targets_card(r, r["group_row"]),
                              groups_lib.targets_schema(), groups_lib.validate_targets, groups_lib.TargetsRunner,
                              TARGETS_BRIEF, "Split the typed text over the groups.")
    if outcome is None:
        return 0
    results, dollars, fatal = outcome
    rows, failed = [], []
    for item, result in zip(items, results):
        if not result["written"]:
            failed.append({"id": item["id"], "status": result["status"], "error": result["error"]})
            continue
        rows.append({"id": item["id"], "pieces": result["written"]["pieces"],
                     "dollars": round(result["usage"]["dollars"], 6)})
    pilot.write_lines(guard.safe_output(f"{args.out}.targets.jsonl", scratch), rows)
    pilot.write_lines(guard.safe_output(f"{args.out}.targets_failed.jsonl", scratch), failed)
    print(f"targets: {len(items)} passages, {len(rows)} written, {len(failed)} call failures; ${dollars:.4f}")
    return 2 if fatal else 0


def usable_pieces(group_row, target):
    """Pieces indexed by group, or None when the call did not return exactly one piece per group, in order."""
    pieces = target["pieces"]
    return pieces if [p["index"] for p in pieces] == [g["index"] for g in group_row["groups"]] else None


def run_prepare_in(args):
    scratch = guard.scratch_roots(args.scratch_dir)
    sources = {s["id"]: s for s in pilot.read_lines(args.sources, scratch)}
    group_rows = {g["id"]: g for g in pilot.read_lines(args.groups, scratch)}
    rows = []
    for target in pilot.read_lines(args.targets, scratch):
        source, grp = sources[target["id"]], group_rows[target["id"]]
        rows.append({"id": f"{source['id']}-whole", "level": "clean", "raw": source["spoken"], "target": source["typed"]})
        pieces = usable_pieces(grp, target)
        for group, piece in zip(grp["groups"], pieces or []):
            if piece["piece"].strip():
                rows.append({"id": f"{source['id']}-g{group['index']}", "level": "clean", "raw": group["text"],
                             "target": piece["piece"].strip()})
    pilot.write_lines(guard.safe_output(f"{args.out}.prepare_in.jsonl", scratch), rows)
    print(f"prepare-in: {len(rows)} (raw, target) pairs")
    return 0


def parser():
    cli = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = cli.add_subparsers(dest="command", required=True)
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--scratch-dir", action="append", default=[])
    common.add_argument("--invented-or-public", action="store_true")
    common.add_argument("--out", required=True)
    merge = commands.add_parser("merge", parents=[common])
    merge.add_argument("--facts", required=True)
    merge.add_argument("--typed-first", required=True)
    calls = argparse.ArgumentParser(add_help=False, parents=[common])
    calls.add_argument("--model", default=writer.DEFAULT_MODEL)
    calls.add_argument("--max-dollars", type=float, default=3.0)
    calls.add_argument("--dry-run", action="store_true")
    calls.add_argument("--limit", type=int)
    calls.add_argument("--state-dir", default=str(pilot.STATE))
    calls.add_argument("--key-file", default=guard.DEFAULT_KEY_FILE)
    calls.add_argument("--base-url", default=f"https://{client_module.API_HOST}")
    calls.add_argument("--workers", type=int, default=4)
    calls.add_argument("--max-tokens", type=int, default=10_000)
    calls.add_argument("--effort", choices=("low", "medium", "high", "xhigh", "max"))
    calls.add_argument("--est-output-tokens", type=int, default=2_000)
    calls.add_argument("--max-retries", type=int, default=5)
    calls.add_argument("--timeout", type=float, default=300.0)
    client_module.add_prompt_cache_flag(calls)
    targets = commands.add_parser("targets", parents=[calls])
    targets.add_argument("--sources", required=True)
    targets.add_argument("--groups", required=True)
    prep = commands.add_parser("prepare-in", parents=[common])
    prep.add_argument("--sources", required=True)
    prep.add_argument("--groups", required=True)
    prep.add_argument("--targets", required=True)
    return cli


def main(argv=None):
    args = parser().parse_args(argv)
    handlers = {"merge": run_merge, "targets": run_targets, "prepare-in": run_prepare_in}
    try:
        return handlers[args.command](args)
    except (writer.WriterError, GuardError, api_judge.JudgeError, OSError, KeyError) as exc:
        print(f"retrain-groups: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
