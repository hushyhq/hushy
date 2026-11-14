#!/usr/bin/env python3
"""Resumable speech-first batch. Dry-run prints the plan; --execute runs the steps.

All generated paths stay under Evals/runs/retrain. One state ledger and one cap
cover notes, speech, typed writing and v4.1 labels.
"""

import argparse
from collections import Counter
import json
import math
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
sys.path.insert(0, str(ROOT / "scripts" / "finetune"))
import shapes  # noqa: E402
from pathguard import DEV_SET_ALLOWLIST, INDEX_ONLY_DEV_SETS  # noqa: E402

import retrain_groups_cli as group_cli  # noqa: E402
import retrain_pilot as pilot  # noqa: E402
import retrain_pilot_steps as pilot_steps  # noqa: E402
import retrain_release as release  # noqa: E402
import retrain_speech_plan as planner  # noqa: E402
import retrain_provenance as provenance  # noqa: E402


def _read(path):
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line]


def _write(path, rows):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in rows), encoding="utf-8")


def dev_index():
    """Use the existing fine-tune n-gram index over its named safe sets."""
    sets = {}
    for name in DEV_SET_ALLOWLIST + INDEX_ONLY_DEV_SETS:
        path = ROOT / "Evals" / name
        if path.is_file():
            obj = json.loads(path.read_text(encoding="utf-8"))
            if isinstance(obj, list):
                sets[name] = obj
    return shapes.ContaminationIndex(sets)


def screen(rows, index):
    """Drop exact/near duplicate passages, and passages overlapping named dev sets."""
    kept, refused, seen = [], [], set()
    for row in rows:
        text = row["spoken"]
        grams = pilot_steps.shingles(text)
        normalized = shapes.normalized(text)
        reason = None
        if any(normalized == prior or (grams and prior_grams and
               len(grams & prior_grams) / len(grams | prior_grams) >= pilot_steps.DUPLICATE_JACCARD)
               for prior, prior_grams in seen):
            reason = "batch_duplicate"
        elif index and (index.hits(text) or index.near(text)):
            reason = "dev_overlap"
        if reason:
            refused.append({"id": row["id"], "reason": reason})
        else:
            kept.append(row)
            seen.add((normalized, frozenset(grams)))
    return kept, refused


def select_targets(targets, sources, count):
    """Prefer quota coverage, then keep as many screened labels as available."""
    available = [t for t in targets if t["id"] in sources]
    agent_need = (3 * count + 9) // 10
    long_need = (count + 1) // 2
    selected, ids = [], set()

    def take(predicate, needed):
        for target in available:
            if needed <= 0:
                break
            if target["id"] not in ids and predicate(sources[target["id"]]):
                selected.append(target)
                ids.add(target["id"])
                needed -= 1
        return needed

    is_long = lambda s: len(s["spoken"].split()) > 120
    # First meet both quotas with the same examples where possible.
    take(lambda s: s["family"] == "agent" and is_long(s), min(agent_need, long_need))
    agent_need -= sum(sources[t["id"]]["family"] == "agent" for t in selected)
    long_need -= sum(is_long(sources[t["id"]]) for t in selected)
    take(lambda s: s["family"] == "agent", agent_need)
    long_need = (count + 1) // 2 - sum(is_long(sources[t["id"]]) for t in selected)
    take(is_long, long_need)
    take(lambda s: True, count - len(selected))
    return selected


def selection_status(selected, sources, count):
    actual = len(selected)
    agent = sum(sources[t["id"]]["family"] == "agent" for t in selected)
    long = sum(len(sources[t["id"]]["spoken"].split()) > 120 for t in selected)
    quotas = {"agent": {"requested_share": 0.3, "actual_share": agent / actual if actual else 0,
                         "requested_count": math.ceil(count * 0.3), "actual_count": agent},
              "over_120_words": {"requested_share": 0.5, "actual_share": long / actual if actual else 0,
                                 "requested_count": math.ceil(count * 0.5), "actual_count": long}}
    return {"complete": actual == count and all(q["actual_count"] >= q["requested_count"] for q in quotas.values()),
            "shortfall": count - actual, "quotas": quotas}


def screen_provenance(targets, groups, checker=provenance.check):
    accepted, refused = [], []
    for target in targets:
        findings = checker(groups[target["id"]], target)
        if findings:
            refused.append({"id": target["id"], "target": target, "findings": findings})
        else:
            accepted.append(target)
    return accepted, refused


def finding_counts(refused):
    return dict(Counter(kind for row in refused
                        for kind in {finding["kind"] for finding in row["findings"]}))


def cost_estimate(count, factor):
    attempts = math.ceil(count * factor)
    after_checks = attempts * 33 / 45
    return {"attempted_passages": attempts,
            "expected_surviving_labels": after_checks * 39 / 48,
            "expected_spend_dollars": round(attempts * (0.01445 + 0.02797 + 0.02228)
                                            + after_checks * 0.04390, 2)}


