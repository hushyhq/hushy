#!/usr/bin/env python3
"""Builds extract-adapter rows from AMI (gold: decisions, actions) and ICSI (gold: decisions).

Gold comes from the corpora's own annotation: an annotator wrote an abstractive sentence (a decision
or an action) and linked it to the dialogue acts that support it. The record text is that sentence;
the quote is the text of one linked dialogue act, found verbatim in the chunk.

    build_nxt.py ami|icsi [--out DIR]

Needs the training-text index (see common.TrainIndex) for the contamination test, so run it with the
interpreter that has numpy. AMI meetings in a scorecard series or overlapping r10d training text are
left out and listed in exclusions-<source>.tsv with the reason.
"""
import argparse
import json
import os
import re
import sys
from collections import Counter
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import nxt
from common import (DATA_ROOT, MAX_QUOTE_WORDS, MIN_QUOTE_WORDS, Chunk, Record, TrainIndex, chunk_turns,
                    content_words, make_row, stable_hash, validate_row, write_jsonl, REPO_ROOT)

REPO = REPO_ROOT
AMI_ROOT = REPO / "Evals/runs/public/ami/extracted"
ICSI_LONG_EVAL = REPO / "Evals/public-long-eval-groups-icsi.json"
ICSI_ROOT = DATA_ROOT / "raw/icsi-plus/x/ICSIplus"
SCORECARD_SETS = Path(os.environ.get("HUSHY_MEETING_SETS", REPO / ".build/meetings-hillclimb/sets"))
SCRIPT_CONTAMINATION = SCORECARD_SETS / "contamination.tsv"
INDEX_CACHE = DATA_ROOT / "cache/trainindex"
# The public recipe (HUSHY_MEETING_PUBLIC=1) runs without the maintainers' evaluation sets: when one of
# those files is absent there, nothing is held out for it. Without the variable a missing file is an error.
PUBLIC_RECIPE = os.environ.get("HUSHY_MEETING_PUBLIC") == "1"


def maintainer_file(path: Path) -> Path | None:
    """`path`, or None when the public recipe runs on a checkout that does not have it."""
    if PUBLIC_RECIPE and not path.exists():
        print(f"note: {path} is absent; the public recipe holds out nothing for it", file=sys.stderr)
        return None
    return path

OWNER_PATTERNS = [
    ("Project Manager", r"project manager|\bpm\b"),
    ("Marketing Expert", r"marketing"),
    ("User Interface Designer", r"user interface|\bui\b|interface (?:designer|specialist)"),
    ("Industrial Designer", r"industrial designer|\bid\b"),
]
DUE = re.compile(
    r"\b(?:(?:by|before|until|for|in|within|during)\s+(?:the\s+)?(?:next|this|our)\s+(?:meeting|session|week|month)"
    r"|next\s+(?:meeting|week|month|session)|tomorrow|today|end of (?:the\s+)?(?:day|week|month|meeting)"
    r"|(?:by|on|before)\s+(?:monday|tuesday|wednesday|thursday|friday|saturday|sunday)"
    r"|within\s+\w+\s+(?:days?|weeks?|minutes?|hours?))\b",
    re.I)
KIND = {"decisions": "decision", "actions": "action"}
WEAK_BELOW = 2
HELD = "held-r10d-overlap"
LICENCE = {"ami": "CC-BY-4.0", "icsi": "CC-BY-4.0"}


def ami_meetings() -> dict:
    text = (AMI_ROOT / "corpusResources/meetings.xml").read_text(encoding="latin-1")
    meetings = {}
    for block in re.finditer(r'<meeting [^>]*observation="(\w+)"[^>]*duration="(\d+)"[^>]*>(.*?)</meeting>', text, re.S):
        meetings[block.group(1)] = {
            "duration": int(block.group(2)),
            "roles": dict(re.findall(r'nxt_agent="(\w)"[^>]*role="(\w+)"', block.group(3))),
        }
    return meetings


def scorecard_ids() -> set:
    ids = set()
    for name in ("ami-dev", "ami-test", "ami-long"):
        path = maintainer_file(SCORECARD_SETS / f"{name}.json")
        if path is None:
            continue
        for m in json.load(open(path))["meetings"]:
            ids.add(m["id"])
    return ids


def series_of(meeting_id: str) -> str:
    return meeting_id[:-1] if re.search(r"[a-z]$", meeting_id) else meeting_id


def icsi_series(meeting_id: str) -> str:
    return re.sub(r"\d+$", "", meeting_id)


