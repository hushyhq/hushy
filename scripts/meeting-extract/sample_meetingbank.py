"""Deterministic stratified sample of MeetingBank chunks for labelling: proportional by city, one chunk per meeting.

    $PY scripts/meeting-extract/sample_meetingbank.py --n 300
Writes labels/meetingbank-s300.ids (one chunk id per line), used by the `meetingbank-s300` stage of label_agent.py.
"""
import argparse
import json
import random
from collections import defaultdict
from pathlib import Path

from common import DATA_ROOT

SEED = 20261107


def sample(rows: list, n: int) -> list:
    by_city = defaultdict(lambda: defaultdict(list))
    for r in rows:
        by_city[r["series"]][r["meeting_id"]].append(r["id"])
    total = sum(len(m) for m in by_city.values())
    quotas = {c: n * len(m) / total for c, m in by_city.items()}
    take = {c: int(q) for c, q in quotas.items()}
    for c in sorted(quotas, key=lambda c: quotas[c] - take[c], reverse=True)[: n - sum(take.values())]:
        take[c] += 1
    rng = random.Random(SEED)
    picked = []
    for city in sorted(by_city):
        meetings = sorted(by_city[city])
        for meeting in rng.sample(meetings, min(take[city], len(meetings))):
            picked.append(rng.choice(sorted(by_city[city][meeting])))
    return sorted(picked)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=300)
    args = ap.parse_args()
    path = DATA_ROOT / "final" / "input-only.jsonl"
    rows = [r for r in map(json.loads, open(path, encoding="utf-8")) if r["source"] == "meetingbank"]
    ids = sample(rows, args.n)
    out = DATA_ROOT / "labels" / f"meetingbank-s{args.n}.ids"
    out.write_text("\n".join(ids) + "\n")
    print(f"{len(ids)} chunk ids from {len(rows)} -> {out}")


if __name__ == "__main__":
    main()
