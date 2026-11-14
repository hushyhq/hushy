#!/usr/bin/env python3
"""Extract licensed long spoken inputs without writing corpus text into the repo.

    python3 -I scripts/retrain_longform.py stretches --source ami --input PATH --out PATH
    python3 -I scripts/retrain_longform.py split --input PATH --train PATH --held-back PATH

`stretches` cuts each speaker's unbroken speech into pieces of 100 to 300 words and writes one JSON
line per kept piece: id, source, licence, meeting, series, words, spoken. The text is shaped like a
recogniser's output; retrain_longform_sources.py documents the token rules (numbers stay as
written, "$" and "%" attached) and which annotation markers are dropped or reject a piece.

A piece is rejected when words are missing from it (`missing_words`), when it is mostly very short
clauses (`short_clauses`) or when it repeats text found in another file (`repeated_across_files`).
Number-heavy pieces are kept: an earlier filter on the share of digit tokens selected against the
numeric content this data is wanted for, and was removed.

`split` holds whole groups out of training: meetings by default, or `--group-key series` for runs
of meetings with the same speakers. The choice is a stable hash of (seed, source, group); a source
with two or more groups always holds at least one, and a source with one group is an error.

Every path read or written goes through the fine-tune path guard."""

import argparse
from collections import Counter, defaultdict
import hashlib
import json
from pathlib import Path
import random
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parent / "finetune"))
from pathguard import check  # noqa: E402
import retrain_holdout as holdout  # noqa: E402
from retrain_longform_sources import earnings_stream, meeting_stream, series_of  # noqa: E402


LICENCES = {"ami": "CC BY 4.0", "icsi": "CC BY 4.0",
            "earnings21": "CC BY-SA 4.0", "earnings22": "CC BY-SA 4.0"}
FILLERS = {"um", "uh", "erm", "er", "ah", "hmm", "mm"}
MIN_WORDS, TARGET_WORDS, MAX_WORDS = 100, 200, 300


def pieces(tokens):
    """Choose a natural cut near 200 words while leaving room for a final full piece."""
    offset = 0
    while len(tokens) - offset >= MIN_WORDS:
        left = len(tokens) - offset
        if left <= MAX_WORDS:
            yield tokens[offset:]
            return
        choices = range(offset + MIN_WORDS, min(offset + MAX_WORDS, len(tokens) - MIN_WORDS) + 1)
        cut = min(choices, key=lambda k: (0 if tokens[k - 1]["sentence"] or tokens[k]["pause"] >= 0.35 else 1,
                                          abs(k - offset - TARGET_WORDS), k))
        yield tokens[offset:cut]
        offset = cut


def shingles(tokens):
    return {tuple(tokens[i:i + 8]) for i in range(max(0, len(tokens) - 7))}


def filter_reason(piece, shared):
    """Why a piece is rejected, or None. Missing words come first: nothing else can repair them."""
    if any(item.get("missing") for item in piece):
        return "missing_words"
    clauses = []
    count = 0
    for item in piece:
        count += 1
        if item["sentence"]:
            clauses.append(count)
            count = 0
    if count:
        clauses.append(count)
    if len(clauses) >= 8 and sum(n <= 7 for n in clauses) / len(clauses) > 0.60:
        return "short_clauses"
    own = shingles([item["word"] for item in piece])
    if own and len(own & shared) / len(own) > 0.25:
        return "repeated_across_files"
    return None


def band(length):
    return "100-149" if length < 150 else "150-199" if length < 200 else "200-249" if length < 250 else "250-300"


def summary(rows):
    return dict(sorted(Counter(f"{row['source']}:{band(row['words'])}" for row in rows).items()))


def candidates(source, path):
    """Every full-length piece of every stretch, and the 8-word runs found in more than one file."""
    stream = meeting_stream(path) if source in {"ami", "icsi"} else earnings_stream(path)
    found = []
    seen = defaultdict(set)
    for stretch_index, (meeting, speaker, stretch) in enumerate(stream):
        for index, piece in enumerate(pieces(stretch)):
            if len(piece) < MIN_WORDS:
                continue
            found.append((meeting, speaker, stretch_index, index, piece))
            seen[meeting].update(shingles([item["word"] for item in piece]))
    counts = Counter(shingle for group in seen.values() for shingle in group)
    return found, {shingle for shingle, count in counts.items() if count > 1}


def screen(source, found, shared):
    """The pieces that pass the filters, as rows that still hold their token lists."""
    kept, rejected = [], Counter()
    for meeting, speaker, stretch_index, index, piece in found:
        reason = filter_reason(piece, shared)
        if reason:
            rejected[reason] += 1
            continue
        tokens = [item["word"] for item in piece]
        digest = hashlib.sha256((source + meeting + speaker + str(stretch_index) + str(index)
                                 + " ".join(tokens)).encode()).hexdigest()[:12]
        kept.append({"id": f"{source}-{digest}", "source": source, "licence": LICENCES[source], "meeting": meeting,
                     "series": series_of(source, meeting), "speaker": speaker, "words": len(tokens), "tokens": tokens})
    return kept, rejected


