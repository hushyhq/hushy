#!/usr/bin/env python3
"""One comparison table from several `murmur-eval meeting --out run.json` files.

    python3 scripts/meeting-eval/summarize_runs.py label=path.json [label=path.json ...] [--split m04-m12]

Rows: action-item recall (owner + task), task recall, precision, decision recall, recall in the
meeting's last quartile (action items + decisions), corrections applied, stale / small-talk
items, hallucinated owners, p50 latency over all meetings and over the 55-65 minute ones.
`--split m04-m12` restricts to meetings whose prompts were never looked at while developing.
"""

from __future__ import annotations

import json
import statistics
import sys


def pct(a: int, b: int) -> str:
    return "–" if b == 0 else f"{100 * a / b:.0f}%"


def row(label: str, runs: list[dict]) -> str:
    total: dict[str, int] = {}
    qf, qt = [0] * 4, [0] * 4
    for run in runs:
        s = run["score"]
        for key, value in s.items():
            if isinstance(value, int):
                total[key] = total.get(key, 0) + value
        for i in range(4):
            qf[i] += s["quartileFound"][i]
            qt[i] += s["quartileTotal"][i]
    t = total.get
    lat = sorted(r["milliseconds"] for r in runs)
    hour = sorted(r["milliseconds"] for r in runs if 55 <= r["minutes"] <= 65)
    p50 = f"{statistics.median(lat) / 1000:.1f} s" if lat else "–"
    h50 = f"{statistics.median(hour) / 1000:.1f} s" if hour else "–"
    return (f"| {label} | {pct(t('actionsFound', 0), t('goldActions', 0))} | {pct(t('actionTasksFound', 0), t('goldActions', 0))} "
            f"| {pct(t('predictedMatchingGold', 0), t('predictedActions', 0))} | {pct(t('decisionsFound', 0), t('goldDecisions', 0))} "
            f"| {pct(qf[3], qt[3])} | {t('correctionsApplied', 0)}/{t('corrections', 0)} | {t('staleItems', 0)} "
            f"| {t('smallTalkItems', 0)} | {t('hallucinatedOwners', 0)}/{t('predictedActions', 0)} | {p50} | {h50} |")


def main() -> None:
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    split = None
    if "--split" in sys.argv:
        lo, hi = sys.argv[sys.argv.index("--split") + 1].split("-")
        split = (lo, hi)
        args = [a for a in args if a != sys.argv[sys.argv.index("--split") + 1]]
    print("| backend · strategy | action recall (owner+task) | task recall | action precision | decision recall "
          "| last-quartile recall | corrections applied | stale items | small-talk items | hallucinated owners "
          "| p50 latency | 55–65 min p50 |")
    print("|---|---|---|---|---|---|---|---|---|---|---|---|")
    for arg in args:
        label, path = arg.rsplit("=", 1)
        runs = json.load(open(path))
        if split:
            runs = [r for r in runs if split[0] <= r["id"] <= split[1]]
        print(row(label, runs))


if __name__ == "__main__":
    main()
