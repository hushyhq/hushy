#!/usr/bin/env python3
"""Made-worse step metrics for scripts/gate-cleanup.sh.

Reads intent-app JSONL rows that include a `steps` object (recogniser, boosted, fixers, model, checks)
and scores each step transition against the set's reference text. Uses the same word stream as the
public scorer (retrain_public_normalise.similarity_words). Speech-only filler removal does not count
as worse when the normalized stream is unchanged.

    python3 -I scripts/gate_cleanup_made_worse.py score --rows PATH --reference-map PATH --out PATH
    python3 -I scripts/gate_cleanup_made_worse.py compare --base PATH --cand PATH --out PATH [--fail-on-regression]

Invented or public text only."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from retrain_public_normalise import similarity_words  # noqa: E402

STEPS = ("recognizer", "boosted", "fixers", "model", "checks")
TRANSITION_STEPS = STEPS[1:]


def read_jsonl(path):
    with Path(path).open(encoding="utf-8") as handle:
        return [json.loads(line) for line in handle if line.strip()]


def matched_reference_indices(reference, hypothesis):
    ref, hyp = similarity_words(reference), similarity_words(hypothesis)
    n, m = len(ref), len(hyp)
    if not n:
        return set()
    lcs = [[0] * (m + 1) for _ in range(n + 1)]
    for i in range(n - 1, -1, -1):
        for j in range(m - 1, -1, -1):
            lcs[i][j] = lcs[i + 1][j + 1] + 1 if ref[i] == hyp[j] else max(lcs[i + 1][j], lcs[i][j + 1])
    matched, i, j = set(), 0, 0
    while i < n and j < m:
        if ref[i] == hyp[j]:
            matched.add(i)
            i += 1
            j += 1
        elif lcs[i + 1][j] >= lcs[i][j + 1]:
            i += 1
        else:
            j += 1
    return matched


def transition(reference, before, after):
    if similarity_words(before) == similarity_words(after):
        return {"worse": 0, "better": 0}
    ref = similarity_words(reference)
    if not ref:
        return {"worse": 0, "better": 0}
    before_ok = matched_reference_indices(reference, before)
    after_ok = matched_reference_indices(reference, after)
    return {"worse": len(before_ok - after_ok), "better": len(after_ok - before_ok)}


def score_row(reference, steps):
    per_step = {}
    for index, step in enumerate(TRANSITION_STEPS):
        before = steps.get(STEPS[index], "")
        after = steps.get(step, "")
        per_step[step] = transition(reference, before, after)
    return per_step


def load_reference_map(path):
    data = json.loads(Path(path).read_text(encoding="utf-8"))
    return data


def score_file(rows_path, reference_by_id):
    rows = read_jsonl(rows_path)
    scored = []
    totals = {step: {"worse": 0, "better": 0} for step in TRANSITION_STEPS}
    for row in rows:
        ident = row["id"]
        steps = row.get("steps")
        if not steps or ident not in reference_by_id:
            continue
        per_step = score_row(reference_by_id[ident], steps)
        scored.append({"id": ident, "perStep": per_step})
        for step, counts in per_step.items():
            totals[step]["worse"] += counts["worse"]
            totals[step]["better"] += counts["better"]
    return {"rows": scored, "totals": totals}


def worst_examples(scored_rows, reference_by_id, rows_by_id, limit=5):
    examples = []
    for item in scored_rows:
        ident = item["id"]
        steps = rows_by_id[ident]["steps"]
        ref = reference_by_id[ident]
        for step, counts in item["perStep"].items():
            if counts["worse"] <= 0:
                continue
            before = steps[STEPS[STEPS.index(step) - 1]]
            after = steps[step]
            examples.append((counts["worse"], ident, step, ref, before, after))
    examples.sort(key=lambda row: -row[0])
    return examples[:limit]


def compare_totals(base, cand):
    regressions = []
    lines = []
    for step in TRANSITION_STEPS:
        b, c = base["totals"][step]["worse"], cand["totals"][step]["worse"]
        lines.append(f"  {step}: made-worse {b} -> {c}")
        if c > b:
            regressions.append(f"{step} made-worse rose {b} -> {c}")
    return lines, regressions


def cmd_score(args):
    reference_by_id = load_reference_map(args.reference_map)
    result = score_file(args.rows, reference_by_id)
    Path(args.out).write_text(json.dumps(result, indent=1, sort_keys=True) + "\n", encoding="utf-8")
    print(f"made-worse: scored {len(result['rows'])} row(s) -> {args.out}")
    for step in TRANSITION_STEPS:
        t = result["totals"][step]
        print(f"  {step}: worse={t['worse']} better={t['better']}")


def cmd_compare(args):
    base = json.loads(Path(args.base).read_text(encoding="utf-8"))
    cand = json.loads(Path(args.cand).read_text(encoding="utf-8"))
    lines, regressions = compare_totals(base, cand)
    report = {"base": base["totals"], "cand": cand["totals"], "regressions": regressions}
    if args.reference_map and args.base_rows and args.cand_rows:
        ref = load_reference_map(args.reference_map)
        base_rows = {row["id"]: row for row in read_jsonl(args.base_rows)}
        cand_rows = {row["id"]: row for row in read_jsonl(args.cand_rows)}
        report["worst"] = [
            {"worse": w, "id": ident, "step": step, "reference": ref[:120], "before": before[:120], "after": after[:120]}
            for w, ident, step, ref, before, after in worst_examples(cand["rows"], ref, cand_rows)
        ]
    Path(args.out).write_text(json.dumps(report, indent=1, sort_keys=True) + "\n", encoding="utf-8")
    print("made-worse totals (base -> candidate):")
    print("\n".join(lines))
    if regressions:
        print("regressions:")
        for line in regressions:
            print(f"  - {line}")
    if args.fail_on_regression and regressions:
        sys.exit(1)


def build_reference_map(args):
    """Write {id: reference} JSON for one gate set."""
    path = Path(args.input)
    if path.suffix == ".json":
        rows = json.loads(path.read_text(encoding="utf-8"))
        if args.set == "golden":
            mapping = {row["id"]: row["expected"] for row in rows}
        else:
            mapping = {row["id"]: row.get("expected") or row.get("reference") or row["spoken"] for row in rows}
    else:
        rows = read_jsonl(path)
        if args.set in ("pub", "long", "live"):
            mapping = {row["id"]: row["reference"] for row in rows}
        else:
            mapping = {row["id"]: row["spoken"] for row in rows}
    Path(args.out).write_text(json.dumps(mapping, indent=0, sort_keys=True) + "\n", encoding="utf-8")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    score = sub.add_parser("score")
    score.add_argument("--rows", required=True)
    score.add_argument("--reference-map", required=True)
    score.add_argument("--out", required=True)
    score.set_defaults(func=cmd_score)

    compare = sub.add_parser("compare")
    compare.add_argument("--base", required=True)
    compare.add_argument("--cand", required=True)
    compare.add_argument("--out", required=True)
    compare.add_argument("--reference-map")
    compare.add_argument("--base-rows")
    compare.add_argument("--cand-rows")
    compare.add_argument("--fail-on-regression", action="store_true")
    compare.set_defaults(func=cmd_compare)

    ref = sub.add_parser("reference-map")
    ref.add_argument("--set", required=True)
    ref.add_argument("--input", required=True)
    ref.add_argument("--out", required=True)
    ref.set_defaults(func=lambda args: build_reference_map(args))

    args = parser.parse_args(argv)
    args.func(args)


if __name__ == "__main__":
    main()