def select(filtered, rejected, rng, limit, meeting_cap, speaker_cap, filler_drop):
    """Applies the per-meeting and per-speaker caps in shuffled order and writes out the spoken text."""
    per_meeting, per_speaker = Counter(), Counter()
    selected = []
    for row in filtered:
        key = (row["meeting"], row["speaker"])
        if per_meeting[row["meeting"]] >= meeting_cap or per_speaker[key] >= speaker_cap:
            continue
        kept = [token for token in row["tokens"] if token not in FILLERS or rng.random() >= filler_drop]
        if len(kept) < MIN_WORDS:
            rejected["short_after_filler_drop"] += 1
            continue
        per_meeting[row["meeting"]] += 1
        per_speaker[key] += 1
        selected.append({**{name: row[name] for name in ("id", "source", "licence", "meeting", "series")},
                         "words": len(kept), "spoken": " ".join(kept)})
        if limit is not None and len(selected) >= limit:
            break
    return selected


def extract(source, path, seed=11, limit=None, meeting_cap=8, speaker_cap=4, filler_drop=0):
    found, shared = candidates(source, check(path))
    filtered, rejected = screen(source, found, shared)
    rng = random.Random(seed)
    rng.shuffle(filtered)
    selected = select(filtered, rejected, rng, limit, meeting_cap, speaker_cap, filler_drop)
    report = {"candidates": len(found), "rejected": dict(sorted(rejected.items())),
              "after_filter": summary(filtered), "after_caps": summary(selected)}
    return selected, report


def write_lines(path, rows):
    with check(path).open("w", encoding="utf-8") as handle:
        for row in rows:
            handle.write(json.dumps(row, ensure_ascii=False) + "\n")


def held_by_source(rows, seed, held_fraction, group_key):
    """{source: held groups}. Every row needs the group field; every source needs two groups."""
    groups = defaultdict(set)
    for number, row in enumerate(rows, 1):
        if not isinstance(row, dict) or not isinstance(row.get("source"), str):
            raise ValueError(f"row {number} is not a stretch (a JSON object with a source)")
        if not isinstance(row.get(group_key), str) or not row[group_key]:
            raise ValueError(f"row {number} ({row.get('id')!r}) has no {group_key!r}; extract it again with "
                             "`stretches`, or split by another --group-key")
        groups[row["source"]].add(row[group_key])
    for source, names in groups.items():
        if len(names) < 2:
            raise ValueError(f"cannot hold anything out of {source!r}: it has only one {group_key}, and a "
                             f"{group_key} is never split between training and held-back rows")
    return {source: holdout.held_groups(names, seed, source, held_fraction) for source, names in groups.items()}


def split(input_path, train_path, held_path, seed, held_fraction, group_key="meeting"):
    input_path, train_path, held_path = check(input_path), check(train_path), check(held_path)
    with input_path.open(encoding="utf-8") as handle:
        rows = [json.loads(line) for line in handle if line.strip()]
    if not rows:
        raise ValueError(f"{input_path} has no rows")
    held = held_by_source(rows, seed, held_fraction, group_key)
    is_held = [row[group_key] in held[row["source"]] for row in rows]
    train = [row for row, out in zip(rows, is_held) if not out]
    held_rows = [row for row, out in zip(rows, is_held) if out]
    write_lines(train_path, train)
    write_lines(held_path, held_rows)
    # "meetings" counts the groups of whichever --group-key was used; the name is kept for older readers.
    return {"train": summary(train), "held_back": summary(held_rows), "group_key": group_key,
            "meetings": len({(row["source"], row[group_key]) for row in rows}),
            "held_groups": {source: sorted(names) for source, names in sorted(held.items())}}


def parse(argv):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    stretches = commands.add_parser("stretches")
    stretches.add_argument("--source", choices=tuple(LICENCES), required=True)
    stretches.add_argument("--input", type=Path, required=True)
    stretches.add_argument("--out", type=Path, required=True)
    stretches.add_argument("--seed", type=int, default=11)
    stretches.add_argument("--limit", type=int)
    stretches.add_argument("--meeting-cap", type=int, default=8)
    stretches.add_argument("--speaker-cap", type=int, default=4)
    stretches.add_argument("--filler-drop", type=float, default=0)
    splitting = commands.add_parser("split")
    splitting.add_argument("--input", type=Path, required=True)
    splitting.add_argument("--train", type=Path, required=True)
    splitting.add_argument("--held-back", type=Path, required=True)
    splitting.add_argument("--seed", type=int, default=11)
    splitting.add_argument("--held-fraction", type=float, default=0.2)
    splitting.add_argument("--group-key", default="meeting",
                           help="the field whose rows stay together: meeting (default) or series")
    args = parser.parse_args(argv)
    if args.command == "stretches":
        if not 0 <= args.filler_drop <= 1 or args.limit is not None and args.limit < 1 \
                or args.meeting_cap < 1 or args.speaker_cap < 1:
            parser.error("rates must be between zero and one; caps and limit must be positive")
    elif not 0 < args.held_fraction < 1:
        parser.error("held fraction must be above zero and below one")
    return args


def run(args):
    if args.command == "split":
        return split(args.input, args.train, args.held_back, args.seed, args.held_fraction, args.group_key)
    out = check(args.out)  # refused before any corpus file is read
    if not check(args.input).is_dir():
        raise ValueError(f"--input {args.input} must be a folder")
    rows, report = extract(args.source, args.input, args.seed, args.limit, args.meeting_cap,
                           args.speaker_cap, args.filler_drop)
    write_lines(out, rows)
    return report


def main(argv=None):
    args = parse(argv)
    try:
        report = run(args)
    except (ValueError, OSError) as error:  # a refused path is a PermissionError
        sys.exit(f"error: {error}")
    print(json.dumps(report, sort_keys=True), file=sys.stderr)


if __name__ == "__main__":
    main()
