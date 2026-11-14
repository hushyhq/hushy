#!/usr/bin/env python3
"""Pilot step 6 and 7: group-level checks, guard verdicts, rows for both arms, and the side-by-side file.

    retrain_assemble.py --sources SRC.sources.jsonl --groups GROUPS --targets T.targets.jsonl \\
        --prepare PREP.prepare_out.jsonl --out OUT --md Evals/runs/retrain/pilot60.md --scratch-dir D --cost "..."
"""

import argparse
import json
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))

import api_judge_guard as guard  # noqa: E402
import retrain_checks as checks  # noqa: E402
import retrain_groups as lib  # noqa: E402
import retrain_pilot as pilot  # noqa: E402
import retrain_pilot_steps as pilot_steps  # noqa: E402

ROUTES = ("speech_first", "typed_first")


def guard_verdict(prepare_by_id, key):
    row = prepare_by_id.get(key)
    if row is None:
        return {"status": "not_run"}
    rejection = row.get("rejection")
    return {"status": "rejected" if isinstance(rejection, str) else "accepted", "reason": rejection or "",
            "draft": row.get("draft", "")}


def assess(source, group_row, target, prepare_by_id, verdict=guard_verdict):
    """Everything known about one passage: per-group records, passage-level verdicts."""
    pieces = pilot_pieces(group_row, target)
    out = {"id": source["id"], "route": source["route"], "family": source["family"], "groups": [],
           "pieces_ok": pieces is not None}
    whole_draft = group_row["wholeDraft"]
    corrections = [p for p in source["plants"] if p["kind"] != "opening_adds"]
    whole_outcome = checks.run_checks(whole_draft, source["typed"], corrections, ())
    # the draft is not the speech: corrections are quoted from the speech, so "grounded" has nothing to test, and the
    # negation rule is the pilot's (typed text is the truth)
    failed_whole = [n for n in checks.failed(whole_outcome) if n not in ("corrections_grounded", "negation")]
    if not pilot_steps.negation_faithful(whole_draft, source["typed"], source["plants"])["ok"]:
        failed_whole.append("negation")
    out["whole"] = {"draft": whole_draft, "failed_checks": failed_whole,
                    "guard": verdict(prepare_by_id, f"{source['id']}-whole")}
    if pieces is None:
        return out
    texts = [g["text"] for g in group_row["groups"]]
    out["joined_equals_typed"] = lib.same_text(lib.join_pieces(pieces), source["typed"])
    seams = lib.seam_spanning(source["plants"], texts)
    previous, previous_piece = "", ""
    for group, piece in zip(group_row["groups"], pieces):
        text = piece["piece"].strip()
        outcome, failed = lib.group_checks(group["draft"], text, source["plants"], group["text"]) if text else ({}, [])
        if text and piece["new_paragraph"] and group["continuesSentence"] \
                and (not previous_piece or not previous_piece.rstrip()[-1:] in ".!?" or text[0].islower()):
            failed = failed + ["paragraph_inside_sentence"]
        reasons = []
        if not piece["span_representable"]:
            reasons.append(f"writer: {piece['reason']}")
        if group["index"] in seams:
            reasons.append(f"seam: {seams[group['index']]}")
        if not text:
            reasons.append("empty piece")
        guard_result = verdict(prepare_by_id, f"{source['id']}-g{group['index']}") if text else {"status": "empty"}
        out["groups"].append({
            "index": group["index"], "continues_sentence": group["continuesSentence"], "text": group["text"],
            "draft": group["draft"], "left_context": lib.left_context(previous), "piece": text,
            "new_paragraph": piece["new_paragraph"], "representable": not reasons, "not_representable_because": reasons,
            "failed_checks": failed, "guard": guard_result,
            "accepted": bool(out["joined_equals_typed"] and not reasons and not failed
                             and guard_result["status"] == "accepted")})
        previous = group["draft"]
        previous_piece = text or previous_piece
    return out


def pilot_pieces(group_row, target):
    if target is None:
        return None
    return target["pieces"] if [p["index"] for p in target["pieces"]] == [g["index"] for g in group_row["groups"]] else None


def counts_for(assessments):
    def tally(rows):
        groups = [g for a in rows for g in a["groups"]]
        failed, guard_reasons = {}, {}
        for g in groups:
            for name in g["failed_checks"]:
                failed[name] = failed.get(name, 0) + 1
            if g["guard"]["status"] == "rejected":
                key = g["guard"]["reason"].split(":")[0] or "rejected"
                guard_reasons[key] = guard_reasons.get(key, 0) + 1
        return {"passages": len(rows), "with_usable_pieces": sum(1 for a in rows if a["pieces_ok"]),
                "joined_equals_typed": sum(1 for a in rows if a.get("joined_equals_typed")),
                "groups": len(groups), "representable": sum(1 for g in groups if g["representable"]),
                "group_checks_failed": dict(sorted(failed.items())),
                "guard_accepted": sum(1 for g in groups if g["guard"]["status"] == "accepted"),
                "guard_rejected": sum(1 for g in groups if g["guard"]["status"] == "rejected"),
                "guard_rejected_by": dict(sorted(guard_reasons.items())),
                "accepted_group_rows": sum(1 for g in groups if g["accepted"]),
                "whole_checks_failed": sum(1 for a in rows if a["whole"]["failed_checks"]),
                "whole_guard_rejected": sum(1 for a in rows if a["whole"]["guard"]["status"] == "rejected"),
                "accepted_whole_rows": sum(1 for a in rows if a["pieces_ok"] and not a["whole"]["failed_checks"]
                                           and a["whole"]["guard"]["status"] == "accepted")}
    return {route: tally([a for a in assessments if a["route"] == route]) for route in ROUTES}