def manifest(plan, counts, failures, sources=None):
    result = {"planned": {"count": len(plan),
                        "family": dict(Counter(s["family"] for s in plan)),
                        "app": dict(Counter(release.bundle_for(s["family"]) for s in plan)),
                        "length_band": dict(Counter(f"{s['band'][0]}-{s['band'][1]}" for s in plan)),
                        "features": {key: sum(bool(s["facts"].get(key)) for s in plan)
                                     for key in ("files", "times", "dates")}
                        | {"corrections": sum(bool(s["plants"]) for s in plan),
                           "restarts": sum(any("restart" in p for p in s["plants"]) for s in plan)}},
            "counts_by_step": counts, "failures_by_step": failures}
    if sources is not None:
        result["passages"] = {"count": len(sources),
                              "family": dict(Counter(s["family"] for s in sources)),
                              "app": dict(Counter(release.bundle_for(s["family"]) for s in sources)),
                              "length_band": dict(Counter(str(s.get("band")) for s in sources)),
                              "corrections": sum(bool(s.get("plants")) for s in sources),
                              "restarts": sum(any("restart" in p.get("kind", "") for p in s.get("plants", [])) for s in sources),
                              "code_tokens": sum(bool(s.get("planned_facts", {}).get("files")) or
                                                 any(c in s["spoken"] for c in ("_", "--", ".py", ".swift"))
                                                 for s in sources),
                              "times": sum(bool(s.get("planned_facts", {}).get("times")) for s in sources)}
    return result


def _command(*parts):
    return [str(x) for x in parts]


