"""Automatic checks on a written typed version, each reported on its own (never merged into one score).

Every check is a cheap lexical test. A pass means "none of the failures this test looks for"; it does
not prove the typed text is right. What each check can and cannot see is spelled out in its docstring
and in docs of the writer (Evals/judge/TYPED-WRITER-INSTRUCTIONS.md is the model's brief; this file is
the auditor's). Inputs: the spoken text, the typed text, the writer's list of corrections it resolved,
and for AMI passages the disfluency layer's taken-back words.
"""

from __future__ import annotations

import re
from collections import Counter

import retrain_numbers as numbers
import retrain_wordchecks as wordchecks

from retrain_lexicon import (CLOSED_CLASS, DISCOURSE_AFTER_NO, DISCOURSE_CAPITALS, EXPANSIONS, FUNCTION_WORDS,  # noqa: F401,E402
                             HESITATIONS, INFORMAL_NEGATIONS, CURRENCY_WORDS, MONTHS, NEGATIONS, WEEKDAYS, WORD, content_stems,
                             grammar_forms, prep_spoken, result, spoken_vocabulary, stem, words)

LENGTH_BAND = (0.55, 1.02)  # typed words / spoken words: below = over-deletion, above = under-deletion
ORDER_TOLERANCE_WORDS = 6
ORDER_MAX_OUT_OF_ORDER = 0.10
DEFAULT_MAX_ADDED_WORDS = wordchecks.DEFAULT_MAX_ADDED_WORDS
DEFAULT_FUNCTION_TOLERANCE_PER100 = wordchecks.DEFAULT_FUNCTION_TOLERANCE_PER100
CLOCK_MARKS = frozenset({"am", "pm"})
ALLOWED_REPEATS = frozenset("had that".split())

# ---- numbers, dates, names -----------------------------------------------------------------------

def _values(found):
    return {n.value for n in found} | {a for n in found for a in n.alternates}


def _removed_counter(corrections, taken_back):
    """Words the speaker took back: in the writer's `said_first` text but not `ended_on`, plus the
    disfluency layer's taken-back words."""
    removed = Counter()
    for item in corrections:
        kept = Counter(words(item["ended_on"]))
        for word, count in Counter(words(item["said_first"])).items():
            removed[word] += max(0, count - kept[word])
    for word in taken_back:
        removed[word.lower()] += 1
    return removed


def check_numbers(spoken, typed, corrections, taken_back):
    """Every number in the typed text exists in the spoken text by value, and every spoken number that was
    not taken back is in the typed text. Blind to: a number that changed to another value which also
    appears elsewhere in the passage; a lone "one" (a pronoun) and bare ordinals are not required."""
    spoken_numbers, typed_numbers = numbers.extract(spoken), numbers.extract(typed)
    spoken_all, typed_all = _values(spoken_numbers), _values(typed_numbers)
    added = sorted({n.value for n in typed_numbers if not n.weak and n.value not in spoken_all
                    and not (n.alternates & spoken_all)}, key=float)
    taken = Counter()
    for item in corrections:
        for n in numbers.extract(item["said_first"]):
            taken[n.value] += 1
        for n in numbers.extract(item["ended_on"]):
            taken[n.value] -= 1
    for word in taken_back:
        for n in numbers.extract(word):
            taken[n.value] += 1
    needed = Counter(n.value for n in spoken_numbers if not n.weak)
    missing = sorted({value for value, count in needed.items() if count - max(0, taken[value]) > 0
                      and value not in typed_all
                      and not any(n.alternates & typed_all for n in spoken_numbers if n.value == value)},
                     key=float)
    return result(not added and not missing, added=added, missing=missing)


def _tracked(vocabulary, text):
    return [w for w in words(text) if w in vocabulary]


def check_dates(spoken, typed, corrections, taken_back):
    """Weekday and month names: none in the typed text that were not said, none said (and not taken back)
    that are missing. Blind to day-of-month numbers (the numbers check covers them)."""
    vocab = WEEKDAYS | MONTHS
    said, wrote = Counter(_tracked(vocab, spoken)), set(_tracked(vocab, typed))
    removed = _removed_counter(corrections, taken_back)
    added = sorted(w for w in wrote if w not in said)
    missing = sorted(w for w, count in said.items() if count - removed[w] > 0 and w not in wrote)
    return result(not added and not missing, added=added, missing=missing)


