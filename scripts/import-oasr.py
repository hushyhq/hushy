#!/usr/bin/env python3
"""Import an Open ASR Leaderboard test set into Evals/data/<name>/manifest.json.

`murmur-eval download oasr-*` fetches the same sets row by row through the Hugging Face
datasets-server, which rate-limits (HTTP 429) long before a full 2,600-utterance split is done.
This reads the leaderboard's parquet files instead (one download per shard, ungated) and writes the
exact manifest format `murmur-eval us-english bench` reads: one audio file per row (the original
encoded bytes, FLAC/WAV/MP3 as stored) plus a JSON list of EvalClip objects.

Usage (needs pyarrow; nothing else):
    python3 scripts/import-oasr.py --config librispeech --split test.clean --name oasr-librispeech-clean
    python3 scripts/import-oasr.py --config earnings22 --split test --name oasr-earnings22
    python3 scripts/import-oasr.py --config common_voice --split test --name oasr-commonvoice --sample 500

--sample N keeps N rows chosen exactly like Downloader.deterministicSample (SplitMix64, seed 42,
one row per equal band of the split), so the result matches `murmur-eval download --limit N`.
Licences: LibriSpeech CC-BY-4.0, Earnings-22 CC-BY-SA-4.0, Common Voice CC0-1.0.
"""
import argparse
import json
import os
import sys
import urllib.request

REPO = "hf-audio/open-asr-leaderboard"
MASK = (1 << 64) - 1


class SplitMix64:
    """Same generator as murmur-eval's SplitMix64 (Datasets.swift)."""

    def __init__(self, seed):
        self.state = seed & MASK

    def next(self):
        self.state = (self.state + 0x9E3779B97F4A7C15) & MASK
        z = self.state
        z = ((z ^ (z >> 30)) * 0xBF58476D1CE4E5B9) & MASK
        z = ((z ^ (z >> 27)) * 0x94D049BB133111EB) & MASK
        return z ^ (z >> 31)


def deterministic_sample(count, total, seed):
    """Port of Downloader.deterministicSample: one jittered index per equal band."""
    if total <= 0 or count <= 0:
        return set()
    if count >= total:
        return set(range(total))
    generator = SplitMix64(seed)
    indices = set()
    band = total / count
    for b in range(count):
        start = int(b * band)
        end = min(total - 1, int((b + 1) * band) - 1)
        span = max(1, end - start + 1)
        candidate = start + generator.next() % span
        while candidate in indices and span > 1:
            candidate = start + generator.next() % span
        indices.add(min(candidate, total - 1))
    return indices


def shard_files(config, split):
    url = f"https://huggingface.co/api/datasets/{REPO}/tree/main/{config}"
    with urllib.request.urlopen(url, timeout=60) as response:
        entries = json.load(response)
    prefix = f"{config}/{split}-"
    return sorted(e["path"] for e in entries if e["path"].startswith(prefix) and e["path"].endswith(".parquet"))


def download(path, cache):
    local = os.path.join(cache, path.replace("/", "__"))
    if not os.path.exists(local):
        url = f"https://huggingface.co/datasets/{REPO}/resolve/main/{path}"
        print(f"  fetching {path}", flush=True)
        urllib.request.urlretrieve(url, local + ".part")
        os.replace(local + ".part", local)
    return local


def main():
    import pyarrow.parquet as pq

    parser = argparse.ArgumentParser()
    parser.add_argument("--config", required=True)
    parser.add_argument("--split", required=True)
    parser.add_argument("--name", required=True)
    parser.add_argument("--data", default=os.path.join(os.getcwd(), "Evals", "data"))
    parser.add_argument("--cache", default=None, help="where parquet shards are kept (default: <data>/.parquet)")
    parser.add_argument("--sample", type=int, default=None)
    parser.add_argument("--seed", type=int, default=42)
    args = parser.parse_args()

    folder = os.path.join(args.data, args.name)
    cache = args.cache or os.path.join(args.data, ".parquet")
    os.makedirs(folder, exist_ok=True)
    os.makedirs(cache, exist_ok=True)
    shards = [download(p, cache) for p in shard_files(args.config, args.split)]
    if not shards:
        sys.exit(f"no parquet shards for {args.config}/{args.split}")
    total = sum(pq.ParquetFile(s).metadata.num_rows for s in shards)
    keep = deterministic_sample(args.sample, total, args.seed) if args.sample else None

    clips, row = [], 0
    for shard in shards:
        table = pq.read_table(shard, columns=["audio", "text", "id"])
        for audio, text, source_id in zip(*(table.column(c).to_pylist() for c in ("audio", "text", "id"))):
            index, row = row, row + 1
            if keep is not None and index not in keep:
                continue
            ext = os.path.splitext(audio.get("path") or "")[1].lstrip(".") or "wav"
            clip_id = f"{args.name}-{index:05d}"
            path = os.path.join(folder, f"{clip_id}.{ext}")
            if not os.path.exists(path):
                with open(path, "wb") as handle:
                    handle.write(audio["bytes"])
            clips.append({"id": clip_id, "audioPath": path, "reference": text, "sourceRowIndex": index,
                          "group": None, "speaker": source_id.split("-")[0] if args.config == "librispeech" else None})
    with open(os.path.join(folder, "manifest.json"), "w") as handle:
        json.dump(clips, handle)
    with open(os.path.join(folder, "manifest.provenance.json"), "w") as handle:
        json.dump({"dataset": REPO, "config": args.config, "split": args.split, "totalSourceRows": total,
                   "samplingMethod": f"deterministic-spread-seed-{args.seed}" if keep else "full-split",
                   "shards": [os.path.basename(s) for s in shards], "clips": len(clips)}, handle)
    print(f"{args.name}: {len(clips)} clips from {total} rows -> {folder}")


if __name__ == "__main__":
    main()
