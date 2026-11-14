"""Label versions side by side (v1 typed-split, v2 minimal, v3 typed-read): pieces against the release drafts, a simple
run-on measure of the joined text, and the release-route pair-check results where a verdict file exists. Pure helpers."""

import re
import statistics
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import retrain_assemble as assemble  # noqa: E402
import retrain_groups as groups_lib  # noqa: E402
import retrain_release as release  # noqa: E402

RUN_ON_WORDS = 40
SENTENCE_END = re.compile(r"(?<=[.!?])[\"')\]]*\s+|\n+")
WORD = re.compile(r"[a-z0-9]+(?:'[a-z]+)?")


def word_list(text):
    return WORD.findall(text.lower().replace("’", "'"))


def only_punctuation_and_case(draft, piece):
    """True when the piece has exactly the draft's words, so the edit is punctuation and case only."""
    return bool(piece.strip()) and word_list(draft) == word_list(piece)


def sentences(text):
    return [s for s in SENTENCE_END.split(text.strip()) if s.strip()]


def run_on(text):
    """{sentences, over_limit, longest}: sentences longer than 40 words, and the longest sentence's length in words."""
    lengths = [len(s.split()) for s in sentences(text)]
    return {"sentences": len(lengths), "over_limit": sum(1 for n in lengths if n > RUN_ON_WORDS),
            "longest": max(lengths) if lengths else 0}


def version_summary(sources, group_rows, targets, verdicts=None):
    """One label version over the passages. `targets` is {id: {pieces}}; `verdicts` {pair id: verdicts_out row} or None."""
    out = {route: {"passages": 0, "pairs": 0, "punct_case_only": 0, "empty": 0, "over_limit_sentences": 0,
                   "passages_with_over_limit": 0, "longest": [], "sentences": 0} for route in release.ROUTES}
    records = []
    for source in sources:
        grp, target = group_rows.get(source["id"]), targets.get(source["id"])
        if not grp or not target:
            continue
        pieces = [p for p in target["pieces"]]
        if [p["index"] for p in pieces] != [g["index"] for g in grp["groups"]]:
            continue
        row = out[source["route"]]
        joined = groups_lib.join_pieces(pieces)
        measure = run_on(joined)
        row["passages"] += 1
        row["sentences"] += measure["sentences"]
        row["over_limit_sentences"] += measure["over_limit"]
        row["passages_with_over_limit"] += 1 if measure["over_limit"] else 0
        row["longest"].append(measure["longest"])
        for group, piece in zip(grp["groups"], pieces):
            row["pairs"] += 1
            if not piece["piece"].strip():
                row["empty"] += 1
            elif only_punctuation_and_case(group["draft"], piece["piece"]):
                row["punct_case_only"] += 1
        if verdicts is not None:
            for group, piece in zip(grp["groups"], pieces):
                if piece["piece"].strip():
                    v = release.release_verdict(verdicts.get(f"{source['id']}-g{group['index']}"))
                    if v["status"] in ("accepted", "rejected"):
                        records.append(("group", source["route"], f"{source['id']}-g{group['index']}",
                                        v["status"] == "accepted", v["reason"], v["basis"]))
    checks = {route: {} for route in release.ROUTES}
    joined_ok = {route: 0 for route in release.ROUTES}
    for source in sources:
        grp, target = group_rows.get(source["id"]), targets.get(source["id"])
        if not grp or not target or [p["index"] for p in target["pieces"]] != [g["index"] for g in grp["groups"]]:
            continue
        current = {**source, "typed": groups_lib.join_pieces(target["pieces"])}
        result = assemble.assess(current, grp, target, {}, verdict=lambda table, key: {"status": "not_run"})
        if "typed" in target:
            joined_ok[source["route"]] += 1 if groups_lib.same_text(current["typed"], target["typed"]) else 0
        for group in result["groups"]:
            for name in group["failed_checks"]:
                checks[source["route"]][name] = checks[source["route"]].get(name, 0) + 1
    for route, row in out.items():
        row["mechanical_group_checks_failed"] = dict(sorted(checks[route].items()))
        row["joined_equals_writer_typed"] = joined_ok[route]
    for row in out.values():
        longest = row.pop("longest")
        row["longest_sentence"] = max(longest) if longest else 0
        row["median_longest_per_passage"] = statistics.median(longest) if longest else 0
    result = {"shape": out}
    if verdicts is not None:
        result["guard"] = release.reason_table(records)["group"]
    return result


# ---- what the blind judge's stated reasons cluster on -------------------------------------------------

CLUSTERS = {
    "paragraph breaks": r"paragraph|blank line|unbroken|wall of text|single block|one block|dense block",
    "run-on and sentence breaks": r"run-on|run on|sentence|chain|comma splice|comma-splice|strung",
    "fillers and discourse openers": r"filler|hesitat|\bum\b|you know|\blike\b|okay,? so|discourse|opening",
    "restarts, repeats, corrections": r"restart|false start|repeat|repetit|correction|duplicat|redundan|doubled|stutter",
    "numbers, times, dates": r"digit|\d:\d\d|\$|numeral|spelled|spells out|written as words|ordinal|time|date",
    "code tokens and identifiers": r"underscore|identifier|code|\bdot\b|dash dash|file name|spoken form",
    "meaning or missing content": r"dropped|missing (point|content|detail)|omit|lost|meaning",
}


def judge_summary(run):
    """From an api_judge report (the .json): pair outcomes and how many of the judge's stated reasons (one per call, both
    orders) mention each theme. A reason can mention several themes."""
    name, pair = next(iter(run["pair_summary"].items()))
    clusters = {key: 0 for key in CLUSTERS}
    reasons = 0
    for call in run["calls"]:
        verdict = call.get("verdict")
        if not verdict:
            continue
        reasons += 1
        text = verdict["reason"].lower()
        for key, pattern in CLUSTERS.items():
            if re.search(pattern, text):
                clusters[key] += 1
    return {"pair": name, "pairs": pair["pairs"], "wins": pair["wins"], "ties": pair["ties"],
            "inconsistent": pair["inconsistent"], "reasons": reasons,
            "clusters": dict(sorted(clusters.items(), key=lambda kv: -kv[1])), "meta": run["meta"]}
