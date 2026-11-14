"""Shared pieces for the meeting-extract data builders: the row shape, the chunker, the
contamination index and the row validator. The format is specified in
docs/research/meeting-extract-data-2026-11-06.md.
"""
import hashlib
import json
import os
import re
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np

KINDS = ("decision", "action", "open_question", "change")
TARGET_WORDS = 1800
MAX_WORDS = 2600
MIN_LAST_WORDS = 600
MAX_QUOTE_WORDS = 80
MIN_QUOTE_WORDS = 3

REPO_ROOT = Path(__file__).resolve().parents[2]
# Where the downloaded and built meeting-extract files live (git-ignored); HUSHY_MEETING_DATA overrides it.
DATA_ROOT = Path(os.environ.get("HUSHY_MEETING_DATA", REPO_ROOT / ".build/public-data/meeting-extract"))
# The cleanup model's training rows, for the contamination index; HUSHY_CLEANUP_TRAIN_DIR overrides the folder.
_CLEANUP_TRAIN = Path(os.environ.get("HUSHY_CLEANUP_TRAIN_DIR", REPO_ROOT / ".build/modal-staging/data-r10d"))
TRAIN_FILES = [str(_CLEANUP_TRAIN / "train.jsonl"), str(_CLEANUP_TRAIN / "valid.jsonl")]
NGRAM = 10
TOKEN = re.compile(r"[a-z0-9']+")
_PRIME = np.uint64(1000003)


def normalized(text: str) -> list:
    return TOKEN.findall(text.lower())


def stable_hash(text: str) -> int:
    return int(hashlib.sha256(text.encode()).hexdigest(), 16)


@dataclass
class Turn:
    speaker: str | None
    start: float | None
    text: str


@dataclass
class Chunk:
    turns: list
    first_turn: int

    @property
    def words(self) -> int:
        return sum(len(t.text.split()) for t in self.turns)


def stamp(seconds: float | None) -> str:
    if seconds is None:
        return ""
    s = int(seconds)
    return f"[{s // 3600}:{s % 3600 // 60:02d}:{s % 60:02d}] " if s >= 3600 else f"[{s // 60:02d}:{s % 60:02d}] "


def render_turn(turn: Turn) -> str:
    prefix = stamp(turn.start) + (f"{turn.speaker}: " if turn.speaker else "")
    return prefix + turn.text


def render(chunk: Chunk) -> str:
    return "\n".join(render_turn(t) for t in chunk.turns)


def split_long_turn(turn: Turn, limit: int) -> list:
    """A turn longer than `limit` words is cut at sentence ends so a chunk can close on a boundary."""
    if len(turn.text.split()) <= limit:
        return [turn]
    pieces, current, count = [], [], 0
    for sentence in re.split(r"(?<=[.?!])\s+", turn.text):
        n = len(sentence.split())
        if current and count + n > limit:
            pieces.append(Turn(turn.speaker, turn.start if not pieces else None, " ".join(current)))
            current, count = [], 0
        current.append(sentence)
        count += n
    if current:
        pieces.append(Turn(turn.speaker, turn.start if not pieces else None, " ".join(current)))
    return pieces


