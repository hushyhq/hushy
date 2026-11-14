"""Conservative, mechanical per-group label provenance audit.

Findings require review: a lexical match cannot prove that a clause kept its meaning.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))

import api_judge_guard as guard
import retrain_groups
import retrain_numbers
from retrain_lexicon import expand_sequence, stem, words

# Grammar repairs allowed by the brief. Relations such as "at" and "from" are
# intentionally absent: adding them can assert a new fact.
GRAMMAR_INSERTIONS = frozenset("a an the is are was were be to of and or it".split())


def _forms(text):
    return {stem(part) for word in words(text) for part in expand_sequence(word)}


def _values(text):
    return {v for number in retrain_numbers.extract(text)
            for v in (number.value, *number.alternates)}


def _licensed(word, group):
    source = group.get("text", "") + " " + group.get("draft", "")
    if word in GRAMMAR_INSERTIONS:
        return True
    if word[0].isdigit():
        return True  # Numeric values are compared as complete expressions below.
    return all(stem(part) in _forms(source) for part in expand_sequence(word))


def check(group_row, target):
    """Return findings with group index, kind and evidence; do not silently fix labels."""
    groups = group_row["groups"]
    pieces = target["pieces"]
    findings = []
    if len(groups) != len(pieces):
        findings.append({"kind": "piece_count", "expected": len(groups), "actual": len(pieces)})
    if retrain_groups.join_pieces(pieces) != target["typed"]:
        findings.append({"kind": "joined_mismatch"})
    for index, (group, piece_row) in enumerate(zip(groups, pieces)):
        piece = piece_row["piece"]
        source = group.get("text", "") + " " + group.get("draft", "")
        if len(words(piece)) <= 1 and len(words(source)) >= 5:
            findings.append({"kind": "short_clause", "index": index, "piece": piece})
        for value in sorted(_values(piece) - _values(source), key=str):
            findings.append({"kind": "ungrounded_value", "index": index, "value": value, "piece": piece})
        for word in dict.fromkeys(words(piece)):
            if _licensed(word, group):
                continue
            neighbours = groups[max(0, index - 1):index] + groups[index + 1:index + 2]
            kind = "neighbour_word" if any(_licensed(word, neighbour) for neighbour in neighbours) else "ungrounded_word"
            findings.append({"kind": kind, "index": index, "word": word, "piece": piece})
    return findings


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--groups", required=True)
    parser.add_argument("--targets", required=True)
    args = parser.parse_args(argv)
    group_path = guard.safe_input(args.groups, [])
    target_path = guard.safe_input(args.targets, [])
    groups = {r["id"]: r for r in map(json.loads, group_path.read_text().splitlines())}
    findings = []
    for target in map(json.loads, target_path.read_text().splitlines()):
        for finding in check(groups[target["id"]], target):
            findings.append({"id": target["id"], **finding})
    print(json.dumps({"passages": len({f['id'] for f in findings}), "findings": len(findings),
                      "by_kind": {kind: sum(f["kind"] == kind for f in findings)
                                  for kind in sorted({f["kind"] for f in findings})},
                      "examples": findings[:5]}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