def owner_of(sentence: str, labels: set) -> str | None:
    """The one role named as the subject, before the first modal; nobody when two roles share the task."""
    subject = re.split(r"\b(?:will|should|is going to|are going to|has to|have to|needs? to|to)\b", sentence.lower(), maxsplit=1)[0]
    found = {owner for owner, pattern in OWNER_PATTERNS if owner in labels and re.search(pattern, subject)}
    return found.pop() if len(found) == 1 else None


def due_of(quote: str) -> str | None:
    m = DUE.search(quote)
    return m.group(0) if m else None


def locate(chunks: list, turn_to_chunk: dict, act_turn: dict, act_ids: list) -> list:
    """Candidate quotes per chunk: (chunk index, turn index in chunk, quote text)."""
    out = []
    for act_id in act_ids:
        if act_id not in act_turn:
            continue
        turn_idx, text = act_turn[act_id]
        words = text.split()
        if len(words) < MIN_QUOTE_WORDS:
            continue
        if len(words) > MAX_QUOTE_WORDS:
            text = " ".join(words[:MAX_QUOTE_WORDS])
        chunk_no, local = turn_to_chunk[turn_idx]
        out.append((chunk_no, local, text))
    return out


def pick(candidates: list, sentence: str) -> tuple:
    """The chunk holding most linked acts, and in it the quote sharing most content words with the sentence."""
    by_chunk = Counter(c[0] for c in candidates)
    chunk_no = max(by_chunk, key=lambda c: (by_chunk[c], -c))
    target = content_words(sentence)
    ranked = sorted((c for c in candidates if c[0] == chunk_no),
                    key=lambda c: (-len(target & content_words(c[2])), -len(c[2].split())))
    return chunk_no, ranked


def build_meeting(source: str, meeting, sentences: dict, links: dict, meta: dict, index: TrainIndex) -> tuple:
    chunks = chunk_turns(meeting.turns)
    turn_to_chunk = {}
    for ci, chunk in enumerate(chunks):
        for local in range(len(chunk.turns)):
            turn_to_chunk[chunk.first_turn + local] = (ci, local)
    labels = set(meeting.speakers)
    per_chunk = {i: [] for i in range(len(chunks))}
    aux = {i: [] for i in range(len(chunks))}
    dropped = Counter()
    for sid, (section, sentence) in sentences.items():
        if section in ("abstract", "progress"):
            continue
        candidates = locate(chunks, turn_to_chunk, meeting.act_turn, links.get(sid, []))
        if not candidates:
            dropped[f"{section}:unlinked"] += 1
            continue
        chunk_no, ranked = pick(candidates, sentence)
        quote = ranked[0][2]
        alts = [{"turn": c[1], "quote": c[2]} for c in ranked[1:4]]
        shared = len(content_words(sentence) & content_words(ranked[0][2]))
        if section == "problems":
            aux[chunk_no].append({"section": "problems", "text": sentence, "turn": ranked[0][1], "quote": quote})
            continue
        kind = KIND[section]
        owner = owner_of(sentence, labels) if kind == "action" else None
        record = Record(kind, sentence, owner, due_of(quote) if kind == "action" else None, quote)
        per_chunk[chunk_no].append((record, ranked[0][1], alts, sid, shared))
    rows = []
    for ci, chunk in enumerate(chunks):
        items = sorted(per_chunk[ci], key=lambda x: x[1])
        text = " ".join(t.text for t in chunk.turns)
        hits, grams = index.overlap(text)
        row = make_row(
            source=source, licence=LICENCE[source], commercial_safe=True, meeting_id=meeting.meeting_id,
            series=meta["series"], chunk_no=ci, chunk_total=len(chunks), chunk=chunk,
            meeting_meta={"title": meta["title"], "kind": meta["kind"], "speakers": meeting.speakers,
                          "minutes": meta["minutes"]},
            split=meta["split"], gold="human-linked", records=[x[0] for x in items],
            notes={
                "label_source": "corpus abstractive summary sentence linked by annotators to dialogue acts",
                "gold_complete": False,
                "alignments": [{"turn": x[1], "summary_sentence_id": x[3], "shared_content_words": x[4],
                                "weak": x[4] < WEAK_BELOW, "alt_quotes": x[2]} for x in items],
                "unmapped_problems": aux[ci],
                "train_overlap_10grams": [hits, grams],
            })
        rows.append(row)
    return rows, dropped


