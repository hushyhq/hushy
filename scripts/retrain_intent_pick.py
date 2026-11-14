#!/usr/bin/env python3
"""Choosing whole groups of cases (for example whole meetings) for the intent measurement. No model call.

Picking takes N groups at random (seeded) and up to K cases from each, and writes the chosen group ids
(ids only, no text) beside the cases. Excluding is the inverse: every case of those groups is dropped,
which is how training inputs are kept clear of the groups being measured.

Run through scripts/retrain_intent.py pick-groups.
"""

import json
from pathlib import Path
import random
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))

import api_judge_guard as guard  # noqa: E402
import retrain_pilot as pilot  # noqa: E402


class PickError(Exception):
    """The request or an input cannot be used; nothing was written."""


def group_of(case, key):
    """The case's group as text. A case with no group is refused: it cannot be shown to be outside one."""
    value = case.get(key) if isinstance(case, dict) else None
    if isinstance(value, bool) or not isinstance(value, (str, int)) or value == "":
        raise PickError(f"a case has no usable {key!r} (id {case.get('id') if isinstance(case, dict) else None!r})")
    return str(value)


def by_group(cases, key):
    groups = {}
    for case in cases:
        groups.setdefault(group_of(case, key), []).append(case)
    return groups


def pick_groups(cases, key, groups, per_group, seed):
    """Returns (the chosen group ids, sorted; their cases, up to `per_group` each, in their original order)."""
    if groups < 1 or per_group < 1:
        raise PickError("--groups and --per-group must be at least 1")
    members = by_group(cases, key)
    if groups > len(members):
        raise PickError(f"asked for {groups} groups; the cases hold only {len(members)}")
    rng = random.Random(seed)
    chosen = sorted(rng.sample(sorted(members), groups))
    picked = []
    for name in chosen:
        keep = set(rng.sample(range(len(members[name])), min(per_group, len(members[name]))))
        picked.extend(case for index, case in enumerate(members[name]) if index in keep)
    return chosen, picked


def exclude_groups(cases, key, excluded):
    """Every case whose group is not in `excluded`, in the original order."""
    names = {str(g) for g in excluded}
    return [case for case in cases if group_of(case, key) not in names]


def read_group_ids(path):
    try:
        value = json.loads(Path(path).read_text(encoding="utf-8"))
    except ValueError as exc:
        raise PickError(f"{path} is not JSON: {exc}") from None
    if not isinstance(value, list) or not all(isinstance(g, (str, int)) and not isinstance(g, bool) for g in value):
        raise PickError(f"{path} must be a JSON list of group ids")
    return value


def check_mode(args):
    picking = (args.groups, args.per_group, args.ids_out)
    if args.exclude_groups and any(v is not None for v in picking):
        raise PickError("--exclude-groups does not go with --groups, --per-group or --ids-out")
    if not args.exclude_groups and any(v is None for v in picking):
        raise PickError("picking needs --groups, --per-group and --ids-out (or pass --exclude-groups)")


def run(args):
    scratch = guard.scratch_roots(args.scratch_dir)
    check_mode(args)
    cases = [case for path in args.cases for case in pilot.read_lines(path, scratch)]
    out = guard.safe_output(args.out, scratch)
    if args.exclude_groups:
        excluded = read_group_ids(guard.safe_input(args.exclude_groups, scratch))
        kept = exclude_groups(cases, args.group_key, excluded)
        seen = {str(g) for g in excluded} & set(by_group(cases, args.group_key))
        pilot.write_lines(out, kept)
        print(json.dumps({"cases": len(cases), "dropped": len(cases) - len(kept), "kept": len(kept),
                          "groups_excluded": len(set(map(str, excluded))), "groups_excluded_seen": len(seen)}))
        return 0
    ids_out = guard.safe_output(args.ids_out, scratch)
    chosen, picked = pick_groups(cases, args.group_key, args.groups, args.per_group, args.seed)
    pilot.write_lines(out, picked)
    ids_out.parent.mkdir(parents=True, exist_ok=True)
    ids_out.write_text(json.dumps(chosen, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    print(json.dumps({"groups_available": len(by_group(cases, args.group_key)), "groups_picked": len(chosen),
                      "cases": len(picked)}))
    return 0


def add_parser(commands, common):
    cli = commands.add_parser("pick-groups", parents=[common], help="choose whole groups of cases, or drop them")
    cli.add_argument("--cases", action="append", required=True, help="JSON lines of cases; repeat for more files")
    cli.add_argument("--group-key", required=True, help="the case field that names its group, for example meeting")
    cli.add_argument("--groups", type=int, help="how many whole groups to choose")
    cli.add_argument("--per-group", type=int, help="at most this many cases from each chosen group")
    cli.add_argument("--seed", type=int, default=11)
    cli.add_argument("--out", required=True)
    cli.add_argument("--ids-out", help="where the chosen group ids go (a JSON list, no text)")
    cli.add_argument("--exclude-groups", help="a group id list written by --ids-out: drop every case of those groups")
    return cli
