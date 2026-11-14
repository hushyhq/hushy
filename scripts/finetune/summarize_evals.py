#!/usr/bin/env python3
"""One table over several `run_dev_evals.sh` output directories.

    python3 scripts/finetune/summarize_evals.py label=<dir> [label=<dir> ...]

Per set: pass/total, negatives kept (where the set has negatives), latency p50/p95 of the whole
cleanup (ms) and model timeouts/speed fallbacks. Reads only the `--report` JSONs.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

SETS = ["cleanup-hybrid", "reformat-clean", "reformat-polished", "overdeletion", "grammar", "long-hybrid",
        "frame-clean", "frame-polished", "list-clean", "list-polished"]


def pct(values: list[float], q: float) -> float:
    values = sorted(values)
    return values[min(len(values) - 1, int(len(values) * q))] if values else 0.0


def summarize(path: Path) -> str:
    if not path.exists():
        return "—"
    report = json.loads(path.read_text())
    if "levels" in report:
        cases = [c for level in report["levels"] for c in level["cases"]]
        negatives = [c for c in cases if c.get("negative")]
        passed = sum(c["passed"] for c in cases)
    else:
        cases = report["cases"]
        negatives = [c for c in cases if c.get("tag") == "negative"]
        passed = sum(c["passed"] for c in cases)
    latencies = [c["latencyMs"] for c in cases if isinstance(c.get("latencyMs"), (int, float))]
    timeouts = sum(1 for c in cases if (c.get("rejection") or "").startswith(("timeout", "skipped", "model busy", "release-window", "prewarm-late")))
    text = f"{passed}/{len(cases)}"
    if negatives:
        text += f" (neg {sum(c['passed'] for c in negatives)}/{len(negatives)})"
    text += f" · {pct(latencies, 0.5):.0f}/{pct(latencies, 0.95):.0f} ms"
    if timeouts:
        text += f" · {timeouts} to"
    return text


def main() -> None:
    runs = [arg.split("=", 1) for arg in sys.argv[1:]]
    print("| Set | " + " | ".join(label for label, _ in runs) + " |")
    print("|---|" + "---|" * len(runs))
    for name in SETS:
        print(f"| {name} | " + " | ".join(summarize(Path(directory) / f"{name}.json") for _, directory in runs) + " |")


if __name__ == "__main__":
    main()
