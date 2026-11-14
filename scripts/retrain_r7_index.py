#!/usr/bin/env python3
"""Round 7 benchmark overlap index: SHA-256 hashes of every evaluation text, never the text itself.

    retrain_r7_index.py --public300 handy-eval300.jsonl --probe Evals/misheard-probe.jsonl --probe ... \\
        --disfl-qa <file whose path names Disfl-QA> --out index.json

Writes the 8-word shingle form that `retrain_public_rows.py assemble --exclude-index` reads, so a row that
shares a whole text or any 8-word run with one of these is dropped from the added source.
`retrain_public_index.py benchmark-index` opens only paths that name Disfl-QA; round 7 also needs the public
300 and the frozen probes in the same index, so this script reads those with the same normalise and hash
functions and keeps the guarded door (`read_benchmark`) for the Disfl-QA file. It prints counts only."""
import argparse
import json
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parent / "finetune"))
import retrain_public_index as index  # noqa: E402
from pathguard import check  # noqa: E402


def read_texts(path):
    """Indexable strings of a JSONL file we may read directly (the public 300 and our own probes)."""
    rows = [json.loads(line) for line in Path(check(path)).read_text(encoding="utf-8").splitlines() if line.strip()]
    return [text for text in index.benchmark_strings(rows) if index.normalise(text)]


def build(public300, probes, disfl_qa, out):
    whole, shingles, counts = set(), set(), {}
    sources = [(str(path), read_texts(path)) for path in [*public300, *probes]]
    sources += [(str(path), index.read_benchmark(path)) for path in disfl_qa]
    for name, texts in sources:
        if not texts:
            raise ValueError(f"no indexable text in {name}")
        counts[Path(name).name] = len(texts)
        whole.update(index.text_hash(text) for text in texts)
        for text in texts:
            shingles.update(index.shingle_hashes(text))
    payload = {"whole": sorted(whole), "shingles": sorted(shingles), "shingle_words": index.SHINGLE_WORDS}
    Path(check(out)).write_text(json.dumps(payload, indent=0) + "\n", encoding="utf-8")
    return {"index": str(out), "strings": counts, "hashes": len(whole), "shingles": len(shingles)}


def main(argv=None):
    cli = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    cli.add_argument("--public300", action="append", type=Path, default=[])
    cli.add_argument("--probe", action="append", type=Path, default=[])
    cli.add_argument("--disfl-qa", action="append", type=Path, default=[])
    cli.add_argument("--out", type=Path, required=True)
    args = cli.parse_args(argv)
    try:
        print(json.dumps(build(args.public300, args.probe, args.disfl_qa, args.out), sort_keys=True))
    except (ValueError, OSError) as error:
        sys.exit(f"error: {error}")


if __name__ == "__main__":
    main()
