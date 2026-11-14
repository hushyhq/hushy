#!/usr/bin/env python3
"""Report for scripts/gate-cleanup.sh: base versus candidate, per set and model.

    python3 -I scripts/gate_cleanup_report.py --out DIR --base-label L --cand-label L \
        --models intent,v54 --sets pub,golden,never,probe,misheard,long \
        --pub-refs FILE --golden FILE --misheard FILE --long FILE --live FILE [--fail-on-regression]

Reads what the shell script left under DIR/base and DIR/cand:
- `<model>-<set>.jsonl` from `murmur-eval intent-app` (sets pub, golden, never, probe, misheard),
- `<model>-long/` from `murmur-eval early-clean` (set long: the long and live dev dictations),
- `<arm>/<model>-<set>.status` holding the exit code of that run,
- `<arm>/vocab-boost.status` and `<arm>/vocab-summary.json` from `murmur-eval vocab-real-boost` (set vocab; record
  only, it never adds a failure),
- `notes.txt` with one line per skipped run.
Prints one table, writes `changed.md` (every changed text, side by side) and `summary.json`.
Exit 0, or 1 with --fail-on-regression when the public exact score drops, a set's used-model
count drops, a long dictation goes from cleaned to raw, any pipeline step's made-worse total rises
on the candidate, or a run failed.

Only invented or public text goes through here. Never point it at a sealed set."""

import argparse
from collections import Counter
import json
from pathlib import Path
import subprocess
import sys

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
INTENT_SETS = ("pub", "golden", "never", "probe", "misheard")
MADE_WORSE_STEPS = ("boosted", "fixers", "model", "checks")
WORST_SETS = frozenset({"pub", "golden"})


def read_jsonl(path):
    with Path(path).open(encoding="utf-8") as handle:
        return [json.loads(line) for line in handle if line.strip()]


def squash(text):
    return " ".join(str(text).split())


def reference_map_for_set(args, name):
    """{id: reference text} for made-worse scoring."""
    source = {"pub": args.pub_refs, "golden": args.golden, "misheard": args.misheard,
              "never": args.never, "probe": args.probe}[name]
    path = Path(source)
    if name == "golden":
        rows = json.loads(path.read_text(encoding="utf-8"))
        return {row["id"]: row["expected"] for row in rows}
    rows = read_jsonl(path) if path.suffix != ".json" else json.loads(path.read_text(encoding="utf-8"))
    if name == "pub":
        return {row["id"]: row["reference"] for row in rows}
    # never, probe and misheard have no written reference; scoring against what was spoken would count
    # every intended rewrite as made worse. Their own checks (refusals, digits, repairs) cover them.
    return {}


def made_worse_totals(rows_path, reference_by_id):
    from gate_cleanup_made_worse import read_jsonl, score_row
    totals = {step: {"worse": 0, "better": 0} for step in MADE_WORSE_STEPS}
    scored_rows = 0
    for row in read_jsonl(rows_path):
        if not row.get("steps") or row["id"] not in reference_by_id:
            continue
        scored_rows += 1
        for step, counts in score_row(reference_by_id[row["id"]], row["steps"]).items():
            totals[step]["worse"] += counts["worse"]
            totals[step]["better"] += counts["better"]
    return totals, scored_rows


def made_worse_worst(rows_path, reference_by_id, limit=5):
    from gate_cleanup_made_worse import read_jsonl, score_row, STEPS
    rows_by_id = {row["id"]: row for row in read_jsonl(rows_path)}
    examples = []
    for ident, row in rows_by_id.items():
        if ident not in reference_by_id or not row.get("steps"):
            continue
        for step, counts in score_row(reference_by_id[ident], row["steps"]).items():
            if counts["worse"] <= 0:
                continue
            before = row["steps"][STEPS[STEPS.index(step) - 1]]
            after = row["steps"][step]
            examples.append((counts["worse"], ident, step, reference_by_id[ident], before, after))
    examples.sort(key=lambda item: -item[0])
    return examples[:limit]


