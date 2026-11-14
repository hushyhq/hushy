#!/usr/bin/env python3
"""Score invented person-memory JSONL runs; never reads user history."""
import argparse
import json
import re
import statistics
from pathlib import Path


def words(text):
    return re.findall(r"[\w']+", text.casefold())


def copied(text, row):
    new = words(row["spoken"])
    history = row["history"]
    sources = [history["style"], *history["terms"], *history["earlier"]]
    sources += [part for edit in history["edits"] for part in edit.values()]
    source_runs = set()
    for source in sources:
        tokens = words(source)
        source_runs.update(tuple(tokens[i:i + 4]) for i in range(len(tokens) - 3))
    source_runs -= {tuple(new[i:i + 4]) for i in range(len(new) - 3)}
    output = words(text)
    return any(tuple(output[i:i + 4]) in source_runs for i in range(len(output) - 3))


def percentile(values, p):
    ordered = sorted(values)
    if not ordered:
        return None
    return ordered[min(len(ordered) - 1, round((len(ordered) - 1) * p))]


def load(path):
    return {r["id"]: r for line in path.read_text().splitlines()
            if (r := json.loads(line)).get("id")}


def score(cases, outputs):
    ids = [row["id"] for row in cases]
    if set(outputs) != set(ids):
        raise ValueError(f"expected {len(ids)} cases; got {len(outputs)} with matching IDs={len(set(outputs) & set(ids))}")
    key = exact = raw_copy = final_copy = used = 0
    for row in cases:
        got = outputs[row["id"]]
        text = got["text"]
        key += all(k.casefold() in text.casefold() for k in row["keyItems"])
        exact += text == row["expected"]
        final_copy += copied(text, row)
        raw_copy += any(copied(answer, row) for answer in got["modelAnswers"])
        used += bool(got["usedModel"])
    return {"key": key, "exact": exact, "rawCopy": raw_copy, "finalCopy": final_copy,
            "used": used, "medianMs": percentile([outputs[i]["totalMs"] for i in ids], .5),
            "p90Ms": percentile([outputs[i]["totalMs"] for i in ids], .9)}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--cases", type=Path, default=Path("Evals/person-memory.jsonl"))
    parser.add_argument("--runs", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    cases = list(load(args.cases).values())
    result = {}
    for model in ("intent", "v54"):
        arms = {arm: load(args.runs / f"{model}-{arm}.jsonl") for arm in "ABCDE"}
        base = arms["A"]
        result[model] = {}
        for arm, output in arms.items():
            stats = score(cases, output)
            controls = [r for r in cases if r["control"]]
            stats["harmedControls"] = sum(
                all(k.casefold() in base[r["id"]]["text"].casefold() for k in r["keyItems"])
                and not all(k.casefold() in output[r["id"]]["text"].casefold() for k in r["keyItems"])
                for r in controls)
            stats["addedPromptTokensMedian"] = percentile([
                (output[r["id"]]["promptTokens"] or 0) - (base[r["id"]]["promptTokens"] or 0)
                for r in cases], .5)
            paired = [output[r["id"]]["totalMs"] - base[r["id"]]["totalMs"] for r in cases]
            stats["addedWaitMedianMs"] = percentile(paired, .5)
            stats["addedWaitP90Ms"] = percentile(paired, .9)
            result[model][arm] = stats
    args.out.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
