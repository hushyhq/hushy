#!/usr/bin/env python3
"""Rows from the research-licensed sources: ELITR (heuristic gold from minutes), QMSum committee
meetings (heuristic gold from query answers), MeetingBank (input only).

    build_other.py elitr|qmsum|meetingbank [--out DIR]

Gold here is weaker than AMI/ICSI. A record's kind is guessed from cue words, and its quote is the
transcript sentence or line that best matches the minutes bullet or the answer. Rows say so in `gold`.
"""
import argparse
import glob
import json
import os
import random
import re
import sys
from collections import Counter
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from build_nxt import INDEX_CACHE
from common import (DATA_ROOT, MAX_QUOTE_WORDS, MIN_QUOTE_WORDS, Chunk, Record, Turn, TrainIndex, chunk_turns,
                    content_words, make_row, stable_hash, validate_row, write_jsonl)

HELD = "held-r10d-overlap"
OVERLAP_LIMIT = 0.02
MIN_CHUNK_WORDS = 300
DECISION_CUE = re.compile(r"\b(decid\w*|agree[ds]?|settled|chose|choose|conclu\w*|resolved?|approved?|adopt\w*|go(?:ing)? with|will (?:use|go with|be using))\b", re.I)
ACTION_CUE = re.compile(r"\b(will|should|need(?:s|ed)? to|have to|has to|must|plans? to|going to|to do|todo|assigned|responsible|action)\b", re.I)
STATE = re.compile(r"\bwill (?:not )?be\b|\bshould be\b|\bis going to be\b|\bmust be\b", re.I)
DESCRIPTIVE = re.compile(r"^\W*(discuss\w*|present\w*|talk\w*|introduc\w*|review\w*|summary|agenda|attendees|date|purpose)\b", re.I)
SENTENCE = re.compile(r"(?<=[.?!])\s+")
MARKUP = re.compile(r"</?(?:another_language|typing|parallel_talk|cough|other_yawn|censored|laugh|unintelligible|other_sigh|talking_to_self|other_noise)\s*/?>")


def best_sentence(texts: list, target: str) -> tuple | None:
    """(index into texts, sentence) with most content words shared with `target`, 3..80 words."""
    want = content_words(target)
    best, score = None, 0
    for i, text in enumerate(texts):
        for sentence in SENTENCE.split(text):
            n = len(sentence.split())
            if not MIN_QUOTE_WORDS <= n <= MAX_QUOTE_WORDS:
                continue
            s = len(want & content_words(sentence))
            if s > score:
                best, score = (i, sentence.strip()), s
    return best if score >= 2 else None


def finish(source: str, rows: list, out: Path, notes: dict | None = None) -> None:
    bad = {r["id"]: validate_row(r) for r in rows if validate_row(r)}
    clean = [r for r in rows if r["id"] not in bad]
    write_jsonl(out / f"{source}.jsonl", [r for r in clean if r["split"] != HELD])
    write_jsonl(out / f"{source}-r10d-overlap.jsonl", [r for r in clean if r["split"] == HELD])
    (out / f"dropped-{source}.json").write_text(json.dumps({"invalid_rows": bad, **(notes or {})}, indent=1))
    n = Counter(rec["kind"] for r in clean if r["output"] for rec in r["output"])
    print(f"{source}: {len(clean)} chunks, gold {Counter(r['gold'] for r in clean)}, records {dict(n)}, invalid {len(bad)}, "
          f"held {sum(1 for r in clean if r['split'] == HELD)}")


def split_for(series: str, index: TrainIndex, text: str, modulus: int = 8) -> tuple:
    hits, grams = index.overlap(text)
    held = grams and hits / grams > OVERLAP_LIMIT
    return (HELD if held else ("val" if stable_hash(series) % modulus == 0 else "train")), [hits, grams]


