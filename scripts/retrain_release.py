"""Pilot round 4: the release route and the policy relabel. Pure helpers, no I/O and no model call.

- which destination app each passage family stands for (the release options differ by app);
- the relabel card (the speech groups and their release-route drafts, no typed text);
- rows for `murmur-eval finetune verdicts` and reading its answers;
- how a relabelled passage differs from the earlier typed text, in words and by class;
- the per-reason tables (counts and three example ids per reason).
"""

import difflib
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import retrain_groups as groups_lib  # noqa: E402
import retrain_numbers as numbers  # noqa: E402
from retrain_lexicon import CURRENCY_WORDS, EXPANSIONS, FUNCTION_WORDS, HESITATIONS  # noqa: E402

AGENT_BUNDLE = "com.anthropic.claudefordesktop"
# A family is the kind of place the person is writing in. The agent family is the code-reading Claude desktop app;
# the others are a plain app of that kind, so the options come from `PipelineSettings.forDictation` for that app.
BUNDLES = {"agent": AGENT_BUNDLE, "chat": "com.tinyspeck.slackmacgap", "status": "com.tinyspeck.slackmacgap",
           "email": "com.apple.mail", "personal": "com.apple.MobileSMS", "note": "com.apple.Notes"}
ARMS = ("group", "whole")
ROUTES = ("speech_first", "typed_first")
EXAMPLES_PER_REASON = 3


def bundle_for(family):
    return BUNDLES[family]


def groups_in_rows(sources):
    return [{"id": s["id"], "text": s["spoken"], "bundle": bundle_for(s["family"])} for s in sources]


# ---- the relabel call -----------------------------------------------------------------------------

def relabel_card(source, group_row):
    """What the relabel writer sees: each group's speech, its release-route draft, and the left context. No typed
    text: the pieces are made from the drafts, so the joined pieces are the new typed text."""
    cards, previous = [], ""
    for g in group_row["groups"]:
        cards.append({"index": g["index"], "continues_sentence": g["continuesSentence"], "text": g["text"],
                      "draft": g["draft"], "left_context": groups_lib.left_context(previous)})
        previous = g["draft"]
    return {"groups": cards, "planted": [{"said_first": p["said_first"], "ended_on": p["ended_on"]}
                                         for p in source["plants"] if p["kind"] != "opening_adds"]}


# ---- rows for the verdict command and its answers ----------------------------------------------------

def verdict_rows(source, group_row, pieces, typed_new):
    """Rows {id, raw, target, bundle}: one per group piece (the group arm) and the whole passage (the whole arm,
    against the joined relabelled pieces and, labelled `-whole-old`, against the earlier typed text)."""
    bundle = bundle_for(source["family"])
    rows = [{"id": f"{source['id']}-whole", "raw": source["spoken"], "target": typed_new, "bundle": bundle},
            {"id": f"{source['id']}-whole-old", "raw": source["spoken"], "target": source["typed"], "bundle": bundle}]
    for group, piece in zip(group_row["groups"], pieces or []):
        if piece["piece"].strip():
            rows.append({"id": f"{source['id']}-g{group['index']}", "raw": group["text"],
                         "target": piece["piece"].strip(), "bundle": bundle})
    return rows


BASES = ("exact", "same_words", "approx", "approx_unreproduced")


def _word_list(text):
    return re.findall(r"[a-z0-9]+(?:'[a-z]+)?", text.lower().replace("\u2019", "'"))


def release_verdict(row):
    """{status, reason, basis, release_draft} from one `finetune verdicts` row. `basis` says how far the answer is the
    pair-check result on the release route's draft: `exact` (the check built the release draft), `same_words` (its draft differs from the release draft
    only in case and punctuation, which the word-level guards do not see), `approx` (the check was re-run on the release
    draft, which it rebuilt exactly) or `approx_unreproduced` (re-run, but the rules changed the draft again)."""
    if row is None:
        return {"status": "not_run", "reason": "", "basis": None, "release_draft": ""}
    if "error" in row:
        return {"status": "not_run", "reason": row["error"], "basis": None, "release_draft": ""}
    if row.get("pairCheckDraftMatchesReleaseDraft", row.get("verdictExact")):
        basis, reason = "exact", row["rejection"]
    elif _word_list(row["ownDraft"]) == _word_list(row["releaseDraft"]):
        basis, reason = "same_words", row["rejection"]
    else:
        basis = "approx" if row.get("approxDraftReproduced") else "approx_unreproduced"
        reason = row.get("approxRejection")
    at_clean = row.get("rejectionAtClean")
    return {"status": "rejected" if isinstance(reason, str) else "accepted", "reason": reason or "", "basis": basis,
            "release_draft": row["releaseDraft"], "at_clean": at_clean if isinstance(at_clean, str) else ""}