def load_arm(directory, model, name):
    """Rows by id for one intent-app run, or (None, reason) when it did not produce a file."""
    status = directory / f"{model}-{name}.status"
    code = status.read_text().strip() if status.exists() else "missing"
    path = directory / f"{model}-{name}.jsonl"
    if code != "0" or not path.exists():
        return None, f"run failed (exit {code})"
    return {row["id"]: row for row in read_jsonl(path)}, None


def public_exact(out, arm, model, outputs, refs):
    verdicts = out / arm / f"{model}-pub.verdicts.jsonl"
    result = subprocess.run(
        [sys.executable, "-I", str(HERE / "retrain_public_eval.py"), "score", "--outputs", str(outputs),
         "--references", str(refs), "--verdicts", str(verdicts)], capture_output=True, text=True)
    if result.returncode != 0:
        return None
    for line in result.stdout.splitlines():
        if line.startswith("exact "):
            return int(line.split()[-1])
    return None


def golden_matches(rows, golden):
    expected = {case["id"]: squash(case["expected"]) for case in json.loads(Path(golden).read_text())}
    return sum(1 for ident, row in rows.items() if squash(row["text"]) == expected.get(ident))


def misheard_counts(out, arm, model, outputs, cases):
    result = subprocess.run([sys.executable, "-I", str(HERE / "misheard_score.py"), str(cases), str(outputs)],
                            capture_output=True, text=True)
    (out / arm / f"{model}-misheard.score.txt").write_text(result.stdout + result.stderr)
    counts = {}
    for line in result.stdout.splitlines():
        if line.startswith("case "):
            for part in line.split(None, 1)[1].split(","):
                key, _, value = part.strip().partition("=")
                if value.isdigit():
                    counts[key] = int(value)
    return counts


def reasons(rows):
    return Counter(str(row.get("rejection"))[:48] for row in rows.values()
                   if not row.get("usedModel") and row.get("rejection") not in (None, "None"))


def load_vocab(directory):
    """The vocab-real-boost summary of one arm, or (None, reason)."""
    status = directory / "vocab-boost.status"
    code = status.read_text().strip() if status.exists() else "missing"
    path = directory / "vocab-summary.json"
    if code != "0" or not path.exists():
        return None, f"run failed (exit {code})" if code != "0" else "wrote no summary (no vocab-real-boost command?)"
    return json.loads(path.read_text(encoding="utf-8")), None


def vocab_block(out, summary, notes):
    """Record base versus candidate for the vocab set. Never a failure: the baseline is still being recorded."""
    base, base_err = load_vocab(out / "base")
    cand, cand_err = load_vocab(out / "cand")
    if cand is None:
        notes.append(f"vocab: candidate {cand_err}; no vocab numbers")
        return
    if base is None:
        notes.append(f"vocab: base {base_err}; a base without the vocab-real-boost command is expected; candidate numbers only")
    summary["vocab"] = {"base": base, "cand": cand}


def print_vocab(summary):
    block = summary.get("vocab")
    if not block:
        return
    base, cand = block["base"], block["cand"]
    print("\nvocab boost on invented speech (record only, never fails the gate; base -> candidate):")
    if base is None:
        print("  (base has no vocab-real-boost; candidate numbers only)")

    def pair(key_path):
        def dig(report):
            if report is None:
                return None
            value = report
            for key in key_path:
                value = value[key]
            return value
        return dig(base), dig(cand)

    def line(label, key_path):
        old, new = pair(key_path)
        print(f"  {label:58} {old} -> {new}" if old is not None else f"  {label:58} {new}")

    harm_rows = cand["harm"]["rows"]
    line(f"harm: rows made worse at the boost (of {harm_rows})", ("harm", "rowsWorseAtBoost"))
    line(f"harm: rows made worse after the guard (of {harm_rows})", ("harm", "rowsWorseAfterGuard"))
    line("harm: words made worse at the boost", ("harm", "wordsWorseAtBoost"))
    line("harm: words made worse after the guard", ("harm", "wordsWorseAfterGuard"))
    terms = cand["win"]["terms"]
    for label, key in (("recogniser", "foundInRecogniser"), ("after boost", "foundAfterBoost"), ("after guard", "foundAfterGuard")):
        line(f"win: expected spellings found, {label} (of {terms})", ("win", key))
    by_source = cand["harm"].get("rowsWorseAfterGuardBySource", {})
    print("  harmful rows after the guard, by source: " + (", ".join(f"{k} {v}" for k, v in sorted(by_source.items())) or "none"))
    print(f"  run time {cand['seconds']:.0f} s")


