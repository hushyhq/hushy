#!/usr/bin/env python3
"""Contamination index for eval-only public benchmarks: hashes of normalised text, never text.

Some public training sets contain rows taken from benchmarks we only evaluate on. Rows carry no
source label, so `build` hashes the benchmark text and `retrain_public_rows.py assemble
--exclude-index` drops any added row whose spoken text or label hashes the same.

By default the index is a JSON list of whole-string hashes. With `shingles=True` it is an object
that also holds the hash of every 8-word run of each benchmark string, and `assemble` then also
drops a row that shares any such run (a benchmark sentence quoted inside a longer row)."""

from collections import namedtuple
import hashlib
import json
from pathlib import Path
import re
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent / "finetune"))
from pathguard import check, check_benchmark_source  # noqa: E402


# Disfl-QA's two fields, then the generic ones.
INDEX_FIELDS = ("original", "disfluent", "text", "spoken", "reference", "transcript")
SHA256_HEX = re.compile(r"[0-9a-f]{64}")
SHINGLE_WORDS = 8
# What `assemble` matches rows against: whole-string hashes and (possibly no) shingle hashes.
Index = namedtuple("Index", "whole shingles")
EMPTY = Index(frozenset(), frozenset())


def normalise(text):
    """Lower-case; keep only letters, digits and single spaces."""
    kept = "".join(char for char in text.lower() if char.isalnum() or char.isspace())
    return " ".join(kept.split())


def text_hash(text):
    return hashlib.sha256(normalise(text).encode("utf-8")).hexdigest()


def shingle_hashes(text):
    """Hashes of every run of SHINGLE_WORDS normalised words; none for a shorter text."""
    tokens = normalise(text).split()
    return {hashlib.sha256(" ".join(tokens[start:start + SHINGLE_WORDS]).encode("utf-8")).hexdigest()
            for start in range(len(tokens) - SHINGLE_WORDS + 1)}


def benchmark_strings(node):
    """Indexable strings in a Disfl-QA dict (id -> record), a list, or one JSONL object."""
    if isinstance(node, dict):
        found = [node[field] for field in INDEX_FIELDS if isinstance(node.get(field), str)]
        return found or [text for value in node.values() for text in benchmark_strings(value)]
    if isinstance(node, list):
        return [text for item in node for text in benchmark_strings(item)]
    return []


def read_benchmark(path):
    """Benchmark text, read through the guard's index-only door; callers keep hashes only."""
    unreadable = ValueError(f"{path} is neither JSON nor JSON lines (export other formats to JSON lines first)")
    try:
        raw = check_benchmark_source(path).read_text(encoding="utf-8")
    except UnicodeDecodeError:
        raise unreadable from None
    try:
        parsed = json.loads(raw)
    except json.JSONDecodeError:
        try:
            parsed = [json.loads(line) for line in raw.splitlines() if line.strip()]
        except json.JSONDecodeError:
            raise unreadable from None
    return [text for text in benchmark_strings(parsed) if normalise(text)]


def build(sources, out, shingles=False):
    """Writes the contamination index (hashes only, never text) and returns its counts."""
    out = check(out)
    if not sources:
        raise ValueError("benchmark-index needs at least one --source")
    whole, runs, strings = set(), set(), {}
    for source in sources:
        texts = read_benchmark(source)
        if not texts:
            raise ValueError(f"no indexable text in {source} (fields: {', '.join(INDEX_FIELDS)})")
        strings[str(source)] = len(texts)
        whole.update(text_hash(text) for text in texts)
        if shingles:
            runs.update(*(shingle_hashes(text) for text in texts))
    payload = ({"whole": sorted(whole), "shingles": sorted(runs), "shingle_words": SHINGLE_WORDS}
               if shingles else sorted(whole))
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(payload, indent=0) + "\n", encoding="utf-8")
    return {"index": str(out), "strings": strings, "hashes": len(whole), "shingles": len(runs)}


def _hash_list(value):
    return isinstance(value, list) and all(isinstance(item, str) and SHA256_HEX.fullmatch(item) for item in value)


def read(manifest, path):
    """An index written by `build`, recorded in the run's manifest. Anything else is refused."""
    try:
        loaded = manifest.read_json(path)
    except json.JSONDecodeError:
        loaded = None
    if _hash_list(loaded):
        return Index(frozenset(loaded), frozenset())
    if (isinstance(loaded, dict) and _hash_list(loaded.get("whole")) and _hash_list(loaded.get("shingles"))
            and loaded.get("shingle_words") == SHINGLE_WORDS):
        return Index(frozenset(loaded["whole"]), frozenset(loaded["shingles"]))
    raise ValueError(f"{path} is not a contamination index (a JSON list of SHA-256 hashes, or the "
                     f"{SHINGLE_WORDS}-word shingle form written by benchmark-index --shingles)")


def combine(indexes):
    """One Index holding everything in `indexes`."""
    return Index(frozenset().union(*(item.whole for item in indexes)),
                 frozenset().union(*(item.shingles for item in indexes)))


def overlap(excluded, *texts):
    """Why a row overlaps the index: its whole text is a benchmark string, it shares a shingle, or None."""
    if excluded.whole and any(text_hash(text) in excluded.whole for text in texts):
        return "benchmark_overlap"
    if excluded.shingles and any(shingle_hashes(text) & excluded.shingles for text in texts):
        return "benchmark_shingle_overlap"
    return None
