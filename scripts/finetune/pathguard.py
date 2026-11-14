"""Path guard and data manifest for the fine-tune pipeline (M7, docs/product/FINETUNE.md).

Every file the pipeline reads or writes goes through `Manifest.read_*` / `Manifest.write_*`,
which (1) refuses any path matching a forbidden pattern — the blind held-out sets
(`Evals/heldout-v2*`, `actions-heldout*`), Voice Lab data, and the app's own data directory
(`~/Library/Application Support/Hushy`) — and (2) records the path and its SHA-256, so the
manifest lists every source file and can prove no held-out path was touched.

`Sources/murmur-eval/Finetune/FinetunePathGuard.swift` enforces the same rule on the Swift side.
"""

from __future__ import annotations

import hashlib
import json
import os
import time
from pathlib import Path
from typing import Any, Iterable

# Lower-cased substrings that may never appear in a pipeline path. "heldout" covers
# `heldout-v2*` and `actions-heldout*`. Keep in sync with FinetunePathGuard.forbiddenPatterns.
FORBIDDEN_PATTERNS = (
    "heldout",
    "held-out",
    "held_out",
    "voicelab",
    "voice-lab",
    "voice_lab",
    "voice lab",
    "application support/hushy",
    "application support/murmur",
    # External public benchmarks (Evals/data/external/, `murmur-eval external`) are eval-only.
    "data/external",
    "disfluencyspeech",
    "disfl_qa",
    "disfl-qa",
    "disflqa",
    # The long-meeting digest eval (Evals/meeting-eval): eval-only, never training data.
    "meeting-eval",
    "/gate/",
    # Sealed by name in .claude/AGENTS.md. "heldout" and "voicelab" are above.
    # voicelab-prompts.json stays out of the filename prefix guard; this substring still
    # refuses it as training input. These three have no checked-in file on main.
    "ab-",
    "eval-long64-b",
    "longb",
    "runs/sealed",
)

# Sets written by a separate author to measure negative robustness (INDEX_ONLY_DEV_SETS below):
# refused as any pipeline input or output, like a sealed set. The one exception is
# `check_dev_set(..., INDEX_ONLY_DEV_SETS)`, the contamination index, which keeps training rows
# from overlapping them. Keep in sync with FinetunePathGuard.indexOnlyPatterns.
INDEX_ONLY_PATTERNS = (
    "negatives-fresh",
)

# Eval-only public benchmarks whose text also sits inside public sets we take training rows from.
# Their paths stay in FORBIDDEN_PATTERNS for every reader and writer. The one exception is
# `check_benchmark_source`, which reads them to build a hash-only contamination index so those
# rows can be dropped. Python only: the Swift guard has no such door.
BENCHMARK_INDEX_PATTERNS = (
    "disfluencyspeech",
    "disfl_qa",
    "disfl-qa",
    "disflqa",
)

# The only Evals/ files the data builder may read: dev sets used for sentence *shapes* and for
# the contamination check (training rows sharing an 8-gram with any of them are dropped).
DEV_SET_ALLOWLIST = (
    "dictation-golden.json",
    "reformat-golden.json",
    "grammar-golden.json",
    "overdeletion-golden.json",
    "long-golden.json",
    "user-dictation-golden.json",
    "frame-golden.json",
    "list-consistency-dev.json",
)

# v5.4: dev sets written by a separate author to measure negative robustness honestly. The data
# builder reads them for the contamination index ONLY (never for shapes), so training can never
# copy them and nothing about their content steers generation.
INDEX_ONLY_DEV_SETS = (
    "negatives-fresh-dev.json",
)

# Voice-actions eval sets the tool-calling data builder (scripts/finetune/tools) may read — for
# the contamination index and aggregate shapes only. The sealed actions held-out set is never on
# any list (and "heldout" is a forbidden pattern besides).
ACTIONS_DEV_ALLOWLIST = (
    "actions-tools-dev.json",
    "actions-golden.json",
    "adversarial-golden.json",
    "tools-v1.schema.json",
)


