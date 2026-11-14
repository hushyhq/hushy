"""Print the AMI scorecard with Wilson 95% intervals from `score_public.py --json` output.

    python3 scripts/meeting-extract/scorecard_table.py score.json [--order extract,r10d,apple]

Counts come from the per-meeting rows: decision recall = decisions_found / gold_decisions, action recall =
actions_found / gold_actions, unsupported = len(unsupported) / produced, invented owners = owners named that are not
speakers, out of the action items written. The unit is one gold item, so the 14 meetings are not independent draws; read the
intervals as a floor on the real uncertainty. The paired line counts meetings where the first run beats the
second on the same metric (ties dropped).
"""
import argparse
import json
import math


def wilson(k: int, n: int, z: float = 1.96) -> tuple:
    if n == 0:
        return (0.0, 0.0)
    p = k / n
    d = 1 + z * z / n
    centre = (p + z * z / (2 * n)) / d
    half = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / d
    return (max(0.0, centre - half), min(1.0, centre + half))


def counts(meetings: list) -> dict:
    return {
        "decision recall": (sum(m["decisions_found"] for m in meetings), sum(m["gold_decisions"] for m in meetings)),
        "action recall": (sum(m["actions_found"] for m in meetings), sum(m["gold_actions"] for m in meetings)),
        "unsupported": (sum(len(m["unsupported"]) for m in meetings), sum(m["produced"] for m in meetings)),
        "invented owners": (sum(len(m["invented_owners"]) for m in meetings), sum(m["pred_items"] for m in meetings)),
        "wrong owner": (sum(m["owner_wrong"] for m in meetings), sum(m["owner_checked"] for m in meetings)),
    }


def cell(k: int, n: int) -> str:
    lo, hi = wilson(k, n)
    return f"{k}/{n} = {100 * k / n:.0f}% [{100 * lo:.0f}, {100 * hi:.0f}]" if n else "0/0"


def paired(a: list, b: list, key: str, lower_is_better: bool = False) -> str:
    wins = losses = 0
    for x, y in zip(a, b):
        vx = x[key] if not isinstance(x[key], list) else len(x[key])
        vy = y[key] if not isinstance(y[key], list) else len(y[key])
        if vx == vy:
            continue
        better = vx < vy if lower_is_better else vx > vy
        wins += better
        losses += not better
    return f"{wins} meetings better, {losses} worse"


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("score")
    ap.add_argument("--order")
    args = ap.parse_args()
    data = json.loads(open(args.score).read())["meetings"]
    names = args.order.split(",") if args.order else list(data)
    table = {name: counts(data[name]) for name in names}
    metrics = list(next(iter(table.values())))
    print("| metric | " + " | ".join(names) + " |")
    print("|---|" + "---|" * len(names))
    for metric in metrics:
        print(f"| {metric} | " + " | ".join(cell(*table[name][metric]) for name in names) + " |")
    if len(names) >= 2:
        first = names[0]
        for other in names[1:]:
            print(f"\n{first} against {other}, per meeting: "
                  f"decisions found {paired(data[first], data[other], 'decisions_found')}; "
                  f"actions found {paired(data[first], data[other], 'actions_found')}; "
                  f"unsupported {paired(data[first], data[other], 'unsupported', True)}.")


if __name__ == "__main__":
    main()