def capitalised_names(text):
    """Capitalised words that are not at the start of a sentence, as lower-case strings."""
    found, previous = [], ""
    for token in text.split():
        bare = re.sub(r"^[^\w]+|[^\w]+$", "", token)
        starts_sentence = not previous or bool(re.search(r"[.?!]$", previous)) or previous in ("-", "--", "—")
        if re.fullmatch(r"[A-Za-z][A-Za-z'’-]*", bare) and bare[:1].isupper() and len(bare) > 1 and not starts_sentence \
                and bare.lower().replace("’", "'") not in DISCOURSE_CAPITALS | CURRENCY_WORDS | CLOCK_MARKS and "_" not in bare:
            found.extend(part for part in bare.lower().replace("’", "'").split("-") if part)
        previous = token
    return found


def check_names(spoken, typed, corrections, taken_back):
    """Capitalised words in the middle of a sentence: none in the typed text that were not said, none said
    (and not taken back) that are missing. Spoken capitalisation is the transcribers', so a name they
    wrote in lower case is invisible here, and so is a sentence-initial name."""
    said = Counter(capitalised_names(spoken))
    wrote = {w for w in capitalised_names(typed)}
    spoken_vocab = set(words(spoken))
    removed = _removed_counter(corrections, taken_back)
    spoken_stems = spoken_vocabulary(spoken)
    added = sorted(w for w in wrote if w not in spoken_vocab and stem(w) not in spoken_stems)
    typed_vocab = set(words(typed))
    missing = sorted(w for w, count in said.items() if count - removed[w] > 0 and w not in typed_vocab
                     and stem(w) not in {stem(t) for t in typed_vocab})
    return result(not added and not missing, added=added, missing=missing)


# ---- negation ------------------------------------------------------------------------------------

def collapse_repeats(tokens):
    """Drops a word or phrase (up to 8 words) said twice in a row, keeping the last: "i do not i do not"."""
    tokens = list(tokens)
    changed = True
    while changed:
        changed = False
        for size in (8, 7, 6, 5, 4, 3, 2, 1):
            for i in range(len(tokens) - 2 * size + 1):
                if tokens[i:i + size] == tokens[i + size:i + 2 * size]:
                    del tokens[i:i + size]
                    changed = True
                    break
            if changed:
                break
    return tokens


def _negation_tokens(text):
    """Lower-case words, with a "no" that is an answer or an interjection ("no, ...", "no wait") renamed."""
    raw = text.lower().replace("’", "'").split()
    clean = [re.sub(r"^[^\w']+|[^\w']+$", "", t) for t in raw]
    out = []
    for i, word in enumerate(clean):
        if not word:
            continue
        if word == "no":
            following = next((w for w in clean[i + 1:] if w), "")
            if raw[i] != word or not following or following in DISCOURSE_AFTER_NO:
                word = "no_discourse"
        out.append(word)
    return out


def negation_count(text, collapse=False):
    tokens = _negation_tokens(text)
    if collapse:
        tokens = collapse_repeats(tokens)
    return sum(1 for w in tokens if w in NEGATIONS or w in INFORMAL_NEGATIONS or w == "no" or w.endswith("n't"))


def check_negation(spoken, typed, corrections, taken_back):
    """Typed negations never exceed spoken, and fall short only by the negations inside resolved corrections
    or the layer's taken-back words. Spoken repeats are collapsed first. Blind to a negation that moved to
    a different clause, and to "no" used as an answer ("no, we did not") beyond the simple rules above."""
    said = negation_count(spoken, collapse=True)
    wrote = negation_count(typed)
    resolved = sum(negation_count(c["said_first"]) for c in corrections) \
        + sum(1 for w in taken_back if w.lower() in NEGATIONS or w.lower() in INFORMAL_NEGATIONS
              or w.lower().endswith("n't"))
    problems = []
    if wrote > said:
        problems.append("negation_added")
    if wrote < said - resolved:
        problems.append("negation_lost")
    return result(not problems, spoken=said, typed=wrote, resolved=resolved, problems=problems)


