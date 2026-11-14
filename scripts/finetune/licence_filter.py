#!/usr/bin/env python3
"""Keep only training rows whose source is licensed for commercial training, and tag each kept row.

    python3 -I scripts/finetune/licence_filter.py --sources SOURCES.json IN.jsonl OUT.jsonl [--report REPORT.json]

SOURCES.json maps a source name to its licence: {"sources": {"ami": {"licence": "CC-BY-4.0",
"commercial_safe": true, "attribution": "..."}, ...}}. Every input row must name its source in a top-level
`source` field. A row is kept only when its source is listed with `commercial_safe: true`; an unlisted source, a
missing `source` field or `commercial_safe: false` drops the row (fail closed). Kept rows gain `licence` and
`commercial_safe` fields, so every row of the output says where it came from. The report counts kept and dropped
rows per source and lists the attributions the model card owes.
"""
from __future__ import annotations

import argparse
import json
import sys
from collections import Counter
from pathlib import Path


def load_sources(path: Path) -> dict:
    sources = json.loads(path.read_text(encoding="utf-8")).get("sources")
    if not isinstance(sources, dict) or not sources:
        raise ValueError(f"{path}: expected a non-empty 'sources' object")
    for name, entry in sources.items():
        if not isinstance(entry, dict) or not isinstance(entry.get("licence"), str) or \
                not isinstance(entry.get("commercial_safe"), bool):
            raise ValueError(f"{path}: source {name!r} needs a 'licence' string and a 'commercial_safe' boolean")
    return sources


def decide(row: dict, sources: dict) -> tuple[dict | None, str]:
    """(tagged row, reason) for a kept row; (None, reason) for a dropped one."""
    name = row.get("source")
    if not isinstance(name, str) or not name:
        return None, "no source field"
    entry = sources.get(name)
    if entry is None:
        return None, "source not listed"
    if not entry["commercial_safe"]:
        return None, "not commercial-safe"
    return {**row, "licence": entry["licence"], "commercial_safe": True}, "kept"


def run(sources: dict, lines, out) -> dict:
    kept, dropped = Counter(), Counter()
    for number, line in enumerate(lines, 1):
        if not line.strip():
            continue
        row = json.loads(line)
        if not isinstance(row, dict):
            raise ValueError(f"line {number}: expected a JSON object")
        tagged, reason = decide(row, sources)
        source = row.get("source") if isinstance(row.get("source"), str) else "<none>"
        if tagged is None:
            dropped[(source, reason)] += 1
            continue
        kept[source] += 1
        out.write(json.dumps(tagged, ensure_ascii=False) + "\n")
    return {
        "kept": dict(sorted(kept.items())),
        "dropped": [{"source": s, "reason": r, "rows": n} for (s, r), n in sorted(dropped.items())],
        "attributions": sorted({sources[s].get("attribution", sources[s]["licence"]) for s in kept}),
    }


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--sources", type=Path, required=True)
    parser.add_argument("--report", type=Path)
    parser.add_argument("input", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args(argv)
    sources = load_sources(args.sources)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.input.open(encoding="utf-8") as src, args.output.open("w", encoding="utf-8") as out:
        report = run(sources, src, out)
    text = json.dumps(report, indent=1)
    if args.report:
        args.report.write_text(text + "\n", encoding="utf-8")
    print(text)
    return 0 if report["kept"] else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