def run_ami(index: TrainIndex, out: Path) -> None:
    meta = ami_meetings()
    scorecard = scorecard_ids()
    scorecard_series = {series_of(m) for m in scorecard}
    script_hits = {}
    contamination = maintainer_file(SCRIPT_CONTAMINATION)
    for line in (open(contamination).read().splitlines()[1:] if contamination else []):
        m, h, _ = line.split("\t")
        script_hits[m] = int(h)
    rows, exclusions, dropped = [], [], Counter()
    for path in sorted((AMI_ROOT / "abstractive").glob("*.abssumm.xml")):
        mid = path.name.split(".")[0]
        if mid not in meta or len(meta[mid]["roles"]) < 3:
            continue
        series = series_of(mid)
        if mid in scorecard:
            exclusions.append((mid, "scorecard-set"))
            continue
        if series in scorecard_series:
            exclusions.append((mid, "scorecard-series"))
            continue
        meeting = nxt.load_ami(AMI_ROOT, mid, meta[mid]["roles"])
        full = " ".join(t.text for t in meeting.turns)
        mine = index.probe_hits(full)
        overlap = max(mine, script_hits.get(mid, 0))
        if overlap:
            exclusions.append((mid, f"held-r10d-overlap probes mine={mine} script={script_hits.get(mid, 0)}"))
        split = HELD if overlap else ("val" if stable_hash(series) % 8 == 0 else "train")
        info = {"series": series, "split": split, "title": f"AMI {mid}", "kind": "product design team meeting (role-play scenario)",
                "minutes": round(meta[mid]["duration"] / 60)}
        sentences = nxt.summary_sentences(path)
        links = nxt.summary_links(AMI_ROOT / f"extractive/{mid}.summlink.xml") if (AMI_ROOT / f"extractive/{mid}.summlink.xml").exists() else {}
        r, d = build_meeting("ami", meeting, sentences, links, info, index)
        rows += r
        dropped.update(d)
    write_all("ami", rows, exclusions, dropped, out)


def run_icsi(index: TrainIndex, out: Path) -> None:
    base = ICSI_ROOT / "Contributions/Summarization"
    rows, exclusions, dropped = [], [], Counter()
    long_eval_file = maintainer_file(ICSI_LONG_EVAL)
    long_eval = set(json.load(open(long_eval_file))) if long_eval_file else set()
    for path in sorted((base / "abstractive").glob("*.abssumm.xml")):
        mid = path.name.split(".")[0]
        if mid in long_eval:
            exclusions.append((mid, "icsi-long-eval-group"))
            continue
        link = base / f"extractive/{mid}.summlink.xml"
        if not link.exists():
            exclusions.append((mid, "no-summary-links"))
            continue
        meeting = nxt.load_icsi(ICSI_ROOT, mid)
        if not meeting.turns:
            exclusions.append((mid, "no-turns"))
            continue
        full = " ".join(t.text for t in meeting.turns)
        mine = index.probe_hits(full)
        if mine:
            exclusions.append((mid, f"held-r10d-overlap probes mine={mine}"))
        series = icsi_series(mid)
        split = HELD if mine else ("val" if stable_hash(series) % 4 == 0 else "train")
        minutes = round((meeting.turns[-1].start - meeting.turns[0].start) / 60)
        info = {"series": series, "split": split, "title": f"ICSI {mid}", "kind": "research group meeting", "minutes": minutes}
        r, d = build_meeting("icsi", meeting, nxt.summary_sentences(path), nxt.summary_links(link), info, index)
        rows += r
        dropped.update(d)
    write_all("icsi", rows, exclusions, dropped, out)


def write_all(source: str, rows: list, exclusions: list, dropped: Counter, out: Path) -> None:
    bad = {r["id"]: validate_row(r) for r in rows if validate_row(r)}
    clean = [r for r in rows if r["id"] not in bad]
    write_jsonl(out / f"{source}.jsonl", [r for r in clean if r["split"] != HELD])
    write_jsonl(out / f"{source}-r10d-overlap.jsonl", [r for r in clean if r["split"] == HELD])
    with open(out / f"exclusions-{source}.tsv", "w") as f:
        f.write("meeting\treason\n")
        for m, reason in exclusions:
            f.write(f"{m}\t{reason}\n")
    (out / f"dropped-{source}.json").write_text(json.dumps({"unlinked_or_unmapped": dropped, "invalid_rows": bad}, indent=1))
    n = Counter(rec["kind"] for r in clean for rec in r["output"])
    print(f"{source}: {len(clean)} chunks from {len({r['meeting_id'] for r in clean})} meetings, "
          f"{sum(n.values())} records {dict(n)}, excluded {len(exclusions)}, dropped {dict(dropped)}, invalid {len(bad)}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("source", choices=["ami", "icsi"])
    parser.add_argument("--out", default=str(DATA_ROOT / "stage"))
    args = parser.parse_args()
    index = TrainIndex(INDEX_CACHE)
    (run_ami if args.source == "ami" else run_icsi)(index, Path(args.out))


if __name__ == "__main__":
    main()
