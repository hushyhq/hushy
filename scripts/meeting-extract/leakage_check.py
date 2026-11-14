"""Leakage checks for the meeting-extract SFT set. Mandatory before any training run; exits 1 on any hit.

    $PY scripts/meeting-extract/leakage_check.py [--report sft/leakage-report.json]

What it compares (the SFT transcripts are read back from sft/*.jsonl, so the check covers the real training text):
  1. AMI scorecard sets ami-dev, ami-test, ami-long (meet-model worktree, feat/meetings-own-model): meeting ids,
     design-team series, and shared 10-grams of the transcripts.
  2. Meeting-memory sets dev, dev2, set-b, set-c (meet-memory worktree, feat/meeting-memory-v1): meeting ids and shared
     10-grams of turn text. Only meetings[].id and meetings[].turns[].text are read from any of them; set-c's cases
     (questions, answers) are never loaded into a variable, printed or compared.
  3. The dev meeting golden Evals/meeting-eval/golden.json (12 meetings) and the ICSI long-eval groups: 10-grams, ids.
  4. Train against valid inside the SFT set: team keys and meeting ids disjoint.
  5. Sealed sets: Evals/sealed-sets.json is read for file names only. Sealed content is never opened, so no overlap
     test is possible; the guard is the source whitelist and the forbidden-string scan of every row's notes.
A 10-gram is 10 consecutive tokens of lowercase [a-z0-9'] words, the same rule as the r10d contamination test.
"""
import argparse
import json
import os
import sys
from collections import Counter, defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from common import DATA_ROOT, NGRAM, REPO_ROOT, normalized  # noqa: E402

SFT = DATA_ROOT / "sft"
ROOT = REPO_ROOT
# Checkouts that hold the scorecard sets and the meeting-memory sets (default: this one).
MODEL_WT = Path(os.environ.get("HUSHY_MEETING_MODEL_ROOT", ROOT))
MEMORY_WT = Path(os.environ.get("HUSHY_MEETING_MEMORY_ROOT", ROOT))
SCORECARD_SETS = ["ami-dev", "ami-test", "ami-long"]
MEMORY_SETS = ["dev", "dev2", "set-b", "set-c"]
SFT_FILES = ["train.jsonl", "valid.jsonl", "train-commercial.jsonl", "valid-commercial.jsonl"]
SOURCES = {"ami", "icsi", "elitr", "qmsum-committee", "notsofar", "meetingbank"}
FORBIDDEN = ("heldout", "held-out", "sealed", "voicelab", "voice-lab", "application support/hushy", "/ab-", "set-c")
SHARE_LIMIT = 0.02   # a row whose transcript shares more than this fraction of its 10-grams with an eval set is a leak
TRANSCRIPT_START, TRANSCRIPT_END = "Transcript:\n", "\n\nExtract the records."


def grams(text: str) -> set:
    tokens = normalized(text)
    return {hash(tuple(tokens[i:i + NGRAM])) for i in range(len(tokens) - NGRAM + 1)}


def transcript_of(row: dict) -> str:
    user = row["messages"][1]["content"]
    return user[user.index(TRANSCRIPT_START) + len(TRANSCRIPT_START):user.rindex(TRANSCRIPT_END)]


def read_jsonl(path: Path) -> list:
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]


def eval_sets() -> dict:
    """name -> {"ids": set, "series": set, "grams": set}. Memory sets contribute ids and turn text only."""
    out = {}
    for name in SCORECARD_SETS:
        meetings = json.loads((MODEL_WT / ".build/meetings-hillclimb/sets" / f"{name}.json").read_text())["meetings"]
        ids = {m["id"] for m in meetings}
        out[name] = {"ids": ids, "series": {i[:6] for i in ids}, "grams": set().union(*(grams(m["transcript"]) for m in meetings))}
    for name in MEMORY_SETS:
        meetings = json.loads((MEMORY_WT / "Evals/meeting-memory" / f"{name}.json").read_text())["meetings"]
        out[f"memory:{name}"] = {"ids": {m["id"] for m in meetings}, "series": set(),
                                 "grams": set().union(*(grams(t["text"]) for m in meetings for t in m["turns"]))}
    golden = json.loads((MODEL_WT / "Evals/meeting-eval/golden.json").read_text())["meetings"]
    out["dev-golden"] = {"ids": {m["id"] for m in golden}, "series": set(), "grams": set().union(*(grams(m["transcript"]) for m in golden))}
    icsi = set(json.loads((ROOT / "Evals/public-long-eval-groups-icsi.json").read_text()))
    out["icsi-long-eval"] = {"ids": icsi, "series": set(), "grams": set()}
    return out