def reason_key(reason):
    return reason.split(":")[0].strip() or "rejected"


# ---- how the new typed text differs from the earlier one ----------------------------------------------

_EDGE = ".,;:!?\"()[]{}<>“”"
INFORMAL = frozenset(EXPANSIONS) | {"kinda", "sorta", "lemme", "gimme", "dunno", "ya", "yeah", "nope"}
CLASSES = ("number", "code token", "contraction", "function word", "content dropped", "content added",
           "content replaced")


def tokens(text):
    out = []
    for raw in text.lower().split():
        tok = raw.strip(_EDGE).replace("’", "'")
        tok = tok.rstrip("-")  # a dash standing alone is punctuation
        if tok:
            out.append(tok)
    return out


def _has_digit(tok):
    return any(c.isdigit() for c in tok)


NUMBER_WORDS = frozenset("""zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen
sixteen seventeen eighteen nineteen twenty thirty forty fifty sixty seventy eighty ninety hundred thousand million
first second third fourth fifth sixth seventh eighth ninth tenth half quarter dollars dollar percent o'clock""".split())


def _is_code(tok):
    return tok.startswith("--") or bool(re.search(r"[a-z0-9][./_][a-z0-9]", tok) and not _has_digit_only(tok)) \
        or tok in {"dot", "slash", "dash", "underscore"}


def _has_digit_only(tok):
    return bool(re.fullmatch(r"[\d.,:/$%-]+", tok))


def _classify(old, new):
    chunk = old + new
    if any(_has_digit(t) or t in NUMBER_WORDS for t in chunk):
        return "number"
    if any(_is_code(t) for t in chunk):
        return "code token"
    if any("'" in t or t in INFORMAL for t in chunk) and (len(old) <= 3 and len(new) <= 3):
        return "contraction"
    if all(t in FUNCTION_WORDS for t in chunk):
        return "function word"
    content_old = [t for t in old if t not in FUNCTION_WORDS]
    content_new = [t for t in new if t not in FUNCTION_WORDS]
    if content_old and content_new:
        return "content replaced"
    return "content dropped" if content_old else "content added" if content_new else "function word"


def word_differences(old_text, new_text):
    """[(class, old words, new words)] for every word-level difference (punctuation and case ignored)."""
    old, new = tokens(old_text), tokens(new_text)
    out = []
    for op, a0, a1, b0, b1 in difflib.SequenceMatcher(a=old, b=new, autojunk=False).get_opcodes():
        if op != "equal":
            out.append((_classify(old[a0:a1], new[b0:b1]), " ".join(old[a0:a1]), " ".join(new[b0:b1])))
    return out


def difference_summary(sources, new_typed):
    """How many passages differ in words, and in which classes (a passage counts once per class it shows; `events` counts
    every separate word-level difference)."""
    changed, per_route = [], {r: 0 for r in ROUTES}
    by_class = {c: 0 for c in CLASSES}
    by_class_route = {r: {c: 0 for c in CLASSES} for r in ROUTES}
    events = {c: 0 for c in CLASSES}
    for source in sources:
        diffs = word_differences(source.get("typed_earlier", source["typed"]), new_typed.get(source["id"], source["typed"]))
        if not diffs:
            continue
        changed.append(source["id"])
        per_route[source["route"]] += 1
        for name, _, _ in diffs:
            events[name] += 1
        for name in {d[0] for d in diffs}:
            by_class[name] += 1
            by_class_route[source["route"]][name] += 1
    return {"passages": len(sources), "differ_in_words": len(changed), "by_route": per_route, "by_class": by_class,
            "by_class_and_route": by_class_route, "events": events, "ids": changed}


