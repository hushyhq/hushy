"""Surface features of a mined passage: fillers, explicit self-corrections, numbers, dates, names,
meeting-addressing cues, and personal-data flags. Everything here is a cheap lexical heuristic; the
module docstrings of each function say what it can miss. Counts only, never the matched text, except
for `person_names_in`, which the select step needs for masking."""

from __future__ import annotations

import re

HESITATIONS = frozenset("um uh uhm umm er erm eh ah hm hmm mm mmm".split())
BACKCHANNELS = frozenset("""yeah yes yep yup no okay ok right sure mm-hmm uh-huh mm hmm mhm uh-uh
    alright good great fine true exactly really oh wow cool nice absolutely definitely indeed""".split())
DIGIT_WORDS = frozenset("zero oh one two three four five six seven eight nine".split())
NUMBER_WORDS = frozenset("""two three four five six seven eight nine ten eleven twelve thirteen fourteen
    fifteen sixteen seventeen eighteen nineteen twenty thirty forty fifty sixty seventy eighty ninety
    hundred thousand million billion percent""".split())
MONTHS = frozenset("""january february march april june july august september october november december
    jan feb mar apr jun jul aug sep sept oct nov dec""".split())
WEEKDAYS = frozenset("monday tuesday wednesday thursday friday saturday sunday".split())
SECOND_PERSON = frozenset("you your you're you'll you've you'd yours yourself guys everybody everyone".split())
FIRST_PERSON = frozenset("i i'm i'll i've i'd my me mine myself".split())
SENTENCE_END = re.compile(r"[.?!]$")

SELF_CORRECTION_CUES = (
    r"\bno,? wait\b", r"\bsorry,? (?:i mean|no|it(?:'s| is| was))\b", r"\bor rather\b", r"\bi meant\b",
    r"\bscratch that\b", r"\bactually,? no\b", r"\bno,? i mean\b", r"\bno,? no,? (?:i|it|that|we|the)\b",
    r"\bcorrection\b", r"\bor sorry\b", r"\blet me rephrase\b", r"\bwhat i meant\b", r"\bno,? sorry\b",
    r"\bnot \w+,? (?:but|rather)\b", r"\bthat is,? no\b")
SELF_CORRECTION = re.compile("|".join(SELF_CORRECTION_CUES), re.I)

PHONE_DIGITS = re.compile(r"(?<!\d)(?:\+?\d[\d ()-]{6,}\d)(?!\d)")
EMAIL = re.compile(r"@|\bat\b[^.?!]{0,30}\bdot (?:com|org|edu|net|co|uk)\b|\be-?mail address\b", re.I)
ADDRESS = re.compile(r"\b(?:street|avenue|boulevard|postcode|post code|zip code|apartment|flat number|"
                     r"my address|home address|house number)\b", re.I)
PHONE_WORDS = re.compile(r"\b(?:phone number|telephone number|mobile number|cell number|my number is|"
                         r"call me on|extension number)\b", re.I)
HEALTH = re.compile(r"\b(?:doctor|hospital|surgery|surgeon|illness|cancer|pregnan\w+|medication|"
                    r"medicine|diagnos\w+|injur\w+|infection|chemotherapy|therapy|therapist|depress\w+|"
                    r"allerg\w+|disease|dentist|asthma|diabet\w+|migraine|headache|my (?:knee|back|leg|"
                    r"arm|ankle|shoulder)|i(?:'m| am) (?:sick|ill|unwell)|funeral|died|passed away)\b", re.I)
MONEY_PERSONAL = re.compile(r"\b(?:my (?:salary|rent|mortgage|bank|account|savings|debt|pay|wages|"
                            r"credit card|loan|tax|bills?)|credit card|mortgage|bank account|"
                            r"i owe|owe (?:him|her|them|you)|student loan)\b", re.I)

INVENTED_NAMES = ("Alder", "Bryn", "Calla", "Dorian", "Elowen", "Fenn", "Garrick", "Hollis", "Ines",
                  "Jory", "Kestrel", "Lenka", "Marlow", "Nell", "Orrin", "Perrin", "Quill", "Rhea",
                  "Soren", "Tamsin")


