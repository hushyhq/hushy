#!/usr/bin/env python3
"""Sample every EdAcc accent group into Evals/data/edacc-all-accents/manifest.json.

The same sample `murmur-eval us-english parity` would build through the Hugging Face
datasets-server (see Sources/murmur-eval/EdAccAccents.swift), without it: that API rate-limits
(HTTP 429 for an hour or more) after a few thousand requests. This reads the EdAcc parquet shards
with HTTP range requests instead, so it only transfers the text columns plus the audio of the
row groups it samples from (~100 rows each), not the dataset's ~7 GB.

Selection (documented in docs/product/US-ENGLISH-ACCURACY.md):
  * both splits (validation + test); nothing is tuned on EdAcc, and pooling doubles the speakers
  * accents with >= --min-clips scorable utterances; "Don't know" is not an accent and is dropped
  * per accent, up to --per-group clips, split as evenly as possible across its speakers
  * per speaker, the clips come from the parquet row group holding most of that speaker's
    utterances (contiguous turns of one conversation) — this keeps the transfer small; the
    clip order inside a row group is a seeded shuffle

Usage (needs pyarrow):
    python3 scripts/import-edacc.py [--per-group 100] [--min-clips 50] [--seed 42]
EdAcc: CC-BY-4.0, https://huggingface.co/datasets/edinburghcstr/edacc
"""
import argparse
import io
import json
import os
import random
import re
import urllib.request
from collections import defaultdict

REPO = "edinburghcstr/edacc"
SPLITS = ["validation", "test"]
EXCLUDED = {"Don't know"}


class HTTPFile(io.RawIOBase):
    """Seekable read-only file over HTTP range requests (enough for pyarrow's ParquetFile)."""

    def __init__(self, url):
        request = urllib.request.Request(url, method="HEAD")
        with urllib.request.urlopen(request, timeout=60) as response:
            self.size = int(response.headers["Content-Length"])
            self.url = response.url
        self.pos = 0
        self.transferred = 0

    def seekable(self):
        return True

    def readable(self):
        return True

    def tell(self):
        return self.pos

    def seek(self, offset, whence=0):
        self.pos = offset if whence == 0 else self.pos + offset if whence == 1 else self.size + offset
        return self.pos

    def read(self, n=-1):
        if n is None or n < 0:
            n = self.size - self.pos
        if n == 0 or self.pos >= self.size:
            return b""
        end = min(self.size, self.pos + n) - 1
        request = urllib.request.Request(self.url, headers={"Range": f"bytes={self.pos}-{end}"})
        with urllib.request.urlopen(request, timeout=120) as response:
            data = response.read()
        self.pos += len(data)
        self.transferred += len(data)
        return data

    def readinto(self, buffer):
        data = self.read(len(buffer))
        buffer[: len(data)] = data
        return len(data)


def scorable(text):
    if "IGNORE_TIME_SEGMENT" in text:
        return ""
    return re.sub(r"<[^>]+>", " ", text).strip()


def shards():
    url = f"https://huggingface.co/api/datasets/{REPO}/tree/main/data"
    with urllib.request.urlopen(url, timeout=60) as response:
        paths = [e["path"] for e in json.load(response)]
    for split in SPLITS:
        for path in sorted(p for p in paths if os.path.basename(p).startswith(split + "-")):
            yield split, f"https://huggingface.co/datasets/{REPO}/resolve/main/{path}"


