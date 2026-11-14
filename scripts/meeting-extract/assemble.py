#!/usr/bin/env python3
"""Sorts the staged rows into the files training and labelling read, checks the eval guards, and writes
the committed manifest and stats.

Outputs under DATA_ROOT/final:
  gold-human.jsonl       AMI + ICSI rows with records from the corpora's own linked annotation (train/val)
  gold-heuristic.jsonl   ELITR + QMSum rows whose records come from minutes or query answers, kind guessed
  input-only.jsonl       rows with no gold; tomorrow's Codex labelling reads these
  held-r10d-overlap.jsonl  every source's rows whose text overlaps the r10d cleanup training data
Committed under Evals/meeting-extract: manifest.json, STATS.md.
"""
import hashlib
import json
import random
import re
import statistics
import sys
from collections import Counter, defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from build_nxt import SCORECARD_SETS, scorecard_ids, series_of
from common import DATA_ROOT, validate_row, write_jsonl

HELD = "held-r10d-overlap"
SOURCES = ["ami", "icsi", "elitr", "qmsum-committee", "meetingbank", "notsofar"]
FORBIDDEN = re.compile(r"heldout|sealed|voicelab|meeting-heldout|/ab-|set-c", re.I)
REPO_OUT = Path(__file__).resolve().parents[2] / "Evals/meeting-extract"


def load(source: str, held: bool) -> list:
    path = DATA_ROOT / "stage" / f"{source}{'-r10d-overlap' if held else ''}.jsonl"
    return [json.loads(line) for line in open(path)] if path.exists() else []


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def check_guards(rows: list) -> None:
    scorecard = scorecard_ids()
    series = {series_of(m) for m in scorecard}
    for r in rows:
        if r["source"] == "ami":
            assert r["meeting_id"] not in scorecard, r["id"]
            assert series_of(r["meeting_id"]) not in series, r["id"]
        assert not FORBIDDEN.search(json.dumps(r["notes"])), r["id"]
        if r["split"] != HELD:
            hits, grams = r["notes"]["train_overlap_10grams"]
            assert r["source"] in ("ami", "icsi") or not grams or hits / grams <= 0.02, r["id"]


def quantiles(values: list) -> dict:
    values = sorted(values)
    pick = lambda q: values[min(len(values) - 1, int(q * len(values)))]
    return {"min": values[0], "p25": pick(0.25), "median": pick(0.5), "p75": pick(0.75), "max": values[-1]}


def main():
    final = DATA_ROOT / "final"
    clean = [r for s in SOURCES for r in load(s, False)]
    held = [r for s in SOURCES for r in load(s, True)]
    check_guards(clean + held)
    ids = [r["id"] for r in clean + held]
    assert len(ids) == len(set(ids)), "duplicate row ids"
    broken = {r["id"]: validate_row(r) for r in clean + held if validate_row(r)}
    assert not broken, broken
    files = {
        "gold-human.jsonl": [r for r in clean if r["gold"] == "human-linked"],
        "gold-heuristic.jsonl": [r for r in clean if r["gold"].startswith("heuristic")],
        "input-only.jsonl": [r for r in clean if r["gold"] == "none"],
        "held-r10d-overlap.jsonl": held,
    }
    for name, rows in files.items():
        write_jsonl(final / name, rows)
    all_rows = clean + held
    manifest = {"files": {}, "by_source": {}, "exclusions": {}}
    for name, rows in files.items():
        manifest["files"][name] = {"rows": len(rows), "sha256": sha(final / name),
                                   "bytes": (final / name).stat().st_size}
    for s in SOURCES:
        rows = [r for r in all_rows if r["source"] == s]
        if not rows:
            continue
        recs = Counter(rec["kind"] for r in rows if r["output"] for rec in r["output"])
        manifest["by_source"][s] = {
            "licence": rows[0]["licence"], "commercial_safe": rows[0]["commercial_safe"],
            "meetings": len({r["meeting_id"] for r in rows}), "chunks": len(rows),
            "chunks_by_split": dict(Counter(r["split"] for r in rows)),
            "chunks_by_gold": dict(Counter(r["gold"] for r in rows)),
            "chunks_with_records": sum(1 for r in rows if r["output"]),
            "weak_alignments": sum(1 for r in rows if r["output"] for a in r["notes"].get("alignments", []) if a.get("weak")),
            "records_by_kind": dict(recs),
            "words": quantiles([r["stats"]["words"] for r in rows]),
            "total_words": sum(r["stats"]["words"] for r in rows),
        }
    for s in ("ami", "icsi"):
        path = DATA_ROOT / "stage" / f"exclusions-{s}.tsv"
        manifest["exclusions"][s] = [line.split("\t") for line in path.read_text().splitlines()[1:]]
    REPO_OUT.mkdir(parents=True, exist_ok=True)
    (REPO_OUT / "manifest.json").write_text(json.dumps(manifest, indent=1))
    write_stats(manifest)
    # twenty random human-linked rows' records for the manual alignment check
    rng = random.Random(20261106)
    pool = [(r, rec, a) for r in files["gold-human.jsonl"] for rec, a in zip(r["output"], r["notes"]["alignments"])]
    sample = rng.sample(pool, min(20, len(pool)))
    audit = [{"id": r["id"], "turn": a["turn"], "record": rec,
              "turn_text": r["input"]["transcript"].split("\n")[a["turn"]]} for r, rec, a in sample]
    (DATA_ROOT / "final" / "audit-sample.json").write_text(json.dumps(audit, indent=1, ensure_ascii=False))
    print(json.dumps({k: v["rows"] for k, v in manifest["files"].items()}))


def write_stats(manifest: dict) -> None:
    lines = ["# Meeting-extract data stats", "", "Generated by scripts/meeting-extract/assemble.py. Counts include the "
             "held-r10d-overlap tier.", "",
             "| source | licence | commercial-safe | meetings | chunks | gold (chunks) | chunks with records | records by kind (weak quote links) | words/chunk (min, median, max) |",
             "|---|---|---|---|---|---|---|---|---|"]
    for s, m in manifest["by_source"].items():
        gold = ", ".join(f"{k} {v}" for k, v in m["chunks_by_gold"].items())
        kinds = ", ".join(f"{k} {v}" for k, v in m["records_by_kind"].items()) or "none"
        w = m["words"]
        lines.append(f"| {s} | {m['licence']} | {'yes' if m['commercial_safe'] else 'no'} | {m['meetings']} | {m['chunks']} | "
                     f"{gold} | {m['chunks_with_records']} | {kinds} ({m['weak_alignments']}) | {w['min']}, {w['median']}, {w['max']} |")
    lines += ["", "| source | train | val | held-r10d-overlap |", "|---|---|---|---|"]
    for s, m in manifest["by_source"].items():
        sp = m["chunks_by_split"]
        lines.append(f"| {s} | {sp.get('train', 0)} | {sp.get('val', 0)} | {sp.get(HELD, 0)} |")
    (REPO_OUT / "STATS.md").write_text("\n".join(lines) + "\n")


if __name__ == "__main__":
    main()