def render_md(sources, assessments, counts, cost):
    by_id = {a["id"]: a for a in assessments}
    out = ["# Pilot: groups, per-group pieces, checks and guard verdicts", "",
           "Invented text. The groups and rules drafts come from `murmur-eval finetune groups` (the app's own "
           "`TextSegmentation.groups` and `TextCleaner`); guard verdicts from `finetune prepare` "
           "(`TrainingPairCheck`, no model). Left context is cut from the previous draft in Python.", "",
           f"API spend: {cost}", "", "## Counts per route", "", "```", json.dumps(counts, indent=1), "```", "",
           "## Passages", ""]
    for source in sources:
        a = by_id.get(source["id"])
        out += [f"### {source['id']} · {source['route']} · {source['family']} · {source['profile']} · "
                f"{len(source['spoken'].split())} spoken words", "", "typed:", "", "> " + source["typed"].replace("\n\n", "\n>\n> "),
                "", "spoken:", "", "> " + source["spoken"], ""]
        if source["plants"]:
            out += ["planted: " + "; ".join(f"{p['kind']}: \"{p['said_first']}\" -> \"{p['ended_on']}\"" for p in source["plants"]), ""]
        if not a or not a["pieces_ok"]:
            out += ["**no usable per-group pieces for this passage**", ""]
            continue
        out += [f"joined pieces equal typed: **{a['joined_equals_typed']}**; whole-text checks failed: "
                f"{a['whole']['failed_checks'] or 'none'}; whole guard: {a['whole']['guard']['status']} "
                f"{a['whole']['guard'].get('reason', '')}", ""]
        for g in a["groups"]:
            out += [f"- group {g['index']}{' (continues sentence)' if g['continues_sentence'] else ''}"
                    f"{' · NEW PARAGRAPH' if g['new_paragraph'] else ''} · representable: {g['representable']}"
                    f"{' (' + '; '.join(g['not_representable_because']) + ')' if g['not_representable_because'] else ''}"
                    f" · checks failed: {g['failed_checks'] or 'none'} · guard: {g['guard']['status']}"
                    f"{' ' + g['guard'].get('reason', '') if g['guard']['status'] == 'rejected' else ''}",
                    f"  - left context: {g['left_context']}", f"  - draft: {g['draft']}", f"  - piece: {g['piece']}"]
        out.append("")
    return "\n".join(out) + "\n"


def main(argv=None):
    cli = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    for name in ("sources", "groups", "targets", "prepare", "out", "md"):
        cli.add_argument(f"--{name}", required=True)
    cli.add_argument("--system-group", default=str(guard.EVALS / "finetune-prompts" / "group-call-system.txt"))
    cli.add_argument("--system-whole", default=str(guard.EVALS / "finetune-prompts" / "whole-dictation-system.txt"))
    cli.add_argument("--cost", default="see the ledger")
    cli.add_argument("--scratch-dir", action="append", default=[])
    args = cli.parse_args(argv)
    scratch = guard.scratch_roots(args.scratch_dir)
    sources = pilot.read_lines(args.sources, scratch)
    group_rows = {g["id"]: g for g in pilot.read_lines(args.groups, scratch)}
    targets = {t["id"]: t for t in pilot.read_lines(args.targets, scratch)}
    prepared = {p["id"]: p for p in pilot.read_lines(args.prepare, scratch)}
    assessments = [assess(s, group_rows[s["id"]], targets.get(s["id"]), prepared) for s in sources if s["id"] in group_rows]
    system_group, system_whole = lib.prompt_sections(args.system_group), lib.prompt_sections(args.system_whole)
    group_out, whole_out = [], []
    for source, a in zip([s for s in sources if s["id"] in group_rows], assessments):
        grp = group_rows[source["id"]]
        previous = ""
        for group, record in zip(grp["groups"], a["groups"]):
            if record["accepted"]:
                group_out.append({**lib.group_row(source, group, previous, {"piece": record["piece"],
                                                                         "new_paragraph": record["new_paragraph"]},
                                                  system_group), "left_context": record["left_context"]})
            previous = group["draft"]
        if a["pieces_ok"] and not a["whole"]["failed_checks"] and a["whole"]["guard"]["status"] == "accepted":
            whole_out.append(lib.whole_row(source, grp["wholeDraft"], system_whole))
    counts = counts_for(assessments)
    pilot.write_lines(guard.safe_output(f"{args.out}.assessments.jsonl", scratch), assessments)
    pilot.write_lines(guard.safe_output(f"{args.out}.group_rows.jsonl", scratch), group_out)
    pilot.write_lines(guard.safe_output(f"{args.out}.whole_rows.jsonl", scratch), whole_out)
    Path(guard.safe_output(f"{args.out}.counts.json", scratch)).write_text(json.dumps(counts, indent=1) + "\n", encoding="utf-8")
    target = guard.safe_output(args.md, scratch)
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(render_md(sources, assessments, counts, args.cost), encoding="utf-8")
    print(json.dumps(counts, indent=1))
    print(f"group rows: {len(group_out)}; whole rows: {len(whole_out)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