# ---- length --------------------------------------------------------------------------------------

def check_length(spoken, typed, band=LENGTH_BAND):
    """Typed words / spoken words inside the band. Below the band is over-deletion (points lost), above it
    is under-deletion (nothing cleaned or text added); the two are counted apart."""
    spoken_n, typed_n = len(words(spoken)), len(words(typed))
    ratio = typed_n / spoken_n if spoken_n else 0.0
    label = "over_deletion" if ratio < band[0] else "under_deletion" if ratio > band[1] else "ok"
    return result(label == "ok", ratio=round(ratio, 3), label=label, band=list(band))


# ---- order ---------------------------------------------------------------------------------------

def first_positions(stems_in_order):
    seen = {}
    for position, word in enumerate(stems_in_order):
        seen.setdefault(word, position)
    return seen


def check_order(spoken, typed, tolerance=ORDER_TOLERANCE_WORDS, max_out_of_order=ORDER_MAX_OUT_OF_ORDER):
    """First occurrences of the typed text's content words, looked up in the spoken text, should rise (to
    within `tolerance` words). The share outside the longest rising run must stay under `max_out_of_order`.
    Sees a moved sentence or paragraph; blind to reordering inside the tolerance and to words that occur
    early in the passage for another reason."""
    spoken_first = first_positions(content_stems(spoken))
    typed_first = first_positions(content_stems(typed))
    shared = sorted((typed_first[w], spoken_first[w]) for w in typed_first if w in spoken_first)
    sequence = [position for _, position in shared]
    best = []
    for i, value in enumerate(sequence):
        best.append(1 + max([best[j] for j in range(i) if sequence[j] <= value + tolerance], default=0))
    in_order = max(best, default=0)
    share = 1 - in_order / len(sequence) if sequence else 0.0
    return result(share <= max_out_of_order, out_of_order=round(share, 3), compared=len(sequence))


# ---- fillers and repeats left --------------------------------------------------------------------

def check_fillers(typed):
    """Hesitation fillers, immediately repeated words, truncated fragments ("th-") and interruption
    dashes still in the typed text. Blind to "like" and "you know" used as fillers."""
    tokens = re.findall(r"[a-z0-9']+(?:-[a-z0-9']+)*", typed.lower().replace("’", "'"))
    fillers = sorted({w for w in tokens if w in HESITATIONS})
    repeats = sorted({a for a, b in zip(tokens, tokens[1:]) if a == b and a not in ALLOWED_REPEATS
                      and not a.isdigit()})
    fragments = re.findall(r"\b\w+-(?=\s|$)", typed)
    dashes = len(re.findall(r"(?:^|\s)-{1,2}(?:\s|$)", typed))
    return result(not (fillers or repeats or fragments or dashes), fillers=fillers, repeats=repeats,
                  fragments=fragments, dashes=dashes)


# ---- corrections ---------------------------------------------------------------------------------

def check_corrections_grounded(spoken, corrections):
    """Each correction the writer reports quotes words that are in the spoken text, in that order.
    Catches an invented correction; cannot tell whether a real one was resolved the right way."""
    spoken_words = words(spoken)
    text = " ".join(spoken_words)
    bad = [c["said_first"] for c in corrections
           if not words(c["said_first"]) or " ".join(words(c["said_first"])) not in text
           or not words(c["ended_on"]) or " ".join(words(c["ended_on"])) not in text]
    return result(not bad, ungrounded=bad)


def _layer_leftover(spoken, typed, taken_back):
    """Single words the AMI layer marks as taken back that survive into the typed text (report only)."""
    removed = _removed_counter([], taken_back)
    spoken_counts = Counter(words(spoken))
    typed_vocab = set(words(typed))
    return sorted(w for w, count in removed.items()
                  if count > 0 and w not in CLOSED_CLASS and w not in HESITATIONS and len(w) > 2
                  and spoken_counts[w] - count <= 0 and w in typed_vocab)


def _contains_in_place(sequence, phrase):
    n = len(phrase)
    return any(sequence[i:i + n] == phrase for i in range(len(sequence) - n + 1))


