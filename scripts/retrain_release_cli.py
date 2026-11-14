#!/usr/bin/env python3
"""Pilot round 4: the release route and the policy relabel.

    retrain_release_cli.py groups-in --sources SRC.sources.jsonl --out R
        (run `murmur-eval finetune groups --in R.groups_in.jsonl --out R.groups.jsonl` through scripts/mac-heavy.sh)
    retrain_release_cli.py relabel   --sources ... --groups R.groups.jsonl --out R ... --max-dollars N   [--dry-run]
    retrain_release_cli.py verdicts-in --sources ... --groups ... --targets R.targets.jsonl --out R
        (run `murmur-eval finetune verdicts --in R.verdicts_in.jsonl --out R.verdicts_out.jsonl`)
    retrain_release_cli.py report    --sources ... --groups ... --targets ... --verdicts ... --earlier OLD.assessments.jsonl
                                     --out R --md Evals/runs/retrain/pilot60.md [--judgment FILE]
"""

import argparse
import json
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))

import api_judge  # noqa: E402
import api_judge_client as client_module  # noqa: E402
import api_judge_guard as guard  # noqa: E402
import retrain_assemble as assemble  # noqa: E402
import retrain_groups as groups_lib  # noqa: E402
import retrain_groups_cli as groups_cli  # noqa: E402
import retrain_pilot as pilot  # noqa: E402
import retrain_release as release  # noqa: E402
import retrain_release_compare as compare  # noqa: E402
import retrain_release_report as report  # noqa: E402
import retrain_writer as writer  # noqa: E402
from api_judge_guard import GuardError  # noqa: E402

def relabel_policy(version):
    if version == "v3":
        return guard.EVALS / "judge" / "GROUP-TARGETS-INSTRUCTIONS-V3.md", groups_lib.TargetsRunnerV3
    if version == "v4":
        return guard.EVALS / "judge" / "GROUP-TARGETS-INSTRUCTIONS-V4.md", groups_lib.TargetsRunnerV4
    return guard.EVALS / "judge" / "GROUP-TARGETS-INSTRUCTIONS.md", groups_lib.TargetsRunnerV4


def run_groups_in(args):
    scratch = guard.scratch_roots(args.scratch_dir)
    sources = pilot.read_lines(args.sources, scratch)
    pilot.write_lines(guard.safe_output(f"{args.out}.groups_in.jsonl", scratch), release.groups_in_rows(sources))
    print(f"groups-in: {len(sources)} passages, bundles {sorted(set(release.BUNDLES.values()))}")
    return 0


def run_relabel(args):
    scratch = guard.scratch_roots(args.scratch_dir)
    pilot.check_run_flags(args)
    sources = pilot.read_lines(args.sources, scratch)[: args.limit or None]
    by_id = {g["id"]: g for g in pilot.read_lines(args.groups, scratch)}
    items = [{**s, "group_row": by_id[s["id"]]} for s in sources if s["id"] in by_id]
    brief, runner = relabel_policy(args.label_version)
    outcome = pilot.call_step(args, scratch, items, lambda r: release.relabel_card(r, r["group_row"]),
                              groups_lib.targets_schema_v3(), groups_lib.validate_targets_v3, runner,
                              brief, "Write the piece for every group.")
    if outcome is None:
        return 0
    results, dollars, fatal = outcome
    rows, failed = [], []
    for item, result in zip(items, results):
        if not result["written"]:
            failed.append({"id": item["id"], "status": result["status"], "error": result["error"]})
            continue
        rows.append({"id": item["id"], "typed": result["written"]["typed"], "pieces": result["written"]["pieces"],
                     "dollars": round(result["usage"]["dollars"], 6)})
    pilot.write_lines(guard.safe_output(f"{args.out}.targets.jsonl", scratch), rows)
    pilot.write_lines(guard.safe_output(f"{args.out}.targets_failed.jsonl", scratch), failed)
    print(f"relabel: {len(items)} passages, {len(rows)} written, {len(failed)} call failures; ${dollars:.4f}")
    return 2 if fatal else 0


def run_verdicts_in(args):
    scratch = guard.scratch_roots(args.scratch_dir)
    sources = {s["id"]: s for s in pilot.read_lines(args.sources, scratch)}
    group_rows = {g["id"]: g for g in pilot.read_lines(args.groups, scratch)}
    rows = []
    for target in pilot.read_lines(args.targets, scratch):
        source, grp = sources[target["id"]], group_rows[target["id"]]
        pieces = groups_cli.usable_pieces(grp, target)
        rows += release.verdict_rows(source, grp, pieces, groups_lib.join_pieces(pieces) if pieces else source["typed"])
    pilot.write_lines(guard.safe_output(f"{args.out}.verdicts_in.jsonl", scratch), rows)
    print(f"verdicts-in: {len(rows)} (raw, target) pairs")
    return 0