def norm(token):
    """Lower-cased word with edge punctuation removed; inner apostrophes and hyphens kept."""
    return re.sub(r"^[^\w]+|[^\w]+$", "", token.lower().replace("’", "'"))


def words_of(text):
    return [w for w in (norm(t) for t in text.split()) if w]


def count_pattern(pattern, text):
    return len(pattern.findall(text))


def filler_counts(tokens):
    """(hesitation count, 'you know'/'I mean' count, immediate repetition count, fragment count)."""
    words = [norm(t) for t in tokens]
    hesitations = sum(1 for w in words if w in HESITATIONS)
    markers = sum(1 for a, b in zip(words, words[1:]) if (a, b) in (("you", "know"), ("i", "mean")))
    repeats = sum(1 for a, b in zip(words, words[1:]) if a and a == b and a not in HESITATIONS)
    fragments = sum(1 for t in tokens if re.search(r"\w-$", t))
    return hesitations, markers, repeats, fragments


def number_hits(words, raw_tokens):
    digits = sum(1 for t in raw_tokens if re.search(r"\d", t))
    spoken = sum(1 for w in words if w in NUMBER_WORDS)
    return digits + spoken


def date_hits(words, raw_tokens):
    named = 0
    for token in raw_tokens:
        w = norm(token)
        if w in WEEKDAYS or (w in MONTHS and (token[:1].isupper() or w not in ("may", "march"))):
            named += 1
    years = sum(1 for t in raw_tokens if re.fullmatch(r"(?:19|20)\d\d[.,?!]?", t))
    clock = sum(1 for a, b in zip(words, words[1:]) if b in ("o'clock", "pm", "am") or a == "o'clock")
    return named + years + clock


VALUE_CUES = frozenset("no sorry wait rather actually mean".split())


def numeric_correction(words):
    """Cue word (no, sorry, wait, rather, actually, mean) with a number, weekday or month within three
    words on each side: the shape of 'tuesday no wait wednesday'. A cheap cue, not proof of a correction."""
    def valued(w):
        return w in NUMBER_WORDS or w in WEEKDAYS or w in MONTHS or w.isdigit()
    hits, last = 0, -10
    for i, w in enumerate(words):
        if w in VALUE_CUES and i - last > 2 and any(valued(x) for x in words[max(0, i - 3):i]) \
                and any(valued(x) for x in words[i + 1:i + 4]):
            hits += 1
            last = i
    return hits


def proper_nouns_in(raw_tokens, proper):
    """Tokens that the corpus-wide capitalisation statistics say are proper nouns (not weekdays or months)."""
    found = []
    for token in raw_tokens:
        w = norm(token)
        if w in proper and w not in WEEKDAYS and w not in MONTHS:
            found.append(w)
    return found


def personal_data(text, person_names, raw_tokens):
    """Counts of personal-data cues. `person_names` is the corpus-derived lexicon of first-name-like
    proper nouns (used in greetings, thanks and introductions)."""
    words = words_of(text)
    spoken_digits = 0
    run = 0
    for w in words:
        run = run + 1 if w in DIGIT_WORDS else 0
        if run == 7:
            spoken_digits += 1
    return {"person_name": sum(1 for w in words if w in person_names),
            "phone": count_pattern(PHONE_DIGITS, text) + count_pattern(PHONE_WORDS, text) + spoken_digits,
            "email": count_pattern(EMAIL, text), "address": count_pattern(ADDRESS, text),
            "health": count_pattern(HEALTH, text), "money_personal": count_pattern(MONEY_PERSONAL, text)}


def person_names_in(text, person_names):
    return sorted({w for w in words_of(text) if w in person_names})


def addressing_cues(words, text):
    """Per-100-word rates of second-person words and question marks, the meeting-talk tells."""
    n = max(1, len(words))
    return {"you_per100": round(100 * sum(1 for w in words if w in SECOND_PERSON) / n, 2),
            "questions_per100": round(100 * text.count("?") / n, 2),
            "first_person_per100": round(100 * sum(1 for w in words if w in FIRST_PERSON) / n, 2)}


def monologue_score(cues, intrusion_words, overlap_fraction):
    """A 0..1 heuristic: higher is closer to one person talking alone. Not validated against anything."""
    penalty = (cues["you_per100"] / 10 + cues["questions_per100"] / 3 + intrusion_words / 20
               + 3 * overlap_fraction)
    return round(max(0.0, 1.0 - penalty), 3)