def select(rows, per_group, min_clips, seed):
    """rows: dicts with split, index, speaker, accent, text, shard, group. Returns chosen rows."""
    usable = [r for r in rows if r["accent"] not in EXCLUDED and scorable(r["text"])]
    by_accent = defaultdict(list)
    for row in usable:
        by_accent[row["accent"]].append(row)
    chosen = []
    for accent in sorted(by_accent):
        group = by_accent[accent]
        if len(group) < min_clips:
            continue
        by_speaker = defaultdict(list)
        for row in group:
            by_speaker[row["speaker"]].append(row)
        speakers = sorted(by_speaker)
        quota = {s: per_group // len(speakers) + (1 if i < per_group % len(speakers) else 0) for i, s in enumerate(speakers)}
        # Speakers with fewer rows than their quota hand the remainder to the others.
        taken = []
        spare = 0
        for speaker in speakers:
            candidates = pick_for_speaker(by_speaker[speaker], quota[speaker], seed)
            spare += quota[speaker] - len(candidates)
            taken += candidates
        if spare > 0:
            leftovers = [r for s in speakers for r in by_speaker[s] if r not in taken]
            random.Random(f"{seed}|{accent}").shuffle(leftovers)
            leftovers.sort(key=lambda r: (r["shard"], r["group"]))  # stay in already-touched groups first
            touched = {(r["shard"], r["group"]) for r in taken}
            leftovers.sort(key=lambda r: (r["shard"], r["group"]) not in touched)
            taken += leftovers[:spare]
        chosen += taken
    return chosen


def pick_for_speaker(rows, quota, seed):
    """Up to `quota` rows, from the row groups holding most of this speaker's rows."""
    by_group = defaultdict(list)
    for row in rows:
        by_group[(row["shard"], row["group"])].append(row)
    picked = []
    for key in sorted(by_group, key=lambda k: (-len(by_group[k]), k)):
        members = sorted(by_group[key], key=lambda r: r["index"])
        random.Random(f"{seed}|{members[0]['speaker']}|{key}").shuffle(members)
        picked += members[: quota - len(picked)]
        if len(picked) >= quota:
            break
    return picked


def main():
    import pyarrow.parquet as pq

    parser = argparse.ArgumentParser()
    parser.add_argument("--per-group", type=int, default=100)
    parser.add_argument("--min-clips", type=int, default=50)
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--data", default=os.path.join(os.getcwd(), "Evals", "data"))
    parser.add_argument("--dry-run", action="store_true", help="print the plan and the audio bytes it would fetch")
    args = parser.parse_args()
    folder = os.path.join(args.data, "edacc-all-accents")
    os.makedirs(folder, exist_ok=True)

    files, rows, offsets = {}, [], defaultdict(int)
    for split, url in shards():
        handle = HTTPFile(url)
        parquet = pq.ParquetFile(handle)
        files[url] = (parquet, handle)
        for group in range(parquet.metadata.num_row_groups):
            table = parquet.read_row_group(group, columns=["speaker", "accent", "text"]).to_pylist()
            for position, row in enumerate(table):
                rows.append({**row, "split": split, "index": offsets[split], "shard": url, "group": group,
                             "position": position})
                offsets[split] += 1
    metadata_bytes = sum(h.transferred for _, h in files.values())
    chosen = select(rows, args.per_group, args.min_clips, args.seed)
    print(f"scanned {len(rows)} utterances ({metadata_bytes / 1e6:.0f} MB); sampling {len(chosen)} across "
          f"{len({r['accent'] for r in chosen})} accents from {len({(r['shard'], r['group']) for r in chosen})} row groups")

    clips = []
    needed = defaultdict(list)
    for row in chosen:
        needed[(row["shard"], row["group"])].append(row)
    audio_bytes = 0
    for url, group in needed:
        metadata = files[url][0].metadata
        names = [metadata.schema.column(i).path for i in range(metadata.num_columns)]
        audio_bytes += sum(metadata.row_group(group).column(i).total_compressed_size
                           for i, name in enumerate(names) if name.startswith("audio."))
    print(f"audio to fetch: {audio_bytes / 1e9:.2f} GB")
    if args.dry_run:
        return
    for (url, group), members in sorted(needed.items()):
        parquet, _ = files[url]
        audio = parquet.read_row_group(group, columns=["audio"]).column("audio").to_pylist()
        for row in members:
            clip_id = f"edacc-{row['split']}-{row['index']:05d}"
            ext = os.path.splitext(audio[row["position"]].get("path") or "")[1].lstrip(".") or "wav"
            path = os.path.join(folder, f"{clip_id}.{ext}")
            with open(path, "wb") as out:
                out.write(audio[row["position"]]["bytes"])
            clips.append({"id": clip_id, "audioPath": path, "reference": scorable(row["text"]), "group": row["accent"],
                          "speaker": row["speaker"], "sourceRowIndex": row["index"]})
    clips.sort(key=lambda c: c["id"])
    with open(os.path.join(folder, "manifest.json"), "w") as out:
        json.dump(clips, out)
    total = sum(h.transferred for _, h in files.values())
    print(f"edacc-all-accents: {len(clips)} clips, {total / 1e9:.2f} GB transferred -> {folder}")


if __name__ == "__main__":
    main()
