#!/usr/bin/env python3
"""Score public dictation outputs against independent references.

    python3 -I scripts/retrain_public_eval.py score --outputs PATH --references PATH --verdicts PATH

Outputs are JSON lines of {id, text}; references are {id, reference, spoken?}. Per row:

- exact: output and reference are the same words once both are normalised (see
  retrain_public_normalise.py: number words and digit forms meet in one canonical stream);
- word_similarity: one minus the word edit distance over the longer side, a number counting as
  one word;
- retracted_wording_present: the retracted wording is what the speaker said that the reference
  does not keep, counted word by word and leaving out function words, hesitations, openers and
  the correction cue words themselves. True when at least half of it is in the output beyond
  what the reference has. It needs `spoken`, and it cannot tell a retraction from any other word
  the reference rewrote, so read it as a count to inspect rather than a verdict;
- spoken_opener_kept: the spoken input starts with a run of opener words ("um okay so"), and the
  output still starts with one of them while the reference does not start with that word.

SCORER_VERSION is printed, returned and written on every verdict row. Version 1 (unstamped) added
separate numbers together and used an output-length test for retractions: never mix its scores
with these."""

import argparse
from collections import Counter
from itertools import takewhile
import json
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parent / "finetune"))
from pathguard import check  # noqa: E402
from retrain_lexicon import CLOSED_CLASS, HESITATIONS  # noqa: E402
from retrain_public_normalise import lexical, normalize, similarity_words  # noqa: E402,F401


SCORER_VERSION = 2
OPENERS = frozenset("okay well so right alright".split())  # "ok" is normalised to "okay"
CUES = frozenset("sorry rather instead actually no correction wait mean scratch oops".split())
NOT_RETRACTABLE = CLOSED_CLASS | HESITATIONS | OPENERS | CUES
RETRACTED_SHARE = .5


def read_rows(path, field):
    """{id: row} from JSON lines, each row an object with an id and `field` as text."""
    path = check(path)
    rows = {}
    with path.open(encoding="utf-8") as handle:
        for number, line in enumerate((line for line in handle if line.strip()), 1):
            row = json.loads(line)
            if not isinstance(row, dict) or "id" not in row:
                raise ValueError(f"{path} row {number} needs an id")
            if not isinstance(row.get(field), str):
                raise ValueError(f"{path} row {number} (id {row['id']!r}) needs {field!r} as text")
            if row["id"] in rows:
                raise ValueError(f"duplicate id in {path}: {row['id']!r}")
            rows[row["id"]] = row
    return rows


def word_similarity(expected, actual):
    """One minus word edit distance divided by the longer word sequence."""
    if not expected and not actual:
        return 1.0
    previous = list(range(len(actual) + 1))
    for i, word in enumerate(expected, 1):
        current = [i]
        for j, other in enumerate(actual, 1):
            current.append(min(current[-1] + 1, previous[j] + 1,
                               previous[j - 1] + (word != other)))
        previous = current
    return 1 - previous[-1] / max(len(expected), len(actual))


def retracted_wording_present(spoken, reference, output):
    """True when the output still holds at least RETRACTED_SHARE of what the speaker took back."""
    said, expected, actual = (Counter(similarity_words(text)) for text in (spoken, reference, output))
    retracted = Counter({word: count for word, count in (said - expected).items() if word not in NOT_RETRACTABLE})
    if not retracted:
        return False
    left_in = retracted & (actual - expected)
    return sum(left_in.values()) / sum(retracted.values()) >= RETRACTED_SHARE


def spoken_opener_kept(spoken, reference, output):
    """True when the output starts with an opener the speaker started with and the reference dropped."""
    said, expected, actual = (normalize(text) for text in (spoken, reference, output))
    run = set(takewhile(lambda word: word in OPENERS or word in HESITATIONS, said))
    return bool(actual) and actual[0] in run and expected[:1] != actual[:1]


def verdict(ident, reference, output):
    spoken = reference.get("spoken") if isinstance(reference.get("spoken"), str) else ""
    expected, actual = similarity_words(reference["reference"]), similarity_words(output)
    return {"id": ident, "exact": actual == expected,
            "word_similarity": round(word_similarity(expected, actual), 4),
            "retracted_wording_present": retracted_wording_present(spoken, reference["reference"], output),
            "spoken_opener_kept": spoken_opener_kept(spoken, reference["reference"], output),
            "scorer_version": SCORER_VERSION}


def score(outputs_path, references_path, verdicts_path):
    verdicts_path = check(verdicts_path)
    outputs = read_rows(outputs_path, "text")
    references = read_rows(references_path, "reference")
    if outputs.keys() != references.keys():
        raise ValueError("output and reference IDs must match")
    verdicts = [verdict(ident, reference, outputs[ident]["text"]) for ident, reference in references.items()]
    verdicts_path.write_text("".join(json.dumps(row) + "\n" for row in verdicts), encoding="utf-8")
    count = Counter()
    for row in verdicts:
        count.update({key: int(row[key]) for key in ("exact", "retracted_wording_present", "spoken_opener_kept")})
    similarity = sum(row["word_similarity"] for row in verdicts) / len(verdicts) if verdicts else 0
    return {"rows": len(verdicts), "exact": count["exact"], "mean_word_similarity": round(similarity, 4),
            "retracted_wording_present": count["retracted_wording_present"],
            "spoken_opener_kept": count["spoken_opener_kept"], "scorer_version": SCORER_VERSION}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("command", choices=["score"])
    parser.add_argument("--outputs", type=Path, required=True)
    parser.add_argument("--references", type=Path, required=True)
    parser.add_argument("--verdicts", type=Path, required=True)
    args = parser.parse_args(argv)
    try:
        metrics = score(args.outputs, args.references, args.verdicts)
    except (ValueError, OSError) as error:
        sys.exit(f"error: {error}")
    print("Metric                         Value")
    print("-----------------------------  -----")
    for key, value in metrics.items():
        print(f"{key:29}  {value}")


if __name__ == "__main__":
    main()