def elitr(index: TrainIndex, out: Path) -> None:
    root = DATA_ROOT / "raw/elitr/x/elitr-minuting-corpus-en"
    rows, stats = [], Counter()
    for mdir in sorted(glob.glob(str(root / "*/meeting_en_*"))):
        mid = os.path.basename(mdir)
        files = os.listdir(mdir)
        transcript = next((f for f in files if f.startswith("transcript")), None)
        if not transcript:
            continue
        lines, turns = [], []
        speaker, previous = None, None
        for no, raw in enumerate(open(os.path.join(mdir, transcript), encoding="utf-8").read().split("\n"), 1):
            m = re.match(r"\((\w+)\)\s*(.*)", raw)
            if m:
                speaker, raw = m.group(1), m.group(2)
            text = re.sub(r"\s+", " ", MARKUP.sub("", raw)).strip()
            if not text or speaker is None:
                continue
            if turns and previous == speaker:
                turns[-1].text += " " + text
            else:
                turns.append(Turn(speaker, None, text))
            previous = speaker
            lines.append((no, len(turns) - 1, text))
        line_info = {no: (ti, text) for no, ti, text in lines}
        chunks = chunk_turns(turns)
        turn_to_chunk = {}
        for ci, ch in enumerate(chunks):
            for local in range(len(ch.turns)):
                turn_to_chunk[ch.first_turn + local] = (ci, local)
        short = {ci for ci, ch in enumerate(chunks) if ch.words < MIN_CHUNK_WORDS}
        minutes = {}
        for f in files:
            if f.startswith("minutes_"):
                minutes[f] = open(os.path.join(mdir, f), encoding="utf-8").read()
        per_chunk = {i: [] for i in range(len(chunks))}
        labels = {t.speaker for t in turns}
        for af in [f for f in files if f.startswith("alignment")]:
            mfile = af.split("+")[2]
            if mfile not in minutes:
                continue
            bullets = minutes[mfile].split("\n")
            aligned = {}
            for entry in open(os.path.join(mdir, af)).read().splitlines():
                parts = entry.split()
                if len(parts) == 3 and parts[1] != "None":
                    aligned.setdefault(int(parts[1]), []).append(int(parts[0]))
            for bno, tl in aligned.items():
                if bno > len(bullets):
                    continue
                bullet = re.sub(r"^[\s•\-\*\t]+", "", bullets[bno - 1]).strip()
                if len(bullet.split()) < 4 or DESCRIPTIVE.match(bullet):
                    continue
                kind = "decision" if DECISION_CUE.search(bullet) else ("action" if ACTION_CUE.search(bullet) and not STATE.search(bullet) else None)
                if kind is None:
                    stats["bullet-no-cue"] += 1
                    continue
                present = [(no, line_info[no]) for no in tl if no in line_info]
                hit = best_sentence([t for _, (_, t) in present], bullet)
                if not hit:
                    stats["bullet-no-quote"] += 1
                    continue
                idx, quote = hit
                turn_idx = present[idx][1][0]
                ci, local = turn_to_chunk[turn_idx]
                head = re.match(r"\[?(PERSON\d+)\]?", bullet)
                owner = head.group(1) if kind == "action" and head and head.group(1) in labels else None
                text = re.sub(r"[\[\]]", "", bullet)
                per_chunk[ci].append((Record(kind, text, owner, None, quote), local, af))
                stats[f"gold-{kind}"] += 1
        text_all = " ".join(t.text for t in turns)
        series = "-".join(mid.split("_")[:2])
        split, overlap = split_for(mid, index, text_all)
        has_gold = any(per_chunk.values())
        for ci, ch in enumerate(chunks):
            if ci in short:
                continue
            items = sorted(per_chunk[ci], key=lambda x: x[1])
            present = {t.speaker for t in ch.turns}
            items = [(Record(r.kind, r.text, r.owner if r.owner in present else None, r.due, r.quote), a, b) for r, a, b in items]
            rows.append(make_row(
                source="elitr", licence="CC-BY-NC-SA-4.0", commercial_safe=False, meeting_id=mid, series=series,
                chunk_no=ci, chunk_total=len(chunks), chunk=ch,
                meeting_meta={"title": mid, "kind": "computer-science project meeting (de-identified)", "speakers": sorted(labels),
                              "minutes": None},
                split=split, gold="heuristic-minutes" if has_gold else "none",
                records=[x[0] for x in items] if has_gold else None,
                notes={"label_source": "human minutes bullet aligned to transcript lines; kind guessed from cue words",
                       "gold_complete": False, "alignments": [{"turn": x[1], "alignment_file": x[2]} for x in items],
                       "train_overlap_10grams": overlap,
                       "minutes_present": sorted(minutes)}))
    finish("elitr", rows, out, {"bullet_stats": stats})


