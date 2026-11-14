#!/usr/bin/env python3
"""Sealed-eval guard for Python tooling (the fine-tune data pipeline, probes, dedupe scripts).

Mirrors `SealedEvalGuard` in MurmurCore: a synthetic-data generator or any tuning script must call
`assert_tuning_safe(path)` on every file it opens. A path is refused when its file name starts with
a sealed prefix (`actions-heldout`, `heldout-v2`, `meeting-heldout`), or when its bytes hash to a sealed set listed in
`Evals/sealed-sets.json` (so a renamed copy is refused too). See .claude/AGENTS.md.

    from sealed_guard import assert_tuning_safe
    assert_tuning_safe("Evals/actions-tools-dev.json")   # fine
    assert_tuning_safe("Evals/actions-heldout.json")     # raises SealedEvalRefusal

`python3 scripts/sealed_guard.py <path>...` exits 1 if any path is sealed; `--self-test` checks itself.
"""
import hashlib
import json
import os
import sys
import tempfile

# File-name prefixes. `voicelab-` is not here: `Evals/voicelab-prompts.json` is on this branch,
# and the absence check refuses any name these prefixes match. pathguard and the judges still
# refuse voicelab paths. `ab-`, `eval-long64-b` and `longb` have no checked-in file on main.
SEALED_PREFIXES = (
    "actions-heldout", "heldout-v2", "meeting-heldout", "ab-", "eval-long64-b", "longb",
)
MAX_HASHED_BYTES = 50 * 1024 * 1024
MANIFEST = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Evals", "sealed-sets.json")


class SealedEvalRefusal(Exception):
    pass


def sealed_hashes(manifest=MANIFEST):
    with open(manifest) as handle:
        return {entry["sha256"] for entry in json.load(handle)["sets"]}


def is_sealed_path(path):
    for candidate in (os.path.abspath(path), os.path.realpath(path)):
        parts = candidate.lower().split(os.sep)
        if parts[-1].startswith(SEALED_PREFIXES) or any(
            pair == ("runs", "sealed") for pair in zip(parts, parts[1:])
        ):
            return True
    return False


def sha256(path):
    if not os.path.isfile(path) or os.path.getsize(path) > MAX_HASHED_BYTES:
        return None
    with open(path, "rb") as handle:
        return hashlib.sha256(handle.read()).hexdigest()


def assert_tuning_safe(path, purpose="synthetic-data generator", manifest=MANIFEST):
    if is_sealed_path(path):
        raise SealedEvalRefusal(f"refused: {path} is a sealed held-out set; {purpose} may never read it")
    if sha256(path) in sealed_hashes(manifest):
        raise SealedEvalRefusal(f"refused: {path} has the contents of a sealed held-out set; {purpose} may never read it")


def _self_test():
    with tempfile.TemporaryDirectory() as directory:
        plain = os.path.join(directory, "dev.json")
        with open(plain, "w") as handle:
            handle.write("{}")
        assert_tuning_safe(plain)
        for name in ("actions-heldout.json", "Heldout-v2-clean.json", "ab-session.jsonl",
                     "eval-long64-b1.jsonl", "longb-notes.jsonl", "runs/sealed/private.jsonl",
                     "Runs/Sealed/nested/dev.json"):
            try:
                assert_tuning_safe(os.path.join(directory, name))
                raise AssertionError(f"{name} was not refused")
            except SealedEvalRefusal:
                pass
        manifest = os.path.join(directory, "sealed.json")
        with open(manifest, "w") as handle:
            json.dump({"sets": [{"sha256": sha256(plain)}]}, handle)
        try:
            assert_tuning_safe(plain, manifest=manifest)
            raise AssertionError("renamed copy was not refused")
        except SealedEvalRefusal:
            pass
    print("sealed_guard self-test: ok")


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        _self_test()
        sys.exit(0)
    failed = False
    for argument in sys.argv[1:]:
        try:
            assert_tuning_safe(argument, purpose="this script")
        except SealedEvalRefusal as refusal:
            print(refusal, file=sys.stderr)
            failed = True
    sys.exit(1 if failed else 0)
