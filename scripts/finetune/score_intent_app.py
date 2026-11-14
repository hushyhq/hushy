#!/usr/bin/env python3
"""Aggregate an intent-app JSONL run without printing dictated text."""

import argparse
import json
import statistics
from pathlib import Path


def rows(path):
    data = path.read_text()
    if path.suffix == ".json":
        return json.loads(data)
    return [json.loads(line) for line in data.splitlines() if line.strip()]


def percentile(values, fraction):
    if not values:
        return 0
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int((len(ordered) - 1) * fraction))]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cases", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    cases = {row["id"]: row for row in rows(args.cases)}
    outputs = rows(args.out)
    exact = 0
    comparable = 0
    for row in outputs:
        source = cases[row["id"]]
        expected = source.get("reference", source.get("expected"))
        if expected is None:
            continue
        comparable += 1
        accepted = [expected] + source.get("alternatives", [])
        exact += any(" ".join(row["text"].split()) == " ".join(answer.split()) for answer in accepted)
    print(f"cases={len(outputs)} usedModel={sum(row['usedModel'] for row in outputs)} whitespaceExact={exact}/{comparable}")
    for key in ("firstTokenMs", "totalMs", "modelMs"):
        values = [row[key] for row in outputs if isinstance(row.get(key), (int, float))]
        print(f"{key}: n={len(values)} p50={statistics.median(values) if values else 0:.0f} "
              f"p90={percentile(values, 0.90):.0f} max={max(values, default=0):.0f}")
    print(f"rejected={sum(bool(row.get('rejection')) for row in outputs)}")


if __name__ == "__main__":
    main()