def judge_reports(sources, targets, flat=False):
    """One report per arm, suitable for api_judge.py convert; flatten both arms identically."""
    target_by_id = {row["id"]: row for row in targets}
    result = {"joined": [], "whole": []}
    for source in sources:
        ident = source["id"]
        if ident not in target_by_id:
            continue
        values = {"joined": groups_lib.join_pieces(target_by_id[ident]["pieces"]), "whole": source["typed"]}
        for arm, value in values.items():
            if flat:
                value = " ".join(value.split())
            result[arm].append({"id": ident, "output": value})
    return result


def run_judge_reports(args):
    scratch = guard.scratch_roots(args.scratch_dir)
    sources = pilot.read_lines(args.sources, scratch)
    targets = pilot.read_lines(args.targets, scratch)
    if {s["id"] for s in sources} != {t["id"] for t in targets}:
        raise GuardError("judge reports require the same passage ids in sources and targets")
    for arm, rows in judge_reports(sources, targets, flat=args.flat).items():
        pilot.write_lines(guard.safe_output(f"{args.out}.{arm}.jsonl", scratch), rows)
    print(f"judge-reports: {len(sources)} passages, flat={args.flat}")
    return 0


def new_source(source, pieces):
    """The passage as the relabel leaves it: the typed text is the joined pieces; the earlier text is kept beside it."""
    return {**source, "typed": groups_lib.join_pieces(pieces), "typed_earlier": source["typed"]}


def training_rows(judged, assessments, group_rows):
    """Chat rows for both arms from what survived every check; the model's input is the release-route draft."""
    system_group = groups_lib.prompt_sections(assemble.guard.EVALS / "finetune-prompts" / "group-call-system.txt")
    system_whole = groups_lib.prompt_sections(assemble.guard.EVALS / "finetune-prompts" / "whole-dictation-system.txt")
    group_out, whole_out = [], []
    for source, a in zip(judged, assessments):
        grp, previous = group_rows[source["id"]], ""
        for group, record in zip(grp["groups"], a["groups"]):
            if record["accepted"]:
                piece = {"piece": record["piece"], "new_paragraph": record["new_paragraph"]}
                group_out.append({**groups_lib.group_row(source, group, previous, piece, system_group),
                                  "left_context": record["left_context"]})
            previous = group["draft"]
        if a["pieces_ok"] and not a["whole"]["failed_checks"] and a["whole"]["guard"]["status"] == "accepted":
            whole_out.append(groups_lib.whole_row(source, grp["wholeDraft"], system_whole))
    return group_out, whole_out


def v3_typed(args, scratch):
    if not args.v3_targets:
        return {}
    return {t["id"]: groups_lib.join_pieces(t["pieces"]) for t in pilot.read_lines(args.v3_targets, scratch)}


def flag_damage(assessment, damage):
    """A target built on a draft that lost a content word is flagged, never accepted."""
    name = assessment["id"]
    if f"{name}-whole" in damage:
        assessment["whole"]["failed_checks"] = assessment["whole"]["failed_checks"] + ["draft_lost_content_word"]
    for group in assessment["groups"]:
        lost = damage.get(f"{name}-g{group['index']}")
        if lost:
            group["failed_checks"] = group["failed_checks"] + ["draft_lost_content_word"]
            group["not_representable_because"] = group["not_representable_because"] + [
                "draft lost a content word: " + ", ".join(lost)]
            group["representable"] = False
            group["accepted"] = False
    return assessment


def run_report(args):
    scratch = guard.scratch_roots(args.scratch_dir)
    sources = pilot.read_lines(args.sources, scratch)
    group_rows = {g["id"]: g for g in pilot.read_lines(args.groups, scratch)}
    targets = {t["id"]: t for t in pilot.read_lines(args.targets, scratch)}
    verdicts = {v["id"]: v for v in pilot.read_lines(args.verdicts, scratch)}
    earlier = {a["id"]: a for a in pilot.read_lines(args.earlier, scratch)} if args.earlier else {}
    damage = release.damaged_drafts(group_rows)
    judged, assessments, new_typed = [], [], {}
    lookup = lambda table, key: release.release_verdict(table.get(key))  # noqa: E731
    for source in sources:
        grp, target = group_rows.get(source["id"]), targets.get(source["id"])
        pieces = assemble.pilot_pieces(grp, target) if grp and target else None
        if not pieces:
            continue
        current = new_source(source, pieces)
        new_typed[source["id"]] = current["typed"]
        judged.append(current)
        assessments.append(flag_damage(assemble.assess(current, grp, target, verdicts, verdict=lookup), damage))
    records = release.arm_records(assessments)
    summary = {"reasons": release.reason_table(records), "rows_kept": report.rows_kept(assessments), "damaged_drafts": damage,
               "v3_typed": v3_typed(args, scratch),
               "differences": release.difference_summary(judged, new_typed),
               "whole_on_earlier_text": report.earlier_text_table(sources, verdicts)}
    pilot.write_lines(guard.safe_output(f"{args.out}.assessments.jsonl", scratch), assessments)
    group_out, whole_out = training_rows(judged, assessments, group_rows)
    pilot.write_lines(guard.safe_output(f"{args.out}.group_rows.jsonl", scratch), group_out)
    pilot.write_lines(guard.safe_output(f"{args.out}.whole_rows.jsonl", scratch), whole_out)
    Path(guard.safe_output(f"{args.out}.summary.json", scratch)).write_text(json.dumps(summary, indent=1) + "\n",
                                                                            encoding="utf-8")
    judgment = Path(guard.safe_input(args.judgment, scratch)).read_text(encoding="utf-8") if args.judgment else ""
    target_md = guard.safe_output(args.md, scratch)
    target_md.parent.mkdir(parents=True, exist_ok=True)
    target_md.write_text(report.render_md(sources, judged, assessments, earlier, summary, args.cost, judgment),
                         encoding="utf-8")
    print(report.short_summary(summary))
    return 0