def arrow(base, cand):
    return f"{base}->{cand}" if base != cand else f"{base}"


def made_worse_block(args, out, model, name, failures, summary, worst_acc):
    if model != "intent":
        return
    base_path, cand_path = out / "base" / f"{model}-{name}.jsonl", out / "cand" / f"{model}-{name}.jsonl"
    if not base_path.exists() or not cand_path.exists():
        return
    refs = reference_map_for_set(args, name)
    base_totals, base_scored = made_worse_totals(base_path, refs)
    cand_totals, cand_scored = made_worse_totals(cand_path, refs)
    summary[f"{model}/{name}/madeWorse"] = {
        "base": base_totals, "cand": cand_totals, "baseScoredRows": base_scored, "candScoredRows": cand_scored}
    if base_scored > 0:
        for step in MADE_WORSE_STEPS:
            if cand_totals[step]["worse"] > base_totals[step]["worse"]:
                failures.append(
                    f"{model} {name} made-worse/{step} rose {base_totals[step]['worse']} -> {cand_totals[step]['worse']}")
    if name in WORST_SETS:
        worst_acc.extend((name, item) for item in made_worse_worst(cand_path, refs))


def intent_block(args, out, model, name, table, changed, summary, failures, worst_acc):
    base, base_err = load_arm(out / "base", model, name)
    cand, cand_err = load_arm(out / "cand", model, name)
    if base is None or cand is None:
        problem = "; ".join(f"{arm}: {err}" for arm, err in (("base", base_err), ("cand", cand_err)) if err)
        table.append((name, model, "-", "-", "-", "-", f"ERROR {problem}"))
        failures.append(f"{model} {name}: {problem}")
        return
    shared = sorted(base.keys() & cand.keys())
    differing = [ident for ident in shared if base[ident]["text"] != cand[ident]["text"]]
    used_base = sum(1 for row in base.values() if row.get("usedModel"))
    used_cand = sum(1 for row in cand.values() if row.get("usedModel"))
    score = "-"
    if name == "pub":
        exact_base = public_exact(out, "base", model, out / "base" / f"{model}-pub.jsonl", args.pub_refs)
        exact_cand = public_exact(out, "cand", model, out / "cand" / f"{model}-pub.jsonl", args.pub_refs)
        score = f"exact {arrow(exact_base, exact_cand)}"
        summary[f"{model}/pub/exact"] = [exact_base, exact_cand]
        if exact_base is None or exact_cand is None:
            failures.append(f"{model} pub: the public scorer failed")
        elif exact_cand < exact_base:
            failures.append(f"{model} pub exact dropped {exact_base} -> {exact_cand}")
    elif name == "golden":
        match_base, match_cand = golden_matches(base, args.golden), golden_matches(cand, args.golden)
        score = f"match {arrow(match_base, match_cand)}"
    elif name == "misheard":
        counts_base = misheard_counts(out, "base", model, out / "base" / f"{model}-misheard.jsonl", args.misheard)
        counts_cand = misheard_counts(out, "cand", model, out / "cand" / f"{model}-misheard.jsonl", args.misheard)
        score = "repaired " + arrow(counts_base.get("repaired", "?"), counts_cand.get("repaired", "?"))
        if "deleted" in counts_base or "deleted" in counts_cand:
            score += ", deleted " + arrow(counts_base.get("deleted", 0), counts_cand.get("deleted", 0))
    if used_cand < used_base:
        failures.append(f"{model} {name}: used-model count dropped {used_base} -> {used_cand}")
    reasons_base, reasons_cand = reasons(base), reasons(cand)
    text = ", ".join(f"{reason} {arrow(reasons_base[reason], reasons_cand[reason])}"
                     for reason in sorted(reasons_base.keys() | reasons_cand.keys())) or "none"
    table.append((name, model, str(len(shared)), arrow(used_base, used_cand), score, str(len(differing)), text))
    summary[f"{model}/{name}"] = {"rows": len(shared), "used": [used_base, used_cand], "changed": len(differing)}
    for ident in differing:
        changed.append((f"{name} / {model} / {ident}", base[ident].get("spoken") or case_text(args, name, ident),
                        base[ident]["text"], cand[ident]["text"]))
    made_worse_block(args, out, model, name, failures, summary, worst_acc)


