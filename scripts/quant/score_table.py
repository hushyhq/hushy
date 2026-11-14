#!/usr/bin/env python3
"""Summarize app-path variant outputs, using the repository's public/probe scorers."""
import json
import math
from pathlib import Path
import re
import statistics
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
from retrain_public_eval import verdict  # noqa: E402
from probe_score import score_number, score_prompt  # noqa: E402

SETS = ("pub", "number_guard", "number", "prompt", "misheard")
VARIANTS = ("q4", "q5", "q6", "q8", "mixed", "dwq")


def read(path):
    rows = [json.loads(line) for line in Path(path).read_text().splitlines() if line.strip()]
    by_id = {row["id"]: row for row in rows}
    if len(by_id) != len(rows):
        raise ValueError(f"duplicate ids: {path}")
    return by_id


def quantile(values, p):
    if not values:
        return "—"
    values = sorted(values)
    value = statistics.median(values) if p == .5 else values[max(0, math.ceil(p * len(values)) - 1)]
    return str(round(value))


def memory_mb(log):
    match = re.search(r"(?m)^\s*(\d+)\s+maximum resident set size", log)
    return str(round(int(match[1]) / 1048576)) if match else "—"


def score(set_name, cases, outputs, case_path, output_path):
    if set(cases) != set(outputs):
        raise ValueError(f"ID mismatch: {output_path}")
    if set_name == "pub":
        return sum(verdict(ident, cases[ident], outputs[ident]["text"])["exact"] for ident in cases)
    if set_name == "number_guard":
        return None  # invented guard inputs carry no expected answers
    if set_name in ("number", "prompt"):
        scorer = score_number if set_name == "number" else score_prompt
        return sum(not scorer(case, outputs[ident]["text"]) for ident, case in cases.items())
    result = subprocess.run([sys.executable, "-I", str(ROOT / "scripts/misheard_score.py"),
                             str(case_path), str(output_path)], check=True, capture_output=True, text=True)
    match = re.search(r"(?m)^case\s+.*\brepaired=(\d+)", result.stdout)
    return int(match[1]) if match else 0


def table(out_root, pub):
    sources = {"pub": Path(pub), "number_guard": ROOT / "Evals/number-guard-probe.jsonl",
               "number": ROOT / "Evals/number-probe.jsonl", "prompt": ROOT / "Evals/prompt-probe.jsonl",
               "misheard": ROOT / "Evals/misheard-probe.jsonl"}
    lines = ["| variant | set | exact / checks | used | changed vs q4 | first token p50/p90 ms | total p50/p90 ms | peak RSS MB |",
             "|---|---|---:|---:|---:|---:|---:|---:|"]
    for name in VARIANTS:
        for set_name in SETS:
            output_path = Path(out_root) / "scores" / f"{name}-{set_name}.jsonl"
            if not output_path.is_file():
                continue
            cases = read(sources[set_name]); outputs = read(output_path)
            base_path = Path(out_root) / "scores" / f"q4-{set_name}.jsonl"
            base = read(base_path) if base_path.is_file() else None
            changed = sum(outputs[i]["text"] != base[i]["text"] for i in cases) if base else None
            passed = score(set_name, cases, outputs, sources[set_name], output_path)
            first = [r["firstTokenMs"] for r in outputs.values() if isinstance(r.get("firstTokenMs"), (int, float))]
            total = [r["totalMs"] for r in outputs.values() if isinstance(r.get("totalMs"), (int, float))]
            log = output_path.with_suffix(".log").read_text()
            lines.append("| " + " | ".join((name, set_name, f"{passed}/{len(cases)}" if passed is not None else "n/a",
                str(sum(bool(r.get("usedModel")) for r in outputs.values())), str(changed) if changed is not None else "n/a",
                f"{quantile(first, .5)}/{quantile(first, .9)}", f"{quantile(total, .5)}/{quantile(total, .9)}",
                memory_mb(log))) + " |")
    return "\n".join(lines) + "\n"


if __name__ == "__main__":
    print(table(sys.argv[1], sys.argv[2]), end="")
