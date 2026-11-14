#!/usr/bin/env python3
"""Seam and paragraph decisions under the small model's own view (Task 142).

    probe    a strong model cleans single groups seeing only what the small model sees (left context and the
             group's draft; with --right-words N also the first N words of the next draft). Paid; invented text only.
    edges    re-decides the seams the whole-message labels left open, under the small model's view: a piece ends
             closed unless its own words break off mid-clause, and the next piece then starts with a capital.
             Paid (one short call per open seam); writes a batch folder the trainset builder reads.
    compare  how often answers (from `probe`, or a model's predictions) match the whole-message labels at the
             group's start (lower case or capital), its end (open or closed) and the new-paragraph flag.

The paid step reuses the pilot's call step: the same client, key handling, ledger, cap and path guards.
"""

import argparse
import json
from pathlib import Path
import random
import re
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))

import api_judge  # noqa: E402
import api_judge_client as client_module  # noqa: E402
import api_judge_guard as guard  # noqa: E402
import api_judge_verdict as verdicts  # noqa: E402
import retrain_pilot as pilot  # noqa: E402
import retrain_writer as writer  # noqa: E402
from api_judge_guard import GuardError  # noqa: E402

BRIEF = guard.EVALS / "judge" / "SEAM-PROBE-INSTRUCTIONS.md"
CLOSED = re.compile(r"[.?!][\"')\]”’]*$")
USER = re.compile(r"Left context: ([^\n]*)\n(?:Right context: [^\n]*\n)?Transcript: ([^\n]+)\nOutput:")


def is_closed(text):
    return bool(CLOSED.search(text.strip()))


def starts_lower(text):
    """True, False, or None when the first character is not a letter (a digit or a symbol decides nothing)."""
    first = text.strip()[:1]
    return first.islower() if first.isalpha() else None


def edges(text, new_paragraph):
    return {"closed": is_closed(text), "lower": starts_lower(text), "paragraph": bool(new_paragraph)}


def schema():
    return {"type": "object", "properties": {"text": {"type": "string"}, "new_paragraph": {"type": "boolean"}},
            "required": ["text", "new_paragraph"], "additionalProperties": False}


def validate(raw):
    if not isinstance(raw, dict) or set(raw) != {"text", "new_paragraph"} or type(raw["text"]) is not str \
            or type(raw["new_paragraph"]) is not bool or "\n" in raw["text"]:
        raise verdicts.VerdictError("a probe answer needs a one-line text and a new_paragraph flag")
    return {"text": raw["text"], "new_paragraph": raw["new_paragraph"]}


class ProbeRunner(writer.WriterRunner):
    validate = staticmethod(validate)
    tool = "retrain_seam_probe"


def next_drafts(groups_rows, words):
    """{row id: the first `words` words of the next group's draft, or "none" for the last group}."""
    found = {}
    for passage in groups_rows:
        drafts = [g["draft"] for g in passage["groups"]]
        for index in range(len(drafts)):
            following = " ".join(drafts[index + 1].split()[:words]) if index + 1 < len(drafts) else "none"
            found[f"{passage['id']}-g{index}"] = following
    return found


def card(row, right=None):
    match = USER.fullmatch(row["messages"][1]["content"])
    if not match:
        raise writer.WriterError(f"{row['id']}: the user turn is not the group contract")
    out = {"left_context": match[1], "transcript": match[2]}
    if right is not None:
        out["right_context"] = right
    return out


def pick(rows, count, seed, first_ids=()):
    """Every row named in `first_ids`, then a seeded draw from the rest, `count` rows in all."""
    wanted = set(first_ids)
    head = [r for r in rows if r["id"] in wanted]
    rest = [r for r in rows if r["id"] not in wanted]
    random.Random(seed).shuffle(rest)
    return (head + rest)[:count] if count else head + rest


def run_probe(args):
    scratch = guard.scratch_roots(args.scratch_dir)
    pilot.check_run_flags(args)
    rows = [r for r in pilot.read_lines(args.rows, scratch) if r.get("source") != "legacy_replay"]
    first = [r["id"] for r in pilot.read_lines(args.first, scratch)] if args.first else []
    rows = pick(rows, args.count, args.seed, first)
    right = next_drafts(pilot.read_lines(args.groups, scratch), args.right_words) if args.right_words else None
    items = [{"id": r["id"], "card": card(r, right.get(r["id"], "none") if right else None)} for r in rows]
    outcome = pilot.call_step(args, scratch, items, lambda item: item["card"], schema(), validate, ProbeRunner,
                              BRIEF, "Return the cleaned piece for this group.")
    if outcome is None:
        return 0
    results, dollars, fatal = outcome
    answers = [{"id": item["id"], **result["written"], "dollars": round(result["usage"]["dollars"], 6)}
               for item, result in zip(items, results) if result["written"]]
    pilot.write_lines(guard.safe_output(args.out, scratch), answers)
    print(f"seam probe: {len(items)} groups, {len(answers)} answered; ${dollars:.4f}")
    return 2 if fatal else 0


