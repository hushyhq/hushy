"""Statistics, the 20-passage sample, and the select filter for mined passages."""

from __future__ import annotations

import random
import statistics

import retrain_passages as passages

PII_KINDS = ("person_name", "phone", "email", "address", "health", "money_personal")
MONOLOGUE_PROPOSAL = {"min_score": 0.5, "max_you_per100": 3.0, "max_questions_per100": 1.5,
                      "max_intrusion_words": 6, "max_overlap_fraction": 0.1}


def share(count, total):
    return round(100 * count / total, 1) if total else 0.0


def group_stats(rows):
    n = len(rows)
    fillers = [r["features"]["filler_per100"] for r in rows]
    return {
        "passages": n, "meetings": len({r["meeting"] for r in rows}),
        "speakers": len({(r["corpus"], r["speaker"]) for r in rows}),
        "words_mean": round(statistics.fmean(r["words"] for r in rows), 1) if n else 0,
        "filler_per100_mean": round(statistics.fmean(fillers), 2) if n else 0,
        "filler_per100_median": round(statistics.median(fillers), 2) if n else 0,
        "filler_per100_pooled": round(100 * sum(r["features"]["hesitations"] for r in rows)
                                      / max(1, sum(r["words"] for r in rows)), 2),
        "pct_with_explicit_self_correction": share(sum(1 for r in rows if r["features"]["explicit_self_correction"]), n),
        "pct_with_numeric_correction_cue": share(sum(1 for r in rows if r["features"]["numeric_correction_cue"]), n),
        "pct_with_i_mean": share(sum(1 for r in rows if r["features"]["i_mean"]), n),
        "pct_with_number": share(sum(1 for r in rows if r["features"]["numbers"]), n),
        "pct_with_date": share(sum(1 for r in rows if r["features"]["dates"]), n),
        "pct_with_proper_noun": share(sum(1 for r in rows if r["features"]["names"]), n),
        "pct_with_repeat_or_fragment": share(sum(1 for r in rows if r["features"]["repeats"] or r["features"]["fragments"]), n),
        "repeats_per_passage": round(statistics.fmean(r["features"]["repeats"] for r in rows), 2) if n else 0,
        "fragments_per_passage": round(statistics.fmean(r["features"]["fragments"] for r in rows), 2) if n else 0,
        "intrusion_words_mean": round(statistics.fmean(r["intrusion"]["words"] for r in rows), 2) if n else 0,
        "pct_with_any_intrusion": share(sum(1 for r in rows if r["intrusion"]["words"]), n),
        "you_per100_mean": round(statistics.fmean(r["features"]["cues"]["you_per100"] for r in rows), 2) if n else 0,
        "questions_per100_mean": round(statistics.fmean(r["features"]["cues"]["questions_per100"] for r in rows), 2) if n else 0,
        "monologue_score_median": round(statistics.median(r["monologue_score"] for r in rows), 3) if n else 0,
        "pct_with_gap_unintelligible_or_censored": share(sum(1 for r in rows if any(r["flags"][k] for k in ("gaps", "unintelligible", "censored"))), n),
        "pii_passages": {k: sum(1 for r in rows if r["features"]["pii"][k]) for k in PII_KINDS},
        "pii_any_passages": sum(1 for r in rows if any(r["features"]["pii"][k] for k in PII_KINDS)),
    }


def ami_layer_stats(rows):
    ami = [r for r in rows if r["corpus"] == "AMI"]
    covered = [r for r in ami if r["ami_layer"]["covered"]]
    marked = [r for r in covered if r["ami_layer"]["taken_back"]]
    return {"ami_passages": len(ami), "covered_by_disfluency_layer": len(covered),
            "pct_covered": share(len(covered), len(ami)),
            "covered_with_taken_back_marks": len(marked),
            "covered_with_replace_or_restart": sum(1 for r in covered if any(
                m["type"] in ("replace", "restart") for m in r["ami_layer"]["taken_back"])),
            "taken_back_marks_per_covered_passage": round(
                statistics.fmean(len(r["ami_layer"]["taken_back"]) for r in covered), 2) if covered else 0}


def build_stats(rows):
    result = {"all": group_stats(rows), "by_corpus_and_length": {}, "ami_layer": ami_layer_stats(rows)}
    for corpus in sorted({r["corpus"] for r in rows}):
        subset = [r for r in rows if r["corpus"] == corpus]
        result["by_corpus_and_length"][f"{corpus} all"] = group_stats(subset)
        for low, high in passages.LENGTH_BINS:
            part = [r for r in subset if passages.length_bin(r["words"]) == f"{low}-{high}"]
            result["by_corpus_and_length"][f"{corpus} {low}-{high}"] = group_stats(part)
    result["monologue_proposal"] = {"filter": MONOLOGUE_PROPOSAL,
                                    "passes": {c: group_stats(select(rows, corpus=c))["passages"]
                                               for c in sorted({r["corpus"] for r in rows})}}
    return result