def qmsum(index: TrainIndex, out: Path) -> None:
    base = glob.glob(str(DATA_ROOT / "raw/qmsum/x/*/data/Committee"))[0]
    decision_query = re.compile(r"\b(decid\w*|conclu\w*|agree\w*|resolv\w*|decision|recommend\w*|next steps?|outcome)\b", re.I)
    rows, stats = [], Counter()
    seen = set()
    for split_dir in ("train", "val", "test"):
        for path in sorted(glob.glob(f"{base}/{split_dir}/*.json")):
            mid = os.path.basename(path)[:-5]
            if mid in seen:
                continue
            seen.add(mid)
            d = json.load(open(path, encoding="utf-8"))
            turns = [Turn(re.sub(r"\s*\(.*$", "", t["speaker"]).strip() or t["speaker"], None, t["content"].strip())
                     for t in d["meeting_transcripts"] if t["content"].strip()]
            chunks = chunk_turns(turns)
            turn_to_chunk = {}
            for ci, ch in enumerate(chunks):
                for local in range(len(ch.turns)):
                    turn_to_chunk[ch.first_turn + local] = (ci, local)
            per_chunk = {i: [] for i in range(len(chunks))}
            for q in d["specific_query_list"] + d["general_query_list"]:
                if not decision_query.search(q["query"]) or "relevant_text_span" not in q:
                    continue
                span = [int(x) for pair in q["relevant_text_span"] for x in pair]
                lo, hi = min(span), min(max(span), len(d["meeting_transcripts"]) - 1)
                idxs = [i for i in range(lo, hi + 1) if i < len(d["meeting_transcripts"])]
                texts = [d["meeting_transcripts"][i]["content"].strip() for i in idxs]
                hit = best_sentence(texts, q["answer"])
                if not hit or len(q["answer"].split()) > 70:
                    stats["query-dropped"] += 1
                    continue
                k, quote = hit
                turn_idx = idxs[k]
                if turn_idx not in turn_to_chunk:
                    continue
                ci, local = turn_to_chunk[turn_idx]
                per_chunk[ci].append((Record("decision", q["answer"].strip(), None, None, quote), local, q["query"]))
                stats["gold-decision"] += 1
            text_all = " ".join(t.text for t in turns)
            series = mid.rsplit("_", 1)[0]
            split, overlap = split_for(mid, index, text_all, 4)
            has_gold = any(per_chunk.values())
            for ci, ch in enumerate(chunks):
                items = sorted(per_chunk[ci], key=lambda x: x[1])
                rows.append(make_row(
                    source="qmsum-committee", licence="MIT-annotations; transcripts Canada ourcommons non-commercial / Senedd unclear",
                    commercial_safe=False, meeting_id=mid, series=series, chunk_no=ci, chunk_total=len(chunks), chunk=ch,
                    meeting_meta={"title": f"Parliamentary committee {mid}", "kind": "parliamentary committee meeting",
                                  "speakers": sorted({t.speaker for t in turns}), "minutes": None},
                    split=split, gold="heuristic-query" if has_gold else "none",
                    records=[x[0] for x in items] if has_gold else None,
                    notes={"label_source": "QMSum query whose wording asks for a decision; answer is the record text, quote is the best-matching sentence in the query's relevant turns",
                           "gold_complete": False, "alignments": [{"turn": x[1], "query": x[2]} for x in items],
                           "train_overlap_10grams": overlap, "qmsum_split": split_dir}))
    finish("qmsum-committee", rows, out, {"query_stats": stats})


