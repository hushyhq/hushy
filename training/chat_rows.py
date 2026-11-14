#!/usr/bin/env python3
"""Turn rows of spoken text and typed targets into the train and validation files the trainer reads.

    python3 training/chat_rows.py IN.jsonl OUT_DIR [--valid-fraction 0.1] [--group-key meeting] [--seed 7]
    python3 training/chat_rows.py --write-prompt-file PROMPT.txt

IN is JSON lines with a `spoken` and a `typed` field on every row, for example the licence-filtered
`*.accepted.jsonl` file that scripts/retrain_writer.py writes. Each row becomes
{"messages": [system, user, assistant]}, the same shape the app sends at run time:

- system: the app's own cleanup prompt (`IntentCleanupPrompt.system`), read from the Swift source,
  so the training prompt and the app's prompt cannot drift apart;
- user: "Transcript: <spoken>\\nOutput:";
- assistant: {"text": "<typed>"}.

OUT_DIR gets train.jsonl and valid.jsonl. Rows that share a `--group-key` value (a meeting, say, read
from the row or from its `meta`) land on the same side, so no recording is in both files. The groups
held out for validation are the first ones in a stable hash order of (seed, group). A row without the
group key is its own group. A row without both text fields stops the run with its line number.
Nothing is dropped silently.

`--write-prompt-file` writes the app's cleanup prompt in the layout `murmur-eval intent-run --system`
reads, so an evaluation uses exactly the prompt the rows were trained with.
"""

import argparse
import hashlib
import json
import math
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PROMPT_SOURCE = ROOT / "Sources/MurmurCore/Cleanup/IntentCleanupPrompt.swift"
OPEN, CLOSE = 'public static let system = #"""\n', '\n"""#'


def app_prompt(source: Path = PROMPT_SOURCE) -> str:
    """The text of `IntentCleanupPrompt.system`, exactly as the app compiles it."""
    text = source.read_text(encoding="utf-8")
    start = text.find(OPEN)
    end = text.find(CLOSE, start + len(OPEN))
    if start < 0 or end < 0:
        raise ValueError(f"{source}: could not find IntentCleanupPrompt.system")
    return text[start + len(OPEN):end]


def chat_row(system: str, spoken: str, typed: str) -> dict:
    answer = json.dumps({"text": typed}, ensure_ascii=False, separators=(",", ":"))
    return {"messages": [{"role": "system", "content": system},
                         {"role": "user", "content": f"Transcript: {spoken}\nOutput:"},
                         {"role": "assistant", "content": answer}]}


def group_of(row: dict, key: str, number: int) -> str:
    meta = row.get("meta") if isinstance(row.get("meta"), dict) else {}
    value = row.get(key, meta.get(key))
    return str(value) if value not in (None, "") else f"line-{number}"


def convert(lines, system: str, key: str = "meeting") -> list[tuple[str, dict]]:
    """(group, chat row) for every input line."""
    rows = []
    for number, line in enumerate(lines, 1):
        if not line.strip():
            continue
        row = json.loads(line)
        spoken, typed = row.get("spoken"), row.get("typed")
        if not isinstance(spoken, str) or not isinstance(typed, str) or not spoken.strip() or not typed.strip():
            raise ValueError(f"line {number}: needs non-empty `spoken` and `typed` text")
        rows.append((group_of(row, key, number), chat_row(system, spoken, typed)))
    return rows


def split(rows: list[tuple[str, dict]], fraction: float, seed: int) -> tuple[list[dict], list[dict]]:
    """(train, valid). Whole groups are held out; at least one when there are two or more."""
    groups = sorted({group for group, _ in rows})
    if len(groups) < 2:
        raise ValueError("need rows from at least two groups to hold one out for validation")
    order = sorted(groups, key=lambda g: hashlib.sha256(f"{seed}:{g}".encode()).hexdigest())
    held = set(order[:max(1, math.ceil(len(groups) * fraction))])
    return ([row for group, row in rows if group not in held],
            [row for group, row in rows if group in held])


def write(path: Path, rows: list[dict]) -> None:
    path.write_text("".join(json.dumps(row, ensure_ascii=False) + "\n" for row in rows), encoding="utf-8")


def main(argv: list[str]) -> None:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("input", type=Path, nargs="?")
    parser.add_argument("out_dir", type=Path, nargs="?")
    parser.add_argument("--write-prompt-file", type=Path)
    parser.add_argument("--valid-fraction", type=float, default=0.1)
    parser.add_argument("--group-key", default="meeting")
    parser.add_argument("--seed", type=int, default=7)
    args = parser.parse_args(argv)
    if args.write_prompt_file:
        args.write_prompt_file.parent.mkdir(parents=True, exist_ok=True)
        args.write_prompt_file.write_text(f"--- system turn ---\n{app_prompt()}\n", encoding="utf-8")
        print(f"prompt -> {args.write_prompt_file}")
        return
    if args.input is None or args.out_dir is None:
        parser.error("give IN.jsonl and OUT_DIR, or --write-prompt-file")
    if not 0 < args.valid_fraction < 1:
        sys.exit("error: --valid-fraction must be between 0 and 1")
    try:
        with args.input.open(encoding="utf-8") as handle:
            rows = convert(handle, app_prompt(), args.group_key)
        train, valid = split(rows, args.valid_fraction, args.seed)
    except (OSError, ValueError) as error:
        sys.exit(f"error: {error}")
    args.out_dir.mkdir(parents=True, exist_ok=True)
    write(args.out_dir / "train.jsonl", train)
    write(args.out_dir / "valid.jsonl", valid)
    print(f"{len(train)} train rows, {len(valid)} valid rows -> {args.out_dir}")


if __name__ == "__main__":
    main(sys.argv[1:])
