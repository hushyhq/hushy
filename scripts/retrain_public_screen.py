#!/usr/bin/env python3
"""Screening of one added public source for `retrain_public_rows.py assemble`.

Checks that case and label rows are well formed, gives each case its hold-out group, and drops a
case whose label is missing, overlaps a benchmark, is empty, repeats the input or has an
implausible length. Every count is per case, so input = train + valid + rejected."""

from collections import Counter
import re

import retrain_public_index as index


# A decimal ("2.5"), a number with separators ("10,000") and a hyphenated word are one word each.
WORD = re.compile(r"\w+(?:[.,]\d+|['’\-]\w+)*")
LONG_INPUT_WORDS = 100
# Label words allowed per input word, as (numerator, denominator) so the edges are exact.
# Long stretches legitimately shrink more: disfluent speech is cleaned up heavily and spoken
# numbers become digits ("twenty five thousand" is three words, "25,000" is one).
SHORT_RATIO = ((1, 2), (8, 5))     # 0.5 to 1.6, inputs under LONG_INPUT_WORDS
LONG_RATIO = ((3, 10), (2, 1))     # 0.3 to 2.0, inputs of LONG_INPUT_WORDS or more


def word_count(text):
    return len(WORD.findall(text))


def label_reason(spoken, label):
    """Why a label is unusable for its spoken input, or None."""
    if not label.strip():
        return "empty"
    if label.strip().casefold() == spoken.strip().casefold():
        return "identical"
    count, labelled = word_count(spoken), word_count(label)
    (low_n, low_d), (high_n, high_d) = LONG_RATIO if count >= LONG_INPUT_WORDS else SHORT_RATIO
    if not count or labelled * low_d < count * low_n or labelled * high_d > count * high_n:
        return "word_ratio"
    return None


def _checked(name, kind, rows, field):
    """Rows of one file as {id: row}; a clear error for a row that is not {id, <field>: text}."""
    by_id = {}
    for number, row in enumerate(rows, 1):
        where = f"{name} {kind} row {number}"
        if not isinstance(row, dict):
            raise ValueError(f"{where} is not a JSON object")
        if not isinstance(row.get("id"), (str, int)) or isinstance(row.get("id"), bool) or row["id"] == "":
            raise ValueError(f"{where} needs an id (text or a whole number)")
        if not isinstance(row.get(field), str):
            raise ValueError(f"{where} (id {row['id']!r}) needs {field!r} as text")
        if row["id"] in by_id:
            raise ValueError(f"duplicate {kind[:-1]} id in {name}: {row['id']!r}")
        by_id[row["id"]] = row
    return by_id


def group_of(name, case, key, alone):
    """The hold-out group of a case: its `key` field. Never silently the case itself."""
    value = case.get(key)
    if isinstance(value, (str, int)) and not isinstance(value, bool) and str(value).strip():
        return str(value)
    if alone:
        return str(case["id"])  # a one-row source has nothing to keep together
    raise ValueError(f"{name}: case {case['id']!r} has no {key!r}, so it cannot be held out with the rest of its "
                     f"recording; give every case one or name another field with --group-key "
                     f"(--group-key id holds out single rows)")


def reject_reason(spoken, label, excluded):
    if label is None:
        return "missing_label"
    return index.overlap(excluded, spoken, label) or label_reason(spoken, label)


def screen(name, cases, labels, excluded, group_key):
    """One added source: kept (group, spoken, label) triples, every group, and the counts."""
    case_by_id = _checked(name, "cases", cases, "spoken")
    label_by_id = _checked(name, "labels", labels, "text")
    kept, groups, licences = [], set(), set()
    rejected = Counter({"benchmark_overlap": 0} if excluded.whole or excluded.shingles else {})
    if excluded.shingles:
        rejected["benchmark_shingle_overlap"] = 0
    for ident, case in case_by_id.items():
        group = group_of(name, case, group_key, alone=len(case_by_id) == 1)
        groups.add(group)  # every case counts, kept or not: filters must not move the held set
        label = label_by_id[ident]["text"] if ident in label_by_id else None
        reason = reject_reason(case["spoken"], label, excluded)
        if reason:
            rejected[reason] += 1
            continue
        licences.add(case.get("licence", "not checked"))
        kept.append((group, case["spoken"], label))
    return {"kept": kept, "groups": groups, "licences": licences, "rejected": rejected,
            "unmatched_labels": len(set(label_by_id) - set(case_by_id))}