# ---- seams re-decided under the model's view ------------------------------------------------------------

EDGE_BRIEF = guard.EVALS / "judge" / "SEAM-EDGE-INSTRUCTIONS.md"
OPEN_TAIL = re.compile(r"[\s,;:\u2014-]+$")


def edge_schema():
    return {"type": "object", "properties": {"ending": {"type": "string", "enum": ["complete", "mid_clause"]},
                                             "end_mark": {"type": "string", "enum": ["", ".", "?", "!"]}},
            "required": ["ending", "end_mark"], "additionalProperties": False}


def validate_edge(raw):
    if not isinstance(raw, dict) or set(raw) != {"ending", "end_mark"} or raw["ending"] not in ("complete", "mid_clause") \
            or raw["end_mark"] not in ("", ".", "?", "!") or (raw["ending"] == "complete") != bool(raw["end_mark"]):
        raise verdicts.VerdictError("an edge answer needs ending and a matching end_mark")
    return {"ending": raw["ending"], "end_mark": raw["end_mark"]}


class EdgeRunner(writer.WriterRunner):
    validate = staticmethod(validate_edge)
    tool = "retrain_seam_edge"


def row_index(row):
    return int(row["id"].rsplit("-g", 1)[1])


def answer_of(row):
    return json.loads(row["messages"][2]["content"])


def open_seams(rows, groups_rows):
    """[{id, card}] for every seam to re-decide: the left piece ends open, or the right piece starts in lower case
    and the left piece has no row. `id` names the left group."""
    by_key = {(r["passage"], row_index(r)): r for r in rows}
    seams = []
    for passage in groups_rows:
        groups = passage["groups"]
        for index in range(len(groups) - 1):
            left, right = by_key.get((passage["id"], index)), by_key.get((passage["id"], index + 1))
            left_open = left is not None and not is_closed(answer_of(left)["text"])
            right_lower = right is not None and starts_lower(answer_of(right)["text"]) is True
            if left_open or (left is None and right_lower):
                item = {"draft": groups[index]["draft"]}
                if left is not None:
                    item["piece"] = answer_of(left)["text"]
                seams.append({"id": f"{passage['id']}-g{index}", "card": item})
    return seams


def close_piece(text, mark):
    return OPEN_TAIL.sub("", text.rstrip()) + mark


def capitalised(text):
    stripped = text.lstrip()
    return stripped[:1].upper() + stripped[1:] if stripped[:1].islower() else stripped


def apply_edges(rows, decisions):
    """Rows with the decided seams applied: a `complete` left piece is closed with its mark and the piece after it
    starts with a capital. Everything else, and every seam with no decision, is left as labelled."""
    by_key = {(r["passage"], row_index(r)): r for r in rows}
    changed = {"closed": 0, "capitalised": 0, "kept_open": 0}
    out = {}
    for key, row in by_key.items():
        out[key] = json.loads(json.dumps(row))
    for ident, decision in decisions.items():
        passage, index = ident.rsplit("-g", 1)
        left, right = out.get((passage, int(index))), out.get((passage, int(index) + 1))
        if decision["ending"] != "complete":
            changed["kept_open"] += 1
            continue
        for row, edit, name in ((left, lambda t: close_piece(t, decision["end_mark"]), "closed"), (right, capitalised, "capitalised")):
            if row is None:
                continue
            answer = answer_of(row)
            new = edit(answer["text"])
            if new != answer["text"]:
                changed[name] += 1
                row["messages"][2]["content"] = json.dumps({"text": new, "new_paragraph": answer["new_paragraph"]},
                                                           ensure_ascii=False, separators=(",", ":"))
    return [out[(r["passage"], row_index(r))] for r in rows], changed


def run_edges(args):
    scratch = guard.scratch_roots(args.scratch_dir)
    pilot.check_run_flags(args)
    rows = pilot.read_lines(args.rows, scratch)
    seams = open_seams(rows, pilot.read_lines(args.groups, scratch))
    outcome = pilot.call_step(args, scratch, seams, lambda item: item["card"], edge_schema(), validate_edge, EdgeRunner,
                              EDGE_BRIEF, "Can a sentence end at the end of this group?")
    if outcome is None:
        return 0
    results, dollars, fatal = outcome
    decisions = {seam["id"]: result["written"] for seam, result in zip(seams, results) if result["written"]}
    new_rows, changed = apply_edges(rows, decisions)
    folder = guard.safe_output(args.out, scratch)
    pilot.write_lines(folder / "batch.group_rows.jsonl", new_rows)
    pilot.write_lines(folder / "edge_decisions.jsonl", [{"id": k, **v} for k, v in sorted(decisions.items())])
    pilot.write_lines(folder / "sources.jsonl", pilot.read_lines(args.sources, scratch))
    summary = {"seams": len(seams), "decided": len(decisions),
               "complete": sum(d["ending"] == "complete" for d in decisions.values()), **changed}
    (folder / "edges.summary.json").write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    print(f"seam edges: {json.dumps(summary)}; ${dollars:.4f}")
    return 2 if fatal else 0


