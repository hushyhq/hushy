"""Speaker attribution error: how often a transcript word would get the wrong speaker.

    python3 -I scripts/diarizer_attribution.py <public-data-dir> [dataset ...]

DER charges a diarizer for speech it does not mark at all. The app does not need that: the
recogniser finds the words, and `SpeakerAlignment` gives each word the turn covering its midpoint, or
the nearest turn when none covers it. This scores that use directly. Every 100 ms frame where exactly
one reference speaker talks stands in for a word. It gets the label of the hypothesis turn covering its
midpoint, else of the nearest turn by edge distance, the same rule as `SpeakerAlignment`.
Hypothesis labels map to reference speakers one to one, greedily by co-occurring frames. The error is
the share of frames whose mapped label is not the reference speaker. Frames within 0.125 s of a reference
boundary are skipped, as a 0.25 s collar does.

References are read from the files the bakeoff downloaded: AMI `only_words` RTTM, VoxConverse cached
manifests, and NOTSOFAR word timings merged as `NotsofarDownloader.referenceTurns` merges them.
"""

import bisect
import json
import sys
from collections import defaultdict
from pathlib import Path

STEP = 0.1
COLLAR = 0.25
NOTSOFAR_GAP = 0.5


def rttm(path):
    turns = []
    for line in path.read_text().splitlines():
        f = line.split()
        if len(f) >= 8 and f[0] == "SPEAKER":
            turns.append((f[7], float(f[3]), float(f[3]) + float(f[4])))
    return turns


def notsofar(path):
    spans = defaultdict(list)
    for u in json.loads(path.read_text()):
        timed = [(w[1], w[2]) for w in (u.get("word_timing") or []) if len(w) >= 3 and w[2] > w[1]]
        spans[u["speaker_id"]].extend(timed or [(u["start_time"], u["end_time"])])
    turns = []
    for speaker, items in spans.items():
        merged = []
        for s, e in sorted(items):
            if merged and s - merged[-1][1] < NOTSOFAR_GAP:
                merged[-1][1] = max(merged[-1][1], e)
            else:
                merged.append([s, e])
        turns.extend((speaker, s, e) for s, e in merged)
    return turns


def reference(root, dataset, file_id):
    if dataset.startswith("ami-sdm"):
        return rttm(root / "ami-sdm" / f"{file_id}.rttm")
    if dataset == "notsofar-sc":
        return notsofar(root / "notsofar-eval-sc" / file_id / "gt_transcription.json")
    if dataset == "voxconverse-test":
        m = json.loads((root / "voxconverse-test" / f"{file_id}.json").read_text())
        return [(t["speakerId"], t["beginTime"], t["endTime"]) for t in m["turns"]]
    raise SystemExit(f"unknown dataset {dataset}")


def label_at(t, hyp, starts):
    """SpeakerAlignment's rule: a covering turn (largest overlap with the frame), else the nearest turn."""
    best, best_overlap = None, 0.0
    i = bisect.bisect_right(starts, t)
    for j in range(max(0, i - 50), i):
        spk, s, e = hyp[j]
        if s <= t < e:
            overlap = min(e, t + STEP / 2) - max(s, t - STEP / 2)
            if overlap > best_overlap:
                best, best_overlap = spk, overlap
    if best is not None:
        return best
    nearest, distance = None, float("inf")
    for j in range(max(0, i - 50), min(len(hyp), i + 50)):
        spk, s, e = hyp[j]
        d = s - t if t < s else (t - e if t >= e else 0)
        if d < distance:
            nearest, distance = spk, d
    return nearest


def score(ref, hyp_turns):
    hyp = sorted(((h["speaker"], h["start"], h["end"]) for h in hyp_turns), key=lambda x: x[1])
    starts = [h[1] for h in hyp]
    boundaries = sorted({b for _, s, e in ref for b in (s, e)})
    end = max(e for _, _, e in ref)
    frames = []
    n = int(end / STEP) + 1
    owners = [set() for _ in range(n)]
    for spk, s, e in ref:
        for k in range(int(s / STEP), min(n, int(e / STEP) + 1)):
            mid = k * STEP + STEP / 2
            if s <= mid < e:
                owners[k].add(spk)
    for k in range(n):
        if len(owners[k]) != 1:
            continue
        mid = k * STEP + STEP / 2
        b = bisect.bisect_left(boundaries, mid)
        near = min(abs(mid - boundaries[j]) for j in (b - 1, b) if 0 <= j < len(boundaries))
        if near < COLLAR / 2:
            continue
        frames.append((next(iter(owners[k])), label_at(mid, hyp, starts) if hyp else None))
    co = defaultdict(int)
    for r, h in frames:
        co[(h, r)] += 1
    mapping, used = {}, set()
    for (h, r), _ in sorted(co.items(), key=lambda kv: -kv[1]):
        if h not in mapping and r not in used:
            mapping[h] = r
            used.add(r)
    wrong = sum(1 for r, h in frames if mapping.get(h) != r)
    return wrong, len(frames)


def main():
    root = Path(sys.argv[1])
    datasets = sys.argv[2:] or [p.name for p in sorted((root / "diarizer-bakeoff").iterdir()) if p.is_dir()]
    for dataset in datasets:
        runs = [json.loads(p.read_text()) for p in sorted((root / "diarizer-bakeoff" / dataset).glob("*.json"))]
        if not runs:
            continue
        common = set.intersection(*(set(f["id"] for f in r["files"]) for r in runs))
        refs = {i: reference(root, dataset, i) for i in common}
        print(f"\n#### {dataset} · attribution error, {len(common)} files\n")
        print("| backend | attribution error | worst file |")
        print("|---|---|---|")
        for run in runs:
            total_wrong = total = 0
            worst = (0.0, "")
            for f in run["files"]:
                if f["id"] not in common:
                    continue
                wrong, count = score(refs[f["id"]], f["hypothesis"])
                total_wrong += wrong
                total += count
                worst = max(worst, (wrong / max(count, 1), f["id"]))
            print(f"| {run['tag']} | **{100 * total_wrong / max(total, 1):.1f}%** | {worst[1]} {100 * worst[0]:.0f}% |")


if __name__ == "__main__":
    main()
