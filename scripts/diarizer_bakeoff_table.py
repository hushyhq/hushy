"""Print one Markdown table from `murmur-eval diarize-bakeoff` JSON results.

    python3 -I scripts/diarizer_bakeoff_table.py <results-dir> [--files ID,ID]

DER is pooled (total error time over total reference time) at collar 0.25 s and 0 s, overlap
included. `--files` restricts every row to the same files, so a backend that skipped a file is
not compared on an easier set.
"""

import json
import sys
from pathlib import Path


def pooled(files, collar):
    parts = [f["der"][collar] for f in files]
    ref = sum(p["reference"] for p in parts) or 1e-9
    miss = sum(p["missed"] for p in parts) / ref
    fa = sum(p["falseAlarm"] for p in parts) / ref
    conf = sum(p["confusion"] for p in parts) / ref
    return miss + fa + conf, miss, fa, conf


def row(run, files):
    der25, miss, fa, conf = pooled(files, "0.25")
    der0 = pooled(files, "0.00")[0]
    exact = sum(f["hypSpeakers"] == f["refSpeakers"] for f in files)
    count_err = sum(abs(f["hypSpeakers"] - f["refSpeakers"]) for f in files) / max(len(files), 1)
    audio = sum(f["durationSeconds"] for f in files)
    compute = sum(f["elapsedSeconds"] for f in files) or 1e-9
    return (
        f"| {run['tag']} | {len(files)} | **{der25 * 100:.1f}** | {miss * 100:.1f} | {fa * 100:.1f} | "
        f"{conf * 100:.1f} | {der0 * 100:.1f} | {exact}/{len(files)} | {count_err:.2f} | "
        f"{audio / compute:.0f}x | {run['peakFootprintMB']:.0f} |"
    )


def main():
    root = Path(sys.argv[1])
    if not root.is_dir():
        sys.exit(f"no results under {root}")
    only = None
    if "--files" in sys.argv:
        only = set(sys.argv[sys.argv.index("--files") + 1].split(","))
    for dataset_dir in sorted(p for p in root.iterdir() if p.is_dir()):
        runs = [json.loads(p.read_text()) for p in sorted(dataset_dir.glob("*.json"))]
        if not runs:
            continue
        common = set.intersection(*(set(f["id"] for f in r["files"]) for r in runs))
        if only:
            common &= only
        minutes = sum(f["durationSeconds"] for f in runs[0]["files"] if f["id"] in common) / 60
        print(f"\n#### {dataset_dir.name} · {len(common)} files · {minutes:.0f} min (files every run scored)\n")
        print("| backend | files | DER c0.25 | missed | false alarm | confusion | DER c0 | count exact | count error | speed | peak MB |")
        print("|---|---|---|---|---|---|---|---|---|---|---|")
        for run in runs:
            print(row(run, [f for f in run["files"] if f["id"] in common]))


if __name__ == "__main__":
    main()