_CASE_CACHE = {}


def case_text(args, name, ident):
    """The spoken text of one case, for the changed list (intent-app rows do not carry it)."""
    source = {"pub": args.pub_refs, "golden": args.golden, "misheard": args.misheard,
              "never": args.never, "probe": args.probe}[name]
    if name not in _CASE_CACHE:
        path = Path(source)
        rows = json.loads(path.read_text()) if path.suffix == ".json" else read_jsonl(path)
        _CASE_CACHE[name] = {row["id"]: row.get("spoken", "") for row in rows}
    return _CASE_CACHE[name].get(ident, "")


def spoken_by_id(args):
    spoken = {}
    for label, path in (("long", args.long), ("live", args.live)):
        for row in read_jsonl(path):
            spoken[(label, row["id"])] = row["spoken"]
    return spoken


def long_outputs(out, arm, model):
    directory = out / arm / f"{model}-long"
    status = out / arm / f"{model}-long.status"
    code = status.read_text().strip() if status.exists() else "missing"
    files = sorted(directory.glob(f"{model}-*.json")) if directory.exists() else []
    if code != "0" or not files:
        return None, f"run failed (exit {code})"
    arm_file = json.loads(files[0].read_text())
    return {(row["set"], row["id"]): row["output"] for row in arm_file["dictations"]}, None


def long_block(args, out, model, spoken, table, changed, summary, failures):
    base, base_err = long_outputs(out, "base", model)
    cand, cand_err = long_outputs(out, "cand", model)
    if base is None or cand is None:
        problem = "; ".join(f"{arm}: {err}" for arm, err in (("base", base_err), ("cand", cand_err)) if err)
        table.append(("long+live", model, "-", "-", "-", "-", f"ERROR {problem}"))
        failures.append(f"{model} long: {problem}")
        return
    keys = sorted(base.keys() & cand.keys())
    raw = lambda key, text: squash(text) == squash(spoken.get(key, ""))  # noqa: E731
    cleaned_base = sum(1 for key in keys if not raw(key, base[key]))
    cleaned_cand = sum(1 for key in keys if not raw(key, cand[key]))
    differing = [key for key in keys if squash(base[key]) != squash(cand[key])]
    to_raw = [key for key in differing if not raw(key, base[key]) and raw(key, cand[key])]
    to_clean = [key for key in differing if raw(key, base[key]) and not raw(key, cand[key])]
    if to_raw:
        failures.append(f"{model} long: {len(to_raw)} dictation(s) went from cleaned to raw: "
                        + ", ".join(f"{s}/{i}" for s, i in to_raw[:8]))
    table.append(("long+live", model, str(len(keys)), "-", f"cleaned {arrow(cleaned_base, cleaned_cand)}",
                  str(len(differing)), f"cleaned->raw {len(to_raw)}, raw->cleaned {len(to_clean)}"))
    summary[f"{model}/long"] = {"dictations": len(keys), "cleaned": [cleaned_base, cleaned_cand],
                                "changed": len(differing), "cleaned_to_raw": len(to_raw)}
    for key in differing:
        changed.append((f"long / {model} / {key[0]}/{key[1]}", spoken.get(key, ""), base[key], cand[key]))


def fence(text):
    return "```text\n" + str(text).replace("```", "'''") + "\n```\n"


def write_changed(path, changed, args):
    lines = [f"# Changed texts: base {args.base_label} versus candidate {args.cand_label}", "",
             f"{len(changed)} changed text(s). Invented or public text only. Do not paste this file anywhere public.", ""]
    for title, spoken, before, after in changed:
        lines += [f"## {title}", "", "spoken", "", fence(spoken), "base", "", fence(before), "candidate", "", fence(after)]
    path.write_text("\n".join(lines), encoding="utf-8")


