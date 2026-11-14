#!/usr/bin/env python3
"""Count lowercase word forms in C4 shards (ODC-By 1.0) for the Hushy word-frequency table.

    python3 -I scripts/wordfreq/count_words.py OUT.json SHARD.json.gz [SHARD.json.gz ...]

Reads each shard line by line (one JSON document per line, field "text"), counts three things over whitespace-free
word tokens made only of letters and inner apostrophes, skipping anything that touches a digit, slash, at-sign, hyphen,
underscore or a dot followed by a letter (URLs, e-mail addresses, file names, hyphenated words):
  lower  every time the form appears entirely in lowercase
  mid    every time it appears capitalized (Abc) right after a lowercase word, so not at the start of a sentence
  total  every word token of any case (the denominator for the frequency)
Only the counts are kept. Documents are not stored. Run it on its own: it takes a few minutes per shard.
"""
import gzip, json, re, sys
from collections import Counter

WORD = re.compile(r"(?<![\w@/.\-:])([A-Za-z]+(?:['’][A-Za-z]+)?)(?![\w@/\-]|\.[A-Za-z])")
MID = re.compile(r"(?<=[a-z,;] )([A-Z][a-z]+(?:'[a-z]+)?)(?![\w@/\-]|\.[A-Za-z])")


def main(out_path, shards):
    lower, mid = Counter(), Counter()
    total = 0
    docs = 0
    for shard in shards:
        with gzip.open(shard, "rt", encoding="utf-8") as handle:
            for line in handle:
                text = json.loads(line)["text"].replace("’", "'")
                words = WORD.findall(text)
                total += len(words)
                lower.update(w for w in words if w.islower())
                mid.update(w.lower() for w in MID.findall(text))
                docs += 1
    with open(out_path, "w", encoding="utf-8") as out:
        json.dump({"documents": docs, "total": total, "lower": lower, "mid": mid}, out)
    print(f"{docs} documents, {total} word tokens, {len(lower)} lowercase forms", file=sys.stderr)


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2:])
