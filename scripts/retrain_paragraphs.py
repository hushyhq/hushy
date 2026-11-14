#!/usr/bin/env python3
"""Paragraph-step training rows from whole typed texts (Task 142). No model call.

For each passage's typed text (paragraphs separated by a blank line): the sentences numbered in one line, and the
numbers of the sentences that begin a paragraph. A passage also gives one shorter row, cut at a sentence end, so the
model sees texts of different lengths.

    python3 -I scripts/retrain_paragraphs.py --targets <batch>/targets_screened.jsonl --out <rows.jsonl>
"""

import argparse
import json
from pathlib import Path
import random
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
PROMPT = ROOT / "Evals/finetune-prompts/paragraph-call-system.txt"
sys.path.insert(0, str(ROOT / "scripts"))
sys.path.insert(0, str(ROOT / "scripts/finetune"))
from pathguard import violation  # noqa: E402
import retrain_groups  # noqa: E402

SENTENCE_END = re.compile(r"(?<=[.?!])[\"')\]”’]*\s+(?=[\"'(\[“‘]?[A-Z0-9$])")
MIN_SENTENCES = 3


def sentences(paragraph):
    return [s.strip() for s in SENTENCE_END.split(paragraph.strip()) if s.strip()]


def numbered(typed):
    """(sentences, numbers of the sentences that begin a paragraph after the first)."""
    all_sentences, starts = [], []
    for paragraph in [p for p in re.split(r"\n\s*\n", typed.strip()) if p.strip()]:
        if all_sentences:
            starts.append(len(all_sentences) + 1)
        all_sentences += sentences(" ".join(paragraph.split()))
    return all_sentences, starts


def user_turn(all_sentences):
    return "Text: " + " ".join(f"[{i}] {s}" for i, s in enumerate(all_sentences, 1)) + "\nOutput:"


def row(ident, passage, all_sentences, starts, system):
    answer = json.dumps({"paragraphs": starts}, separators=(",", ":"))
    return {"id": ident, "passage": passage, "arm": "paragraphs", "source": "paragraph_step",
            "messages": [{"role": "system", "content": system}, {"role": "user", "content": user_turn(all_sentences)},
                         {"role": "assistant", "content": answer}]}


def rows_for(target, system, rng):
    all_sentences, starts = numbered(target["typed"])
    if len(all_sentences) < MIN_SENTENCES:
        return []
    out = [row(f"{target['id']}-para", target["id"], all_sentences, starts, system)]
    if len(all_sentences) >= 2 * MIN_SENTENCES:
        cut = rng.randint(MIN_SENTENCES, len(all_sentences) - 2)
        out.append(row(f"{target['id']}-para-cut", target["id"], all_sentences[:cut], [n for n in starts if n <= cut], system))
    return out


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--targets", action="append", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--seed", type=int, default=11)
    args = parser.parse_args(argv)
    system = retrain_groups.prompt_sections(PROMPT)
    rng = random.Random(args.seed)
    rows = []
    for path in args.targets:
        if violation(Path(path)):
            raise SystemExit(f"refused path: {path}")
        with open(path, encoding="utf-8") as handle:
            for line in handle:
                if line.strip():
                    rows += rows_for(json.loads(line), system, rng)
    Path(args.out).parent.mkdir(parents=True, exist_ok=True)
    Path(args.out).write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in rows), encoding="utf-8")
    with_breaks = sum(bool(json.loads(r["messages"][2]["content"])["paragraphs"]) for r in rows)
    print(json.dumps({"rows": len(rows), "with_a_break": with_breaks,
                      "longest_chars": max(len(r["messages"][1]["content"]) for r in rows)}))


if __name__ == "__main__":
    main()