def passage_features(tokens, text, proper, person_names):
    words = [w for w in (norm(t) for t in tokens) if w]
    hes, markers, repeats, frags = filler_counts(tokens)
    n = max(1, len(words))
    proper_hits = proper_nouns_in(tokens, proper)
    return {
        "hesitations": hes, "you_know_i_mean": markers, "repeats": repeats, "fragments": frags,
        "filler_per100": round(100 * hes / n, 2),
        "explicit_self_correction": count_pattern(SELF_CORRECTION, text),
        "numeric_correction_cue": numeric_correction(words),
        "i_mean": sum(1 for a, b in zip(words, words[1:]) if (a, b) == ("i", "mean")),
        "numbers": number_hits(words, tokens), "dates": date_hits(words, tokens),
        "names": len(proper_hits), "cues": addressing_cues(words, text),
        "pii": personal_data(text, person_names, tokens)}


def mask_names(text, person_names, seed_key):
    """Replaces each distinct first-name-like word with an invented name, consistently within `text`."""
    mapping = {}

    def swap(match):
        word = match.group(0)
        key = word.lower()
        if key not in person_names:
            return word
        if key not in mapping:
            index = (sum(ord(c) for c in key + seed_key) + len(mapping)) % len(INVENTED_NAMES)
            mapping[key] = INVENTED_NAMES[index]
        return mapping[key]
    return re.sub(r"[A-Za-z][A-Za-z'’-]*", swap, text)


NOT_PERSON = frozenset("""ami x mister europe mitre absinthe english german italian spanish french chinese american
    british european african asian indian canadian australian dutch swiss""".split()) | MONTHS | WEEKDAYS
VOCATIVE_OPENERS = frozenset("""thanks thank hi hey hello sorry cheers bye morning afternoon evening dear ask tell
    told call called named""".split())
INTRO_PRECEDERS = frozenset(("name", "i'm", "this", "my", "that", "who", ""))


def derive_lexicons(passage_token_lists, min_count=3, ratio=0.8):
    """(proper nouns, first-name-like words) from capitalisation statistics over `passage_token_lists`
    (an iterable of token lists, each token as written).

    proper: mid-sentence capitalisation (not all caps) at least `ratio` of the time over at least
    `min_count` mid-sentence uses. names: proper nouns used at least twice as a vocative or
    self-introduction ('thanks X', 'hi X', "I'm X", 'my name is X', 'X, can you ...'). Names that are only
    ever mentioned in other ways are missed: the name flag is a lower bound, not a guarantee."""
    cap, low, vocative = {}, {}, {}
    for tokens in passage_token_lists:
        prev = prev2 = ""
        for i, token in enumerate(tokens):
            w = norm(token)
            if re.fullmatch(r"[a-z']+", w):
                sentence_start = i == 0 or SENTENCE_END.search(prev) or prev == "-"
                acronym = token.rstrip(",.?!").isupper() and len(w) > 1
                if not sentence_start and w not in ("i", "i'm", "i'll", "i've", "i'd"):
                    if token[:1].isupper() and not acronym:
                        cap[w] = cap.get(w, 0) + 1
                        before = norm(prev)
                        if before in VOCATIVE_OPENERS or (before in ("is", "i'm") and norm(prev2) in INTRO_PRECEDERS):
                            vocative[w] = vocative.get(w, 0) + 1
                    elif not token[:1].isupper():
                        low[w] = low.get(w, 0) + 1
                elif sentence_start and token[:1].isupper() and token.endswith(",") and not acronym and len(w) > 2:
                    vocative[w] = vocative.get(w, 0) + 1
            prev2, prev = prev, token
    proper = {w for w, n in cap.items()
              if n >= min_count and n / (n + low.get(w, 0)) >= ratio and w not in ("okay", "ok")}
    names = {w for w in proper | {w for w in cap if cap[w] >= 2}
             if vocative.get(w, 0) >= 2 and cap.get(w, 0) / (cap.get(w, 0) + low.get(w, 0)) >= 0.7
             and w not in NOT_PERSON}
    return proper, names