def sealed_names() -> list:
    return [s["file"] for s in json.loads((ROOT / "Evals/sealed-sets.json").read_text())["sets"]]


def check_rows(rows: list, meta: dict, sets: dict) -> dict:
    """Per eval set: ids shared, series shared, rows over the 10-gram share limit, rows with any shared 10-gram."""
    result = {}
    row_grams = {r["id"]: grams(transcript_of(r)) for r in rows}
    for name, s in sets.items():
        ids = sorted({meta[r["id"]]["meeting_id"] for r in rows} & s["ids"])
        series = sorted({meta[r["id"]]["meeting_id"][:6] for r in rows if meta[r["id"]]["source"] == "ami"} & s["series"])
        any_hit, over, worst = [], [], 0.0
        for r in rows:
            g = row_grams[r["id"]]
            shared = len(g & s["grams"]) if g and s["grams"] else 0
            share = shared / len(g) if g else 0.0
            worst = max(worst, share)
            if shared:
                any_hit.append(r["id"])
            if share > SHARE_LIMIT:
                over.append(r["id"])
        result[name] = {"shared_meeting_ids": ids, "shared_series": series, "rows_with_any_shared_10gram": len(any_hit),
                        "rows_over_limit": len(over), "over_limit_ids": over[:20], "worst_share": round(worst, 4)}
    return result


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--report", type=Path, default=SFT / "leakage-report.json")
    args = ap.parse_args()
    meta = {m["id"]: m for m in read_jsonl(SFT / "meta.jsonl")}
    sets = eval_sets()
    report, bad = {"limit": SHARE_LIMIT, "sealed_sets_not_opened": sealed_names(), "files": {}}, 0
    for name in SFT_FILES:
        rows = read_jsonl(SFT / name)
        res = check_rows(rows, meta, sets)
        report["files"][name] = {"rows": len(rows), "by_eval_set": res}
        bad += sum(len(v["shared_meeting_ids"]) + len(v["shared_series"]) + v["rows_over_limit"] for v in res.values())
    train, valid = read_jsonl(SFT / "train.jsonl"), read_jsonl(SFT / "valid.jsonl")
    train_teams = {meta[r["id"]]["team"] for r in train}
    valid_teams = {meta[r["id"]]["team"] for r in valid}
    train_meetings = {meta[r["id"]]["meeting_id"] for r in train}
    valid_meetings = {meta[r["id"]]["meeting_id"] for r in valid}
    split = {"shared_teams": sorted(train_teams & valid_teams), "shared_meetings": sorted(train_meetings & valid_meetings),
             "train_teams": len(train_teams), "valid_teams": len(valid_teams),
             "train_meetings": len(train_meetings), "valid_meetings": len(valid_meetings)}
    report["train_vs_valid"] = split
    bad += len(split["shared_teams"]) + len(split["shared_meetings"])
    sources = Counter(m["source"] for m in meta.values())
    report["sources"] = dict(sources)
    bad += sum(1 for s in sources if s not in SOURCES)
    report["rows_total"] = len(meta)
    args.report.write_text(json.dumps(report, indent=1) + "\n")
    print(f"rows {len(meta)}; sources {dict(sources)}")
    for name in SFT_FILES:
        print(f"-- {name} ({report['files'][name]['rows']} rows)")
        for s, v in report["files"][name]["by_eval_set"].items():
            print(f"   {s:16s} ids {len(v['shared_meeting_ids'])}  series {len(v['shared_series'])}  any-10gram rows {v['rows_with_any_shared_10gram']:3d}"
                  f"  over {SHARE_LIMIT:.0%} rows {v['rows_over_limit']}  worst share {v['worst_share']:.4f}")
    print(f"train vs valid: shared teams {len(split['shared_teams'])}, shared meetings {len(split['shared_meetings'])} "
          f"({split['train_meetings']} train meetings, {split['valid_meetings']} valid meetings)")
    print(f"sealed sets not opened: {report['sealed_sets_not_opened']}")
    print("FAIL" if bad else "PASS", f"({bad} hits)")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