def chunk_turns(turns: list, split_long: bool = False) -> list:
    """Greedy chunks of about TARGET_WORDS at turn boundaries; a short tail joins the previous chunk.
    With `split_long` a turn over half the cap is cut at sentence ends (for text with no real turns)."""
    flat = [p for t in turns for p in (split_long_turn(t, MAX_WORDS // 2) if split_long else [t])]
    chunks, current, count, index = [], [], 0, 0
    for turn in flat:
        n = len(turn.text.split())
        if current and (count >= TARGET_WORDS or count + n > MAX_WORDS):
            chunks.append(Chunk(current, index))
            index += len(current)
            current, count = [], 0
        current.append(turn)
        count += n
    if current:
        tail = Chunk(current, index)
        if chunks and tail.words < MIN_LAST_WORDS and chunks[-1].words + tail.words <= MAX_WORDS + 400:
            chunks[-1] = Chunk(chunks[-1].turns + tail.turns, chunks[-1].first_turn)
        else:
            chunks.append(tail)
    return chunks


class TrainIndex:
    """Hashed 10-grams of the r10d training text (train + valid), for overlap tests.

    `probe_hits` repeats scripts/meeting-eval/build_public_ami.py's contamination check (6 probes of
    10 tokens spread along a meeting, a hit when the probe is a substring of the normalised training
    text). `overlap` is a denser measure over every 10-gram of a text.
    """

    def __init__(self, cache_dir: Path):
        cache_dir.mkdir(parents=True, exist_ok=True)
        self.vocab_path, self.hash_path = cache_dir / "vocab.json", cache_dir / "ngrams.npy"
        if self.hash_path.exists() and self.vocab_path.exists():
            self.vocab = json.loads(self.vocab_path.read_text())
            self.hashes = np.load(self.hash_path)
            return
        self.vocab, ids = {}, []
        present = [path for path in TRAIN_FILES if Path(path).exists()]
        if not present:
            # A checkout without cleanup training data (the public recipe): nothing to overlap with.
            print(f"note: no cleanup training files under {_CLEANUP_TRAIN}; the overlap index is empty "
                  "(set HUSHY_CLEANUP_TRAIN_DIR to your own train.jsonl/valid.jsonl folder)")
        for path in present:
            with open(path, encoding="utf-8", errors="ignore") as f:
                for line in f:
                    for tok in TOKEN.findall(line.lower()):
                        ids.append(self.vocab.setdefault(tok, len(self.vocab) + 1))
        self.hashes = np.unique(self._grams(np.asarray(ids, dtype=np.uint64)))
        np.save(self.hash_path, self.hashes)
        self.vocab_path.write_text(json.dumps(self.vocab))

    @staticmethod
    def _grams(ids: np.ndarray) -> np.ndarray:
        if len(ids) < NGRAM:
            return np.zeros(0, dtype=np.uint64)
        h = np.zeros(len(ids) - NGRAM + 1, dtype=np.uint64)
        with np.errstate(over="ignore"):
            for k in range(NGRAM):
                h = h * _PRIME + ids[k:len(ids) - NGRAM + 1 + k]
        return h

    def overlap(self, text: str) -> tuple:
        """(10-grams present in training text, 10-grams in text)."""
        ids = np.asarray([self.vocab.get(t, 0) for t in normalized(text)], dtype=np.uint64)
        grams = self._grams(ids)
        if not len(grams):
            return 0, 0
        pos = np.searchsorted(self.hashes, grams)
        pos[pos >= len(self.hashes)] = 0
        return int((self.hashes[pos] == grams).sum()), len(grams)

    def probe_hits(self, text: str, probes: int = 6, length: int = 10) -> int:
        tokens = normalized(text)
        if len(tokens) < length * probes:
            return 0
        step = len(tokens) // (probes + 1)
        hits = 0
        for k in range(1, probes + 1):
            ids = np.asarray([self.vocab.get(t, 0) for t in tokens[k * step:k * step + length]], dtype=np.uint64)
            gram = self._grams(ids)
            if len(gram):
                pos = int(np.searchsorted(self.hashes, gram[0]))
                hits += int(pos < len(self.hashes) and self.hashes[pos] == gram[0])
        return hits


@dataclass
class Record:
    kind: str
    text: str
    owner: str | None
    due: str | None
    quote: str

    def as_output(self) -> dict:
        return {"kind": self.kind, "text": self.text, "owner": self.owner, "due": self.due, "quote": self.quote}


def make_row(*, source: str, licence: str, commercial_safe: bool, meeting_id: str, series: str, chunk_no: int,
             chunk_total: int, chunk: Chunk, meeting_meta: dict, split: str, gold: str,
             records: list | None, notes: dict) -> dict:
    transcript = render(chunk)
    stamped = [t.start for t in chunk.turns if t.start is not None]
    return {
        "id": f"{source}:{meeting_id}:c{chunk_no:02d}",
        "source": source,
        "licence": licence,
        "commercial_safe": commercial_safe,
        "meeting_id": meeting_id,
        "series": series,
        "chunk_index": chunk_no,
        "chunk_count": chunk_total,
        "split": split,
        "gold": gold,
        "input": {
            "meeting": {**meeting_meta, "chunk": f"{chunk_no + 1} of {chunk_total}"},
            "transcript": transcript,
        },
        "output": None if records is None else [r.as_output() for r in records],
        "stats": {
            "words": chunk.words, "turns": len(chunk.turns),
            "start_s": min(stamped) if stamped else None, "end_s": max(stamped) if stamped else None,
        },
        "notes": notes,
    }


def validate_row(row: dict) -> list:
    """Problems with one row; empty when it is sound. A gold quote must be a substring of one turn's text."""
    problems = []
    transcript = row["input"]["transcript"]
    lines = transcript.split("\n")
    if row["output"] is None:
        return problems
    for i, rec in enumerate(row["output"]):
        if rec["kind"] not in KINDS:
            problems.append(f"{i}: kind {rec['kind']}")
        if not rec["text"].strip():
            problems.append(f"{i}: empty text")
        n = len(rec["quote"].split())
        if not MIN_QUOTE_WORDS <= n <= MAX_QUOTE_WORDS:
            problems.append(f"{i}: quote words {n}")
        if not any(rec["quote"] in line for line in lines):
            problems.append(f"{i}: quote not in one line")
        if rec["owner"] is not None and rec["owner"] not in transcript:
            problems.append(f"{i}: owner not a speaker label")
        if rec["due"] is not None and rec["due"].lower() not in transcript.lower():
            problems.append(f"{i}: due not in transcript")
    return problems


def write_jsonl(path: Path, rows: list) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        for row in rows:
            f.write(json.dumps(row, ensure_ascii=False) + "\n")


def content_words(text: str) -> set:
    """Content words cut to five letters, so 'designing' and 'designer' match."""
    return {w[:5] for w in normalized(text) if len(w) > 2 and w not in STOP}


STOP = set("""the and for that with this will have from they their there them then than what when which would
could should about into over also are was were been being has had does did not but can its our out who how all any some
more most other such only own same too very just team group meeting need needs""".split())