def _outside_span(spoken_stems, said_stems):
    """The stems said anywhere except in the first place `said_stems` occurs in the speech."""
    n = len(said_stems)
    for i in range(len(spoken_stems) - n + 1):
        if spoken_stems[i:i + n] == said_stems:
            return spoken_stems[:i] + spoken_stems[i + n:]
    return spoken_stems


def check_taken_back_residue(spoken, typed, corrections, taken_back=()):
    """For each correction the writer reported, the words the speaker took back must not survive in place: the
    content words of `said_first` that `ended_on` does not repeat, taken as one contiguous phrase (fragments
    and fillers left out), must not appear as a run of content words in the typed text. A taken-back phrase of
    one word is held against the typed text only when the speaker does not say that word anywhere else in the
    speech (before or after the correction: "prices" said earlier justifies "prices" in the typed text). Blind to a phrase reordered into pieces, and to taking-back the writer did not report. (The
    AMI layer's words are judged by `run_report_only`, never here.)"""
    typed_stems = content_stems(typed)
    spoken_stems = content_stems(spoken)
    leftover = []
    for item in corrections:
        said = [t for t in item["said_first"].split() if not re.search(r"\w-$", t)]
        said_stems = content_stems(" ".join(said))
        kept = set(content_stems(item["ended_on"]))
        phrase = [w for w in said_stems if w not in kept]
        if not phrase or len(" ".join(phrase)) <= 2:
            continue
        if len(phrase) == 1 and phrase[0] in _outside_span(spoken_stems, said_stems):
            continue
        if _contains_in_place(typed_stems, phrase):
            leftover.append(" ".join(phrase))
    return result(not leftover, leftover=sorted(set(leftover)))


CHECK_NAMES = ("numbers", "dates", "names", "negation", "content_words_added", "function_words_added", "length",
               "order", "fillers", "corrections_grounded", "taken_back_residue")
REPORT_ONLY_NAMES = ("layer_taken_back_residue", "mixed_number_style")


def run_checks(spoken, typed, corrections=(), taken_back=(), band=LENGTH_BAND, max_added=DEFAULT_MAX_ADDED_WORDS,
               function_tolerance=DEFAULT_FUNCTION_TOLERANCE_PER100):
    """{check name: {"ok": bool, ...detail}} for one written row. Never merged into one score. These are the
    checks that can quarantine a row. `taken_back` (the AMI disfluency layer's words) only excuses spoken
    numbers, dates, names and negations from having to survive; whether those words were left in the typed
    text is reported by `run_report_only`, not decided here."""
    corrections, taken_back = list(corrections), [w for w in taken_back if w]
    heard = prep_spoken(spoken)
    return {
        "numbers": check_numbers(heard, typed, corrections, taken_back),
        "dates": check_dates(heard, typed, corrections, taken_back),
        "names": check_names(heard, typed, corrections, taken_back),
        "negation": check_negation(heard, typed, corrections, taken_back),
        "content_words_added": wordchecks.check_content_words_added(spoken, typed, max_added),
        "function_words_added": wordchecks.check_function_words_added(spoken, typed, function_tolerance),
        "length": check_length(spoken, typed, band),
        "order": check_order(heard, typed),
        "fillers": check_fillers(typed),
        "corrections_grounded": check_corrections_grounded(spoken, corrections),
        "taken_back_residue": check_taken_back_residue(heard, typed, corrections, []),
    }


def run_report_only(spoken, typed, taken_back=()):
    """Findings that are recorded but never quarantine a row: AMI-layer taken-back words that survive into the
    typed text (the layer marks some words that were plainly kept), and mixed number style in a sentence."""
    heard = prep_spoken(spoken)
    layer = _layer_leftover(heard, typed, [w for w in taken_back if w])
    return {"layer_taken_back_residue": result(not layer, leftover=layer),
            "mixed_number_style": wordchecks.mixed_number_style(typed)}


def failed(checks):
    return [name for name in CHECK_NAMES if name in checks and not checks[name]["ok"]]


def noted(report_only):
    return [name for name in REPORT_ONLY_NAMES if name in report_only and not report_only[name]["ok"]]