def run(args):
    out = Path(args.out)
    safe_root = (ROOT / "Evals/runs/retrain").resolve()
    if out.is_absolute() or not (ROOT / out).resolve().is_relative_to(safe_root) \
            or any(x in str(out).lower() for x in ("heldout", "voicelab", "voice lab")):
        raise ValueError("--out must be a safe directory under Evals/runs/retrain")
    estimate = cost_estimate(args.count, args.attempt_factor)
    plan = planner.scale_plan(estimate["attempted_passages"], args.seed)
    plan_path = out / "plan.jsonl"
    state = out / "state"
    prefix = out / "batch"
    facts = Path(str(prefix) + ".facts.jsonl")
    sources = out / "sources.jsonl"
    groups_in = out / "groups_in.jsonl"
    groups = out / "groups.jsonl"
    targets = Path(str(prefix) + ".targets.jsonl")
    clean_targets = out / "targets_screened.jsonl"
    verdicts_in = Path(str(prefix) + ".verdicts_in.jsonl")
    verdicts_out = out / "verdicts_out.jsonl"
    py = [sys.executable, "-I"]
    call_flags = ["--invented-or-public", "--max-dollars", args.max_dollars,
                  "--state-dir", state, "--workers", args.workers]
    scale_flags = [*call_flags, "--scale-run"]
    steps = [
        ("notes", Path(str(prefix) + ".notes.jsonl"), _command(*py, "scripts/retrain_speech.py", "notes", "--plan", plan_path, "--out", prefix, *scale_flags)),
        ("speech", Path(str(prefix) + ".speech.jsonl"), _command(*py, "scripts/retrain_speech.py", "speech", "--notes", str(prefix) + ".notes.jsonl", "--pool", args.pool, "--out", prefix, *scale_flags)),
        ("writer", Path(str(prefix) + ".writer.accepted.jsonl"), _command(*py, "scripts/retrain_writer.py", "write", "--passages", str(prefix) + ".for_writer.jsonl", "--out", str(prefix) + ".writer", *call_flags)),
        ("facts", facts, _command(*py, "scripts/retrain_speech.py", "facts", "--speech", str(prefix) + ".speech.jsonl", "--writer", str(prefix) + ".writer", "--out", prefix, "--invented-or-public")),
        ("groups", groups, _command(".build/debug/murmur-eval", "finetune", "groups", "--in", groups_in, "--out", groups)),
        ("labels", targets, _command(*py, "scripts/retrain_release_cli.py", "relabel", "--sources", sources, "--groups", groups, "--out", prefix, "--label-version", "v4.1", *scale_flags)),
        ("verdict_input", verdicts_in, _command(*py, "scripts/retrain_release_cli.py", "verdicts-in", "--sources", sources, "--groups", groups, "--targets", clean_targets, "--out", prefix)),
        ("verdicts", verdicts_out, _command(".build/debug/murmur-eval", "finetune", "verdicts", "--in", verdicts_in, "--out", verdicts_out)),
        ("report", Path(str(prefix) + ".group_rows.jsonl"), _command(*py, "scripts/retrain_release_cli.py", "report", "--sources", sources, "--groups", groups, "--targets", clean_targets, "--verdicts", verdicts_out, "--out", prefix, "--md", out / "report.md")),
    ]
    if not args.execute:
        print(json.dumps({"dry_run": True, "requested_labels": args.count,
                          "attempt_factor": args.attempt_factor, "pilot_estimate": estimate,
                          "manifest": manifest(plan, {}, {}),
                          "steps": [{"step": name, "command": cmd} for name, _, cmd in steps]}, indent=2))
        return 0
    if plan_path.exists() and _read(plan_path) != plan:
        raise ValueError("existing plan differs; resume with the same count and seed")
    if not plan_path.exists():
        _write(plan_path, plan)
    counts, failures = {}, {}
    for name, output, command in steps:
        if name == "groups" and not groups_in.exists():
            kept = [{**group_cli.source_row(r, "speech_first"), "planned_facts": r["slot"]["facts"]}
                    for r in _read(facts) if r["stage"] == "kept"]
            kept, refused = screen(kept, dev_index())
            _write(sources, kept)
            _write(groups_in, release.groups_in_rows(kept))
            _write(out / "duplicate_failures.jsonl", refused)
        if name == "verdict_input" and not clean_targets.exists():
            by_id = {r["id"]: r for r in _read(groups)}
            source_by_id = {r["id"]: r for r in _read(sources)}
            accepted, refused = screen_provenance(_read(targets), by_id)
            _write(clean_targets, select_targets(accepted, source_by_id, args.count))
            _write(out / "provenance_failures.jsonl", refused)
        if not output.exists():
            subprocess.run(command, cwd=ROOT, check=True)
        counts[name] = sum(1 for _ in output.open(encoding="utf-8")) if output.suffix == ".jsonl" else int(output.exists())
        failure_suffix = {"writer": ".writer.failed.jsonl", "labels": ".targets_failed.jsonl",
                          "notes": ".notes_failed.jsonl", "speech": ".speech_failed.jsonl"}.get(name)
        failed_file = Path(str(prefix) + failure_suffix) if failure_suffix else out / "no_such_failures.jsonl"
        failures[name] = len(_read(failed_file)) if failed_file.exists() else 0
        if name in ("notes", "speech"):
            failures[f"{name}_checks"] = sum(bool(r.get("problems")) for r in _read(output))
        if name == "writer":
            failures["writer_quarantine"] = len(_read(Path(str(prefix) + ".writer.quarantine.jsonl")))
            failures["writer_not_typed"] = len(_read(Path(str(prefix) + ".writer.not_typed.jsonl")))
        if name == "facts":
            failures["facts_check"] = sum(r["stage"] != "kept" for r in _read(output))
        failures["duplicates"] = len(_read(out / "duplicate_failures.jsonl")) if (out / "duplicate_failures.jsonl").exists() else 0
        failures["provenance"] = len(_read(out / "provenance_failures.jsonl")) if (out / "provenance_failures.jsonl").exists() else 0
        failures["provenance_by_kind"] = finding_counts(_read(out / "provenance_failures.jsonl")) if (out / "provenance_failures.jsonl").exists() else {}
        observed = _read(sources) if sources.exists() else None
        current = {"requested_labels": args.count, **manifest(plan, counts, failures, observed)}
        if clean_targets.exists():
            selected = _read(clean_targets)
            current["screened_labels"] = len(selected)
            if observed is not None:
                by_id = {s["id"]: s for s in observed}
                current.update(selection_status(selected, by_id, args.count))
                labelled = [by_id[t["id"]] for t in selected]
                current["labelled"] = manifest(plan, {}, {}, labelled)["passages"]
        (out / "manifest.json").write_text(json.dumps(current, indent=2) + "\n", encoding="utf-8")
    if clean_targets.exists():
        shortfall = args.count - len(_read(clean_targets))
        if shortfall:
            print(f"screened labels shortfall: {shortfall} of {args.count}", file=sys.stderr)
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--count", type=int, required=True)
    parser.add_argument("--seed", type=int, default=11)
    parser.add_argument("--out", required=True)
    parser.add_argument("--pool", default="Evals/runs/retrain/pilot/manner-pool.jsonl")
    parser.add_argument("--workers", type=int, default=4)
    parser.add_argument("--max-dollars", type=float, required=True)
    parser.add_argument("--attempt-factor", type=float, default=2.2)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--execute", action="store_true", help="run local and paid steps")
    args = parser.parse_args(argv)
    if args.execute == args.dry_run:
        parser.error("choose exactly one of --dry-run and --execute")
    if args.count < 1 or not math.isfinite(args.attempt_factor) or args.attempt_factor <= 0:
        parser.error("--count and --attempt-factor must be positive")
    return run(args)


if __name__ == "__main__":
    raise SystemExit(main())