def compare_counts(labels, answers):
    """Counts of label -> answer for the end, the start and the flag, over rows present in both."""
    table = {"end": {}, "start": {}, "flag": {}, "rows": 0}
    for ident, label in labels.items():
        answer = answers.get(ident)
        if answer is None:
            continue
        table["rows"] += 1
        gold, got = edges(label["text"], label["new_paragraph"]), edges(answer["text"], answer["new_paragraph"])
        key = f"{'closed' if gold['closed'] else 'open'}->{'closed' if got['closed'] else 'open'}"
        table["end"][key] = table["end"].get(key, 0) + 1
        if gold["lower"] is not None and got["lower"] is not None:
            key = f"{'lower' if gold['lower'] else 'upper'}->{'lower' if got['lower'] else 'upper'}"
            table["start"][key] = table["start"].get(key, 0) + 1
        key = f"{str(gold['paragraph']).lower()}->{str(got['paragraph']).lower()}"
        table["flag"][key] = table["flag"].get(key, 0) + 1
    return table


def run_compare(args):
    scratch = guard.scratch_roots(args.scratch_dir)
    labels = {r["id"]: json.loads(r["messages"][2]["content"]) for r in pilot.read_lines(args.rows, scratch)}
    only = {r["id"] for r in pilot.read_lines(args.only, scratch)} if args.only else None
    if only is not None:
        labels = {k: v for k, v in labels.items() if k in only}
    for path in args.answers:
        answers = {r["id"]: r for r in pilot.read_lines(path, scratch)}
        print(json.dumps({"answers": path, **compare_counts(labels, answers)}, sort_keys=True))
    return 0


def parser():
    cli = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = cli.add_subparsers(dest="command", required=True)
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--scratch-dir", action="append", default=[])
    common.add_argument("--rows", required=True, help="group rows (jsonl) with the whole-message labels")
    probe = commands.add_parser("probe", parents=[common])
    probe.add_argument("--out", required=True)
    probe.add_argument("--groups", help="the batch's groups.jsonl; needed with --right-words")
    probe.add_argument("--right-words", type=int, default=0)
    probe.add_argument("--first", help="rows (jsonl) whose ids are taken before the seeded draw")
    probe.add_argument("--count", type=int, default=0, help="rows to send; 0 for all")
    probe.add_argument("--seed", type=int, default=11)
    edge = commands.add_parser("edges", parents=[common])
    edge.add_argument("--groups", required=True)
    edge.add_argument("--sources", required=True)
    edge.add_argument("--out", required=True, help="new batch folder")
    for target in (probe, edge):
        target.add_argument("--invented-or-public", action="store_true")
        target.add_argument("--model", default=writer.DEFAULT_MODEL)
        target.add_argument("--max-dollars", type=float)
        target.add_argument("--scale-run", action="store_true", help="use the explicit total cap instead of the pilot ceiling")
        target.add_argument("--dry-run", action="store_true")
        target.add_argument("--state-dir", required=True)
        target.add_argument("--key-file", default=guard.DEFAULT_KEY_FILE)
        target.add_argument("--base-url", default=f"https://{client_module.API_HOST}")
        target.add_argument("--workers", type=int, default=4)
        target.add_argument("--max-tokens", type=int, default=1_000)
        target.add_argument("--effort", choices=("low", "medium", "high", "xhigh", "max"))
        target.add_argument("--est-output-tokens", type=int, default=120)
        target.add_argument("--max-retries", type=int, default=5)
        target.add_argument("--timeout", type=float, default=300.0)
        client_module.add_prompt_cache_flag(target)
    compare = commands.add_parser("compare", parents=[common])
    compare.add_argument("--answers", action="append", required=True)
    compare.add_argument("--only", help="rows (jsonl) whose ids limit the comparison")
    return cli


def main(argv=None):
    args = parser().parse_args(argv)
    try:
        return {"probe": run_probe, "edges": run_edges, "compare": run_compare}[args.command](args)
    except (writer.WriterError, GuardError, api_judge.JudgeError, verdicts.VerdictError, OSError, KeyError) as exc:
        print(f"retrain-seamview: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
