"""Dev-set *shapes* (never text) and the contamination index.

The fine-tune may learn from the dev sets' shapes — which categories exist, how long drafts are,
which correction cues and fillers people use — but never from their sentences: every dev input,
reference and expected text goes into an n-gram index, and any training row sharing an 8-gram
(or, for short rows, the whole normalized text) with a dev text is dropped. The dev sets are
what we report on, so copying them into training would make every dev number meaningless.
"""

from __future__ import annotations

import collections
import re
from pathlib import Path
from typing import Any

from pathguard import DEV_SET_ALLOWLIST, INDEX_ONLY_DEV_SETS, Manifest

CUE_PATTERNS = {
    "no": r"\bno\b",
    "no wait": r"\bno wait\b",
    "wait": r"\bwait\b",
    "i mean": r"\bi mean\b",
    "i meant": r"\bi meant\b",
    "sorry": r"\bsorry\b",
    "actually": r"\bactually\b",
    "scratch that": r"\bscratch that\b",
    "forget": r"\bforget\b",
    "never mind": r"\bnever ?mind\b",
    "make it": r"\bmake it\b",
    "not": r"\bnot\b",
    "leave it": r"\bleave it\b",
    "skip": r"\bskip\b",
    "drop": r"\bdrop\b",
    "cancel": r"\bcancel\b",
}
FILLER_PATTERNS = {
    "um": r"\bum+\b",
    "uh": r"\buh+\b",
    "you know": r"\byou know\b",
    "like": r"\blike\b",
    "basically": r"\bbasically\b",
    "kind of": r"\bkind of\b",
    "so (lead)": r"^(okay |yeah )?so\b",
    "right (tag)": r"\bright\b",
    "honestly": r"\bhonestly\b",
}
STUTTER = re.compile(r"\b(\w+(?: \w+){0,3}) \1\b")
WORD = re.compile(r"[a-z0-9']+")


def words(text: str) -> list[str]:
    return WORD.findall(text.lower())


def normalized(text: str) -> str:
    return " ".join(words(text))


def dev_texts(case: dict[str, Any]) -> list[str]:
    """Every string in a dev case that could leak: inputs, references, expected, alternatives."""
    texts: list[str] = []
    for key in ("spoken", "input", "expected", "reference"):
        if isinstance(case.get(key), str):
            texts.append(case[key])
    texts.extend(alt for alt in case.get("alternatives") or [] if isinstance(alt, str))
    for level in (case.get("levels") or {}).values():
        if isinstance(level.get("reference"), str):
            texts.append(level["reference"])
    return texts


def load_dev_sets(evals_dir: Path, manifest: Manifest) -> dict[str, list[dict[str, Any]]]:
    sets = {}
    for name in DEV_SET_ALLOWLIST:
        path = evals_dir / name
        if path.exists():
            sets[name] = manifest.read_json(path, dev_set=True)
    return sets


def load_index_only_sets(evals_dir: Path, manifest: Manifest) -> dict[str, list[dict[str, Any]]]:
    """Dev sets that only feed the contamination index (INDEX_ONLY_DEV_SETS), never shapes."""
    sets = {}
    for name in INDEX_ONLY_DEV_SETS:
        path = evals_dir / name
        if path.exists():
            sets[name] = manifest.read_json(path, dev_set=True, allowlist=INDEX_ONLY_DEV_SETS)
    return sets


def shape_profile(sets: dict[str, list[dict[str, Any]]]) -> dict[str, Any]:
    """Counts only — categories, lengths, cue and filler inventories. No sentences."""
    spoken = []
    categories: collections.Counter[str] = collections.Counter()
    buckets: collections.Counter[str] = collections.Counter()
    for name, cases in sets.items():
        for case in cases:
            text = case.get("spoken") or case.get("input") or ""
            spoken.append(text.lower())
            categories[f"{name}:{case.get('category') or case.get('tag') or 'none'}"] += 1
            count = len(words(text))
            buckets["short (<=15)" if count <= 15 else "medium (16-40)" if count <= 40 else "long (>40)"] += 1
    cues = {cue: sum(bool(re.search(p, t)) for t in spoken) for cue, p in CUE_PATTERNS.items()}
    fillers = {filler: sum(bool(re.search(p, t)) for t in spoken) for filler, p in FILLER_PATTERNS.items()}
    stutter_lengths: collections.Counter[int] = collections.Counter()
    for text in spoken:
        for match in STUTTER.finditer(text):
            stutter_lengths[len(match.group(1).split())] += 1
    return {
        "cases": len(spoken),
        "categories": dict(sorted(categories.items())),
        "lengthBuckets": dict(buckets),
        "cueUsage": cues,
        "fillerUsage": fillers,
        "stutterSpanWords": {str(k): v for k, v in sorted(stutter_lengths.items())},
        "lowercaseUnpunctuatedShare": round(
            sum(1 for t in spoken if t == t.lower() and not re.search(r"[.?!]$", t.strip())) / max(1, len(spoken)), 3
        ),
    }


class ContaminationIndex:
    """8-gram (and whole-text for short texts) index over every dev text."""

    def __init__(self, sets: dict[str, list[dict[str, Any]]], n: int = 8) -> None:
        self.n = n
        self.ngrams: set[tuple[str, ...]] = set()
        self.short: set[str] = set()
        self._dev_texts: list[str] = []
        for cases in sets.values():
            for case in cases:
                for text in dev_texts(case):
                    self._dev_texts.append(text)
                    tokens = words(text)
                    if len(tokens) < n:
                        self.short.add(" ".join(tokens))
                    for i in range(len(tokens) - n + 1):
                        self.ngrams.add(tuple(tokens[i : i + n]))

    # v5.5 near-duplicate check: word-trigram overlap with any single dev text. A training text is
    # "near" a dev text when they share at least NEAR_MIN_SHARED trigrams covering NEAR_SHARE of
    # either one's trigrams — paraphrases that keep the dev sentence's skeleton ("Assign it to X,
    # no, Y, they also I think…") are caught even with new names.
    NEAR_K = 3
    NEAR_SHARE = 0.5
    NEAR_MIN_SHARED = 3

    def _build_near(self) -> None:
        self._texts: list[set[tuple[str, ...]]] = []
        self._by_gram: dict[tuple[str, ...], list[int]] = collections.defaultdict(list)
        for text in self._dev_texts:
            grams = self._grams(text)
            if not grams:
                continue
            index = len(self._texts)
            self._texts.append(grams)
            for gram in grams:
                self._by_gram[gram].append(index)

    def _grams(self, text: str) -> set[tuple[str, ...]]:
        tokens = words(text)
        return {tuple(tokens[i : i + self.NEAR_K]) for i in range(len(tokens) - self.NEAR_K + 1)}

    def near(self, text: str) -> bool:
        """True when `text` shares most of its (or a dev text's) word trigrams with one dev text."""
        if not hasattr(self, "_texts"):
            self._build_near()
        grams = self._grams(text)
        if not grams:
            return False
        shared: collections.Counter[int] = collections.Counter()
        for gram in grams:
            for index in self._by_gram.get(gram, ()):
                shared[index] += 1
        for index, count in shared.items():
            if count < self.NEAR_MIN_SHARED:
                continue
            if count / len(grams) >= self.NEAR_SHARE or count / len(self._texts[index]) >= self.NEAR_SHARE:
                return True
        return False

    def hits(self, text: str) -> bool:
        tokens = words(text)
        if " ".join(tokens) in self.short:
            return True
        return any(tuple(tokens[i : i + self.n]) in self.ngrams for i in range(len(tokens) - self.n + 1))