class ForbiddenPathError(PermissionError):
    """Raised for any path that matches a forbidden pattern or is outside the Evals allow-list."""


def violation(path: str | os.PathLike[str], index_only_ok: bool = False) -> str | None:
    """The first forbidden pattern `path` matches (as given or symlink-resolved), or None.
    INDEX_ONLY_PATTERNS count too unless `index_only_ok` (the contamination index read)."""
    patterns = FORBIDDEN_PATTERNS if index_only_ok else FORBIDDEN_PATTERNS + INDEX_ONLY_PATTERNS
    return _first_match(path, patterns)


# Sealed families named by a file-name prefix: they match only where a path component starts, so a temp folder such
# as `...-9B91E6AB-AD3C...` is not mistaken for `ab-...`. Keep in sync with FinetunePathGuard.componentPrefixPatterns.
COMPONENT_PREFIX_PATTERNS = frozenset({"ab-", "eval-long64-b", "longb"})


def _matches(candidate: str, pattern: str) -> bool:
    if pattern not in COMPONENT_PREFIX_PATTERNS:
        return pattern in candidate
    return candidate.startswith(pattern) or ("/" + pattern) in candidate


def _first_match(path: str | os.PathLike[str], patterns: tuple[str, ...]) -> str | None:
    raw = os.fspath(path)
    candidates = {raw.lower(), os.path.realpath(raw).lower(), os.path.abspath(raw).lower()}
    for pattern in patterns:
        if any(_matches(candidate, pattern) for candidate in candidates):
            return pattern
    return None


def check(path: str | os.PathLike[str], index_only_ok: bool = False) -> Path:
    """`path` as a Path, or raises ForbiddenPathError."""
    pattern = violation(path, index_only_ok)
    if pattern is not None:
        raise ForbiddenPathError(f"refusing {os.fspath(path)!r}: matches forbidden pattern {pattern!r}")
    return Path(path)


def check_benchmark_source(path: str | os.PathLike[str]) -> Path:
    """A benchmark text file read for the contamination index ONLY (hashes out, never text).

    Not a general reader: the path, with symlinks resolved, MUST match one of
    BENCHMARK_INDEX_PATTERNS, so a benchmark-looking link to any other file is refused. Those
    patterns are the only ones lifted: every other forbidden and index-only pattern still refuses
    (as given or resolved), and `check` is unchanged for every other caller. Returns the resolved
    path, so the file read is the one that was judged."""
    raw = os.fspath(path)
    resolved = os.path.realpath(raw)
    patterns = tuple(pattern for pattern in FORBIDDEN_PATTERNS + INDEX_ONLY_PATTERNS
                     if pattern not in BENCHMARK_INDEX_PATTERNS)
    pattern = _first_match(raw, patterns)
    if pattern is not None:
        raise ForbiddenPathError(f"refusing {raw!r}: matches forbidden pattern {pattern!r}")
    if not any(pattern in resolved.lower() for pattern in BENCHMARK_INDEX_PATTERNS):
        raise ForbiddenPathError(f"refusing {raw!r}: not a benchmark source (its resolved path matches none of "
                                 f"{BENCHMARK_INDEX_PATTERNS})")
    return Path(resolved)