# ---- the per-reason tables ------------------------------------------------------------------------------

def arm_records(assessments):
    """[(arm, route, id, accepted_by_guard, reason, basis)] one per (draft, piece) pair that was judged."""
    out = []
    for a in assessments:
        if a["whole"]["guard"]["status"] in ("accepted", "rejected"):
            g = a["whole"]["guard"]
            out.append(("whole", a["route"], a["id"], g["status"] == "accepted", g.get("reason", ""), g.get("basis")))
        for grp in a["groups"]:
            g = grp["guard"]
            if g["status"] in ("accepted", "rejected"):
                out.append(("group", a["route"], f"{a['id']}-g{grp['index']}", g["status"] == "accepted",
                            g.get("reason", ""), g.get("basis")))
    return out


def passage_of(ident):
    return re.sub(r"-(g\d+|whole(-old)?)$", "", ident)


def pick_examples(ids, count=EXAMPLES_PER_REASON):
    """Up to `count` ids, from different passages first, in the order they were judged."""
    chosen, seen = [], set()
    for ident in ids:
        if passage_of(ident) not in seen and len(chosen) < count:
            chosen.append(ident)
            seen.add(passage_of(ident))
    for ident in ids:
        if ident not in chosen and len(chosen) < count:
            chosen.append(ident)
    return chosen


def reason_table(records):
    """{arm: {route: {judged, accepted, rejected, exact, reasons: {reason: {count, examples}}}}}"""
    table = {}
    for arm in ARMS:
        table[arm] = {}
        for route in ROUTES:
            rows = [r for r in records if r[0] == arm and r[1] == route]
            ids = {}
            for _, _, ident, ok, reason, _ in rows:
                if not ok:
                    ids.setdefault(reason_key(reason), []).append(ident)
            reasons = {key: {"count": len(found), "examples": pick_examples(found)} for key, found in ids.items()}
            table[arm][route] = {
                "judged": len(rows), "accepted": sum(1 for r in rows if r[3]), "rejected": sum(1 for r in rows if not r[3]),
                "basis": {name: sum(1 for r in rows if r[5] == name) for name in BASES},
                "reasons": dict(sorted(reasons.items(), key=lambda kv: -kv[1]["count"]))}
    return table


# ---- drafts that lost a content word --------------------------------------------------------------------

_SPOKEN_FILLERS = frozenset("""like you know mean okay ok so well right yeah yes just basically actually literally kind sort
of really oh wait no sorry scratch that forget never mind dot slash dash underscore percent""".split())
_TAKEN_BACK = re.compile(r"\b(no wait|no,? wait|sorry|scratch that|actually,? no|no,? no)\b", re.I)


def lost_content_words(text, draft):
    """Content words of the speech that are gone from the rules draft altogether. Not counted: fillers, hesitations,
    function words, number words and currency or unit words (the rules write them as symbols), a word that is still
    in the draft once (a stutter or a restart copy was removed), and anything in a group with a cued take-back
    ("no wait", "sorry", "scratch that"), where the first value is meant to go."""
    if _TAKEN_BACK.search(text):
        return []
    draft_words = set(_word_list(draft))
    lost = []
    for word in _word_list(text):
        if word in draft_words or word in lost:
            continue
        if word in FUNCTION_WORDS or word in _SPOKEN_FILLERS or word in HESITATIONS or word in CURRENCY_WORDS \
                or word.isdigit() or numbers.is_number_word(word) or word.endswith("n't"):
            continue
        lost.append(word)
    return lost


def damaged_drafts(group_rows):
    """{pair id: [lost words]} for every group draft, and for the whole draft, that lost a content word."""
    found = {}
    for row in group_rows.values():
        for g in row["groups"]:
            lost = lost_content_words(g["text"], g["draft"])
            if lost:
                found[f"{row['id']}-g{g['index']}"] = lost
        lost = lost_content_words(row["text"], row["wholeDraft"])
        if lost:
            found[f"{row['id']}-whole"] = lost
    return found