def select(rows, corpus=None, monologue=True, exclude_pii=(), allow_flags=False, min_score=None):
    """Passages meeting the monologue proposal (when asked), without the named personal-data kinds
    and, unless `allow_flags`, without gaps, undecipherable stretches or censored material."""
    rule = MONOLOGUE_PROPOSAL
    chosen = []
    for row in rows:
        cues, pii = row["features"]["cues"], row["features"]["pii"]
        if corpus and row["corpus"] != corpus:
            continue
        if monologue and not (row["monologue_score"] >= (rule["min_score"] if min_score is None else min_score)
                              and cues["you_per100"] <= rule["max_you_per100"]
                              and cues["questions_per100"] <= rule["max_questions_per100"]
                              and row["intrusion"]["words"] <= rule["max_intrusion_words"]
                              and row["intrusion"]["overlap_fraction"] <= rule["max_overlap_fraction"]):
            continue
        if any(pii.get(kind) for kind in exclude_pii):
            continue
        if not allow_flags and any(row["flags"][k] for k in ("gaps", "unintelligible", "censored")):
            continue
        chosen.append(row)
    return chosen


DEFAULT_MAX_PER_MEETING = 3
DEFAULT_MAX_PER_SPEAKER = 5
ICSI_TYPES = {"Bmr": "Meeting Recorder", "Bro": "Robustness", "Bed": "Even Deeper Understanding",
              "Bns": "Network Services", "Btr": "Transcriber team", "Bdb": "Database", "Bsr": "SRI collaboration",
              "Buw": "UW collaboration"}


def meeting_group(row):
    """AMI: scenario meetings (ids ES, IS, TS: all one remote-control design task) versus non-scenario (EN, IB,
    IN), as meetings.xml types them.
    ICSI: the meeting type from the id's second field (Bmr, Bro, Bed, ...)."""
    if row["corpus"] == "AMI":
        scenario = row["meeting"][:2] in ("ES", "IS", "TS")
        return "AMI scenario (ES/IS/TS)" if scenario else "AMI non-scenario (EN/IB/IN)"
    return f"ICSI {row['meeting'][:3]} ({ICSI_TYPES.get(row['meeting'][:3], 'other')})"


def sampling_group(row):
    return meeting_group(row) if row["corpus"] == "AMI" else "ICSI"


def apply_caps(rows, per_meeting, per_speaker, seed):
    """At most `per_meeting` passages per meeting and `per_speaker` per speaker (0 = no cap), taken in a
    seeded random order so no part of a meeting is favoured."""
    order = sorted(rows, key=lambda r: r["id"])
    random.Random(seed).shuffle(order)
    meetings, speakers, kept = {}, {}, []
    for row in order:
        m, s = (row["corpus"], row["meeting"]), (row["corpus"], row["speaker"])
        if (per_meeting and meetings.get(m, 0) >= per_meeting) or (per_speaker and speakers.get(s, 0) >= per_speaker):
            continue
        meetings[m] = meetings.get(m, 0) + 1
        speakers[s] = speakers.get(s, 0) + 1
        kept.append(row)
    return sorted(kept, key=lambda r: (r["corpus"], r["meeting"], r["start"], r["speaker"]))


def cap_summary(before, after):
    """Passages, meetings and speakers before and after the caps, split by meeting group."""
    def count(rows):
        groups = {}
        for row in rows:
            g = groups.setdefault(meeting_group(row), {"passages": 0, "meetings": set(), "speakers": set()})
            g["passages"] += 1
            g["meetings"].add(row["meeting"])
            g["speakers"].add((row["corpus"], row["speaker"]))
        return {name: {"passages": g["passages"], "meetings": len(g["meetings"]), "speakers": len(g["speakers"])}
                for name, g in sorted(groups.items())}
    return {"before_caps": {"passages": len(before), "groups": count(before)},
            "after_caps": {"passages": len(after), "groups": count(after)}}


def sample_varied(rows, count, seed):
    """`count` passages chosen by `seed`, spread over meeting group (AMI scenario, AMI non-scenario, ICSI) and length bin, one meeting and speaker at
    most once until every stratum has been used."""
    rng = random.Random(seed)
    strata = {}
    for row in rows:
        strata.setdefault((sampling_group(row), passages.length_bin(row["words"])), []).append(row)
    pools = [sorted(pool, key=lambda r: r["id"]) for _, pool in sorted(strata.items())]
    for pool in pools:
        rng.shuffle(pool)
    picked, used_meetings, used_speakers = [], set(), set()
    for strict in (True, False):
        while len(picked) < count and any(pools):
            progressed = False
            for pool in pools:
                for index, row in enumerate(pool):
                    if strict and (row["meeting"] in used_meetings or row["speaker"] in used_speakers):
                        continue
                    picked.append(pool.pop(index))
                    used_meetings.add(row["meeting"])
                    used_speakers.add(row["speaker"])
                    progressed = True
                    break
                if len(picked) >= count:
                    break
            if not progressed:
                break
    return picked


def render_sample(rows):
    blocks = []
    for number, row in enumerate(rows, 1):
        pii = {k: v for k, v in row["features"]["pii"].items() if v}
        head = (f"[{number}] {row['id']}  {row['corpus']} {row['meeting']} speaker {row['speaker']}  "
                f"{row['start']:.0f}s-{row['end']:.0f}s  {row['words']} words  "
                f"monologue score {row['monologue_score']}  intrusion words {row['intrusion']['words']}  "
                f"fillers/100 {row['features']['filler_per100']}  pii cues {pii or 'none'}")
        blocks.append(head + "\n" + row["text"])
    return "\n\n".join(blocks) + "\n"