def meetingbank(index: TrainIndex, out: Path, cap: int = 1500) -> None:
    rows = []
    for name in ("train", "validation", "test"):
        for line in open(DATA_ROOT / f"raw/meetingbank/{name}.json", encoding="utf-8"):
            r = json.loads(line)
            if len(r["transcript"].split()) < 400:
                continue
            rows.append(r)
    rows.sort(key=lambda r: stable_hash(r["uid"]))
    out_rows, per_city = [], Counter()
    for r in rows:
        city = r["uid"].split("_")[0]
        if len(out_rows) >= cap:
            break
        if per_city[city] >= cap // 4:
            continue
        chunks = chunk_turns([Turn(None, None, r["transcript"])], split_long=True)
        text = r["transcript"]
        split, overlap = split_for(city, index, text)
        for ci, ch in enumerate(chunks):
            out_rows.append(make_row(
                source="meetingbank", licence="CC-BY-NC-SA-4.0 (HF card; Zenodo says CC-BY-4.0; authors say research only)",
                commercial_safe=False, meeting_id=r["uid"], series=city, chunk_no=ci, chunk_total=len(chunks), chunk=ch,
                meeting_meta={"title": r["uid"], "kind": "city council agenda item (no speaker labels)", "speakers": [], "minutes": None},
                split=split, gold="none", records=None,
                notes={"agenda_summary": r["summary"], "train_overlap_10grams": overlap}))
            per_city[city] += 1
    finish("meetingbank", out_rows, out)


def notsofar(index: TrainIndex, out: Path) -> None:
    rows = []
    for path in sorted(glob.glob(str(DATA_ROOT / "raw/notsofar/mtg/*/gt_transcription.json"))):
        mid = os.path.basename(os.path.dirname(path))
        meta = json.load(open(path.replace("gt_transcription", "gt_meeting_metadata")))
        utterances = sorted(json.load(open(path)), key=lambda u: u["start_time"])
        turns, last_end = [], {}
        for u in utterances:
            text = re.sub(r"\s+", " ", re.sub(r"<[^>]*>", "", u["text"])).strip()
            if not text:
                continue
            speaker = u["speaker_id"]
            if turns and turns[-1].speaker == speaker and u["start_time"] - last_end[speaker] < 1.5:
                turns[-1].text += " " + text
            else:
                turns.append(Turn(speaker, u["start_time"], text))
            last_end[speaker] = u["end_time"]
        if sum(len(t.text.split()) for t in turns) < 200:
            continue
        chunks = chunk_turns(turns)
        split, overlap = split_for(mid, index, " ".join(t.text for t in turns))
        for ci, ch in enumerate(chunks):
            rows.append(make_row(
                source="notsofar", licence="CC-BY-4.0 (changed from challenge-only on 2026-06-22)", commercial_safe=True,
                meeting_id=mid, series=meta.get("Room", mid), chunk_no=ci, chunk_total=len(chunks), chunk=ch,
                meeting_meta={"title": meta.get("Topic", mid), "kind": f"short recorded conversation ({meta.get('MtgType', 'mtg')})",
                              "speakers": sorted({t.speaker for t in turns}), "minutes": round(meta.get("MeetingDurationSec", 0) / 60)},
                split=split, gold="none", records=None,
                notes={"hashtags": meta.get("Hashtags"), "train_overlap_10grams": overlap, "dataset_version": "240825.1_train"}))
    finish("notsofar", rows, out)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("source", choices=["elitr", "qmsum", "meetingbank", "notsofar"])
    parser.add_argument("--out", default=str(DATA_ROOT / "stage"))
    args = parser.parse_args()
    index = TrainIndex(INDEX_CACHE)
    {"elitr": elitr, "qmsum": qmsum, "meetingbank": meetingbank, "notsofar": notsofar}[args.source](index, Path(args.out))


if __name__ == "__main__":
    main()
