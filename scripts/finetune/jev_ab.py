#!/usr/bin/env python3
"""Pointwise Jev A/B over dev-eval reports (Evals/JUDGES.md policy: compare pBad, never the
pairwise Choice).

    python3 scripts/finetune/jev_ab.py --runs apple=<dir> qwen2b=<dir> … --out <dir> --max-calls 170
        [--sets cleanup-hybrid,reformat-clean,reformat-polished] [--ledger <file>]

Each <dir> holds the `--report` JSONs from `run_dev_evals.sh`. Only cases where the backends'
outputs differ are judged (identical outputs get identical pBad and say nothing about the A/B);
identical (level, spoken, output) rows are judged once. If that is more than --max-calls, whole
cases are sampled by a stable hash so every backend is judged on the same cases. Writes
ab-rows.jsonl, ab-judged.jsonl and ab-summary.md.
"""

from __future__ import annotations

import argparse
import collections
import hashlib
import json
import statistics
import subprocess
import sys
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))
from pathguard import Manifest, check  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
LEVEL = {"cleanup-hybrid": "clean", "reformat-clean": "clean", "reformat-polished": "polished",
         "overdeletion": "clean", "grammar": "polished", "long-hybrid": "clean",
         "frame-clean": "clean", "frame-polished": "polished",
         "list-clean": "clean", "list-polished": "polished", "negfresh-clean": "clean", "negfresh-polished": "polished"}


# long-golden's `expected` is the rules output (it keeps "Thursday, no wait, Friday"), so it is a
# poor reference for a model that resolves corrections; Jev judges those outputs without one.
NO_REFERENCE = {"long-hybrid"}


def load_cases(path: Path, manifest: Manifest) -> dict[str, dict[str, str]]:
    report = manifest.read_json(path)
    out: dict[str, dict[str, str]] = {}
    if "levels" in report:
        for level in report["levels"]:
            for case in level["cases"]:
                out[case["id"]] = {"spoken": case["input"], "output": case["output"], "reference": case.get("reference") or ""}
    else:
        for case in report["cases"]:
            # Golden reports carry input/actual/expected; the grammar report spoken/output (no reference).
            out[case["id"]] = {"spoken": case.get("input") or case.get("spoken") or "",
                               "output": case.get("actual", case.get("output", "")),
                               "reference": case.get("expected") or ""}
    return out


def stable(key: str) -> int:
    return int(hashlib.sha256(key.encode()).hexdigest()[:8], 16)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--runs", nargs="+", required=True, help="label=dir")
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--sets", default="cleanup-hybrid,reformat-clean,reformat-polished")
    parser.add_argument("--max-calls", type=int, required=True)
    parser.add_argument("--ledger", type=Path)
    parser.add_argument("--baseline", default="apple")
    parser.add_argument("--eval-bin", type=Path, default=ROOT / ".build/release/murmur-eval")
    args = parser.parse_args()
    out = check(args.out.resolve())
    out.mkdir(parents=True, exist_ok=True)
    manifest = Manifest(ROOT)
    runs = dict(item.split("=", 1) for item in args.runs)
    sets = args.sets.split(",")

    per_case: dict[tuple[str, str], dict[str, dict[str, str]]] = collections.defaultdict(dict)
    for label, directory in runs.items():
        for name in sets:
            path = Path(directory) / f"{name}.json"
            if path.exists():
                for case_id, case in load_cases(path, manifest).items():
                    if name in NO_REFERENCE:
                        case["reference"] = ""
                    per_case[(name, case_id)][label] = case
    differing = {key: value for key, value in per_case.items() if len({c["output"] for c in value.values()}) > 1}
    identical = len(per_case) - len(differing)

    def rows_for(keys: list[tuple[str, str]]) -> list[dict[str, Any]]:
        rows, seen = [], set()
        for name, case_id in keys:
            for label, case in differing[(name, case_id)].items():
                signature = (LEVEL[name], case["spoken"], case["output"], case["reference"])
                if signature in seen:
                    continue
                seen.add(signature)
                rows.append({"id": f"{name}/{case_id}/{label}", "set": name, "case": case_id, "level": LEVEL[name],
                             "spoken": case["spoken"], "output": case["output"], "reference": case["reference"]})
        return rows

    keys = sorted(differing, key=lambda k: stable("ab|" + "/".join(k)))
    chosen = keys
    while len(rows_for(chosen)) > args.max_calls:
        chosen = chosen[:-1]
    rows = rows_for(chosen)
    manifest.write_jsonl(out / "ab-rows.jsonl", rows)
    command = [str(args.eval_bin), "finetune", "jev", "--in", str(out / "ab-rows.jsonl"), "--out", str(out / "ab-judged.jsonl"),
               "--max-calls", str(args.max_calls), "--spoken-key", "spoken", "--output-key", "output",
               "--reference-key", "reference", "--label", f"ab:{','.join(runs)}"]
    if args.ledger:
        command += ["--ledger", str(check(args.ledger))]
    subprocess.run(command, cwd=ROOT, check=True)
    judged = {(r["level"], r["spoken"], r["output"], r["reference"]): r for r in manifest.read_jsonl(out / "ab-judged.jsonl")}

    lines = [f"Pointwise Jev ({len(rows)} judged outputs) on the {len(chosen)} of {len(differing)} cases whose outputs differ "
             f"between backends ({identical} identical cases not judged). pBad: < 0.3 pass, 0.3–0.7 unsure, ≥ 0.7 fail.", ""]
    lines.append("| Set | Backend | n | mean pBad | median | pass / unsure / fail | better / worse than " + args.baseline + " (ΔpBad > 0.2) |")
    lines.append("|---|---|---:|---:|---:|---|---|")
    for name in sets:
        case_keys = [k for k in chosen if k[0] == name]
        for label in runs:
            scores, better, worse = [], 0, 0
            for key in case_keys:
                case = differing[key].get(label)
                if not case:
                    continue
                row = judged.get((LEVEL[name], case["spoken"], case["output"], case["reference"]))
                if not row or row.get("pBad") is None:
                    continue
                scores.append(row["pBad"])
                base = differing[key].get(args.baseline)
                base_row = base and judged.get((LEVEL[name], base["spoken"], base["output"], base["reference"]))
                if base_row and base_row.get("pBad") is not None and label != args.baseline:
                    delta = row["pBad"] - base_row["pBad"]
                    better += delta < -0.2
                    worse += delta > 0.2
            if not scores:
                continue
            bands = (sum(s < 0.3 for s in scores), sum(0.3 <= s < 0.7 for s in scores), sum(s >= 0.7 for s in scores))
            vs = "—" if label == args.baseline else f"{better} / {worse}"
            lines.append(f"| {name} | {label} | {len(scores)} | {statistics.mean(scores):.2f} | {statistics.median(scores):.2f} | "
                         f"{bands[0]} / {bands[1]} / {bands[2]} | {vs} |")
    summary = "\n".join(lines) + "\n"
    (out / "ab-summary.md").write_text(summary)
    manifest.record_write(out / "ab-summary.md")
    manifest.sections["runs"] = runs
    manifest.save(out / "ab-manifest.json")
    print(summary)


if __name__ == "__main__":
    main()