def check_dev_set(path: str | os.PathLike[str], allowlist: tuple[str, ...] = DEV_SET_ALLOWLIST) -> Path:
    """A dev-set path: must pass `check` and be one of `allowlist` (default DEV_SET_ALLOWLIST)."""
    resolved = check(path, index_only_ok=allowlist == INDEX_ONLY_DEV_SETS)
    if resolved.name not in allowlist:
        raise ForbiddenPathError(f"refusing {os.fspath(path)!r}: not on the dev-set allow-list {allowlist}")
    return resolved


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def sha256_text(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


class Manifest:
    """Records every file read/written, plus arbitrary sections (counts, prompts, seeds)."""

    def __init__(self, root: Path) -> None:
        self.root = root
        self.reads: dict[str, str] = {}
        self.writes: dict[str, str] = {}
        self.sections: dict[str, Any] = {"created": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}

    # -- guarded I/O ---------------------------------------------------------------------------

    def _relative(self, path: Path) -> str:
        try:
            return str(path.resolve().relative_to(self.root.resolve()))
        except ValueError:
            return str(path.resolve())

    def record_read(self, path: str | os.PathLike[str], dev_set: bool = False,
                    allowlist: tuple[str, ...] = DEV_SET_ALLOWLIST) -> Path:
        resolved = check_dev_set(path, allowlist) if dev_set else check(path)
        self.reads[self._relative(resolved)] = sha256_file(resolved)
        return resolved

    def read_json(self, path: str | os.PathLike[str], dev_set: bool = False,
                  allowlist: tuple[str, ...] = DEV_SET_ALLOWLIST) -> Any:
        resolved = self.record_read(path, dev_set=dev_set, allowlist=allowlist)
        with open(resolved, encoding="utf-8") as handle:
            return json.load(handle)

    def read_jsonl(self, path: str | os.PathLike[str]) -> list[dict[str, Any]]:
        resolved = self.record_read(path)
        with open(resolved, encoding="utf-8") as handle:
            return [json.loads(line) for line in handle if line.strip()]

    def write_jsonl(self, path: str | os.PathLike[str], rows: Iterable[dict[str, Any]]) -> Path:
        resolved = check(path)
        resolved.parent.mkdir(parents=True, exist_ok=True)
        with open(resolved, "w", encoding="utf-8") as handle:
            for row in rows:
                handle.write(json.dumps(row, ensure_ascii=False, sort_keys=True) + "\n")
        self.record_write(resolved)
        return resolved

    def write_json(self, path: str | os.PathLike[str], payload: Any) -> Path:
        resolved = check(path)
        resolved.parent.mkdir(parents=True, exist_ok=True)
        with open(resolved, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, ensure_ascii=False, indent=2, sort_keys=True)
            handle.write("\n")
        self.record_write(resolved)
        return resolved

    def record_write(self, path: str | os.PathLike[str]) -> None:
        resolved = check(path)
        self.writes[self._relative(resolved)] = sha256_file(resolved)

    # -- the proof -----------------------------------------------------------------------------

    def assert_clean(self) -> dict[str, Any]:
        """Re-checks every recorded path; returns the proof section or raises."""
        touched = sorted(set(self.reads) | set(self.writes))
        # An index-only dev set may be *read* (for the contamination index), never written.
        index_only_reads = [path for path in self.reads if Path(path).name in INDEX_ONLY_DEV_SETS]
        offenders = [path for path in touched
                     if violation(path, index_only_ok=path in index_only_reads and path not in self.writes) is not None]
        if offenders:
            raise ForbiddenPathError(f"manifest lists forbidden paths: {offenders}")
        return {
            "forbiddenPatterns": list(FORBIDDEN_PATTERNS),
            "indexOnlyPatterns": list(INDEX_ONLY_PATTERNS),
            "pathsChecked": len(touched),
            "forbiddenPathsTouched": 0,
            "devSetAllowList": list(DEV_SET_ALLOWLIST),
            "indexOnlyReads": sorted(index_only_reads),
        }

    def to_dict(self) -> dict[str, Any]:
        payload = dict(self.sections)
        payload["heldoutProof"] = self.assert_clean()
        payload["reads"] = dict(sorted(self.reads.items()))
        payload["writes"] = dict(sorted(self.writes.items()))
        return payload

    def save(self, path: str | os.PathLike[str]) -> Path:
        resolved = check(path)
        resolved.parent.mkdir(parents=True, exist_ok=True)
        with open(resolved, "w", encoding="utf-8") as handle:
            json.dump(self.to_dict(), handle, ensure_ascii=False, indent=2, sort_keys=True)
            handle.write("\n")
        return resolved