def run_compare(args):
    """--label NAME=TARGETS[,VERDICTS] per version; writes OUT.compare.json and a markdown section."""
    scratch = guard.scratch_roots(args.scratch_dir)
    sources = pilot.read_lines(args.sources, scratch)
    group_rows = {g["id"]: g for g in pilot.read_lines(args.groups, scratch)}
    summary = {}
    for spec in args.label:
        name, _, files = spec.partition("=")
        target_file, _, verdict_file = files.partition(",")
        targets = {t["id"]: t for t in pilot.read_lines(target_file, scratch)}
        verdicts = {v["id"]: v for v in pilot.read_lines(verdict_file, scratch)} if verdict_file else None
        summary[name] = compare.version_summary(sources, group_rows, targets, verdicts)
    Path(guard.safe_output(f"{args.out}.compare.json", scratch)).write_text(json.dumps(summary, indent=1) + "\n",
                                                                           encoding="utf-8")
    print(report.compare_md(summary))
    return 0


def run_judge_summary(args):
    scratch = guard.scratch_roots(args.scratch_dir)
    summaries = [compare.judge_summary(json.loads(Path(guard.safe_input(path, scratch)).read_text(encoding="utf-8")))
                 for path in args.run]
    Path(guard.safe_output(f"{args.out}.judge.json", scratch)).write_text(json.dumps(summaries, indent=1) + "\n",
                                                                         encoding="utf-8")
    print(report.judge_md(summaries))
    return 0


def parser():
    cli = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = cli.add_subparsers(dest="command", required=True)
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--scratch-dir", action="append", default=[])
    common.add_argument("--out", required=True)
    gi = commands.add_parser("groups-in", parents=[common])
    gi.add_argument("--sources", required=True)
    calls = argparse.ArgumentParser(add_help=False, parents=[common])
    calls.add_argument("--invented-or-public", action="store_true")
    calls.add_argument("--model", default=writer.DEFAULT_MODEL)
    calls.add_argument("--max-dollars", type=float)
    calls.add_argument("--scale-run", action="store_true", help="use the explicit total cap instead of the pilot ceiling")
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
    rl = commands.add_parser("relabel", parents=[calls])
    rl.add_argument("--sources", required=True)
    rl.add_argument("--groups", required=True)
    rl.add_argument("--label-version", choices=("v3", "v4", "v4.1"), default="v4.1")
    vi = commands.add_parser("verdicts-in", parents=[common])
    for name in ("sources", "groups", "targets"):
        vi.add_argument(f"--{name}", required=True)
    jr = commands.add_parser("judge-reports", parents=[common])
    jr.add_argument("--sources", required=True)
    jr.add_argument("--targets", required=True)
    jr.add_argument("--flat", action="store_true", help="remove every line break from both output arms")
    cp = commands.add_parser("compare", parents=[common])
    cp.add_argument("--sources", required=True)
    cp.add_argument("--groups", required=True)
    cp.add_argument("--label", action="append", required=True, metavar="NAME=TARGETS[,VERDICTS]")
    js = commands.add_parser("judge-summary", parents=[common])
    js.add_argument("--run", action="append", required=True)
    rp = commands.add_parser("report", parents=[common])
    for name in ("sources", "groups", "targets", "verdicts", "md"):
        rp.add_argument(f"--{name}", required=True)
    rp.add_argument("--earlier")
    rp.add_argument("--judgment")
    rp.add_argument("--v3-targets")
    rp.add_argument("--cost", default="see the ledger")
    return cli


def main(argv=None):
    args = parser().parse_args(argv)
    handlers = {"groups-in": run_groups_in, "relabel": run_relabel, "verdicts-in": run_verdicts_in,
                "judge-reports": run_judge_reports,
                "report": run_report, "compare": run_compare,
                "judge-summary": run_judge_summary}
    try:
        return handlers[args.command](args)
    except (writer.WriterError, GuardError, api_judge.JudgeError, OSError, KeyError) as exc:
        print(f"retrain-release: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