def print_table(table, args, notes):
    header = ("set", "model", "rows", "used model", "score", "changed", "refusal reasons / other")
    widths = [max(len(str(row[i])) for row in [header] + table) for i in range(len(header))]
    print(f"\ncleanup gate: base {args.base_label}  versus  candidate {args.cand_label}\n")
    for row in [header, tuple("-" * w for w in widths)] + table:
        print("  ".join(str(cell).ljust(width) for cell, width in zip(row, widths)).rstrip())
    for note in notes:
        print(f"note: {note}")


def write_made_worse_worst(path, examples):
    lines = ["# Made-worse examples (candidate, public or golden only)", ""]
    for set_name, (worse, ident, step, reference, before, after) in examples:
        lines += [
            f"## {set_name} / {ident} / {step} (worse={worse})",
            "", "reference", "", fence(reference), "before step", "", fence(before), "after step", "", fence(after), ""]
    path.write_text("\n".join(lines), encoding="utf-8")


def print_made_worse(summary, models, sets):
    rows = []
    for model in models:
        for name in INTENT_SETS:
            if name not in sets or model != "intent":
                continue
            key = f"{model}/{name}/madeWorse"
            if key not in summary:
                continue
            block = summary[key]
            compare = block.get("baseScoredRows", 0) > 0
            for step in MADE_WORSE_STEPS:
                base = block["base"][step]["worse"]
                cand = block["cand"][step]["worse"]
                rows.append((name, step, base, cand, block["cand"][step]["better"], compare))
    if not rows:
        return
    print("\nmade-worse (words newly wrong vs reference, per step; base -> candidate):")
    if rows and not rows[0][5]:
        print("  (base had no step trace; totals below are candidate-only, no made-worse regression check)")
    for name, step, base, cand, better, compare in rows:
        mark = " REGRESSION" if compare and cand > base else ""
        print(f"  {name:8} {step:8} worse {base}->{cand}  better-on-cand {better}{mark}")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    for name in ("out", "base-label", "cand-label", "models", "sets", "pub-refs", "golden", "misheard", "never",
                 "probe", "long", "live"):
        parser.add_argument(f"--{name}", required=True)
    parser.add_argument("--fail-on-regression", action="store_true")
    args = parser.parse_args(argv)
    out = Path(args.out)
    models, sets = args.models.split(","), args.sets.split(",")
    table, changed, summary, failures, worst_made_worse = [], [], {}, [], []
    notes_file = out / "notes.txt"
    notes = notes_file.read_text().splitlines() if notes_file.exists() else []
    spoken = spoken_by_id(args) if "long" in sets else {}
    if "vocab" in sets:
        vocab_block(out, summary, notes)
    for model in models:
        for name in INTENT_SETS:
            if name in sets and model == "intent":
                intent_block(args, out, model, name, table, changed, summary, failures, worst_made_worse)
        if "long" in sets:
            long_block(args, out, model, spoken, table, changed, summary, failures)
    print_table(table, args, notes)
    print_made_worse(summary, models, sets)
    print_vocab(summary)
    write_changed(out / "changed.md", changed, args)
    if worst_made_worse:
        worst_made_worse.sort(key=lambda item: -item[1][0])
        write_made_worse_worst(out / "made-worse-worst.md", worst_made_worse[:5])
        print(f"\nmade-worse worst examples: {out / 'made-worse-worst.md'}")
    summary["changed_texts"] = len(changed)
    summary["failures"] = failures
    (out / "summary.json").write_text(json.dumps(summary, indent=1, sort_keys=True) + "\n")
    print(f"\nchanged texts: {len(changed)}  (list: {out / 'changed.md'})")
    if failures:
        print("regressions / errors:")
        for failure in failures:
            print(f"  - {failure}")
    else:
        print("regressions / errors: none")
    if args.fail_on_regression and failures:
        sys.exit(1)


if __name__ == "__main__":
    main()
