"""Word lists and text helpers shared by the checks: tokenising, a crude stemmer, contraction and
spoken-reduction expansion, and the spoken text with what the speaker abandoned taken out."""

from __future__ import annotations

import re

import retrain_numbers as numbers


HESITATIONS = frozenset("um uh uhm umm er erm eh ah hm hmm mm mmm".split())
WEEKDAYS = frozenset("monday tuesday wednesday thursday friday saturday sunday".split())
MONTHS = frozenset("""january february march april june july august september october november december
    jan feb mar apr jun jul aug sep sept oct nov dec""".split())  # "may" is also a verb: not tracked
NEGATIONS = frozenset("not never nothing nobody none neither nor cannot nowhere".split())
# informal spoken negations that a writer expands to "do not know", "can not" and so on
INFORMAL_NEGATIONS = frozenset("""dunno nah dont cant wont didnt doesnt isnt wasnt werent arent wouldnt couldnt
    shouldnt hasnt havent hadnt aint""".split())
DISCOURSE_AFTER_NO = frozenset("wait sorry no yeah i actually".split())
CLOSED_CLASS = frozenset("""a an the and or but so because although though while if then than as of to in on at for with
    by from about into over under between through after before during up down out off i me my mine we us our
    ours you your yours he him his she her hers it its they them their theirs this that these those who whom
    which what whose there here be is am are was were been being do does did done have has had having will
    would can could shall should may might must not no all any some""".split())
EXPANSIONS = {"gonna": ("going", "to"), "wanna": ("want", "to"), "gotta": ("got", "to"),
              "kinda": ("kind", "of"), "sorta": ("sort", "of"), "cause": ("because",), "cuz": ("because",),
              "lemme": ("let", "me"), "gimme": ("give", "me"), "dunno": ("do", "not", "know"),
              "ya": ("you",), "yeah": ("yes",), "yep": ("yes",), "nope": ("no",), "ok": ("okay",),
              "okay": ("ok",), "alright": ("all", "right"), "til": ("until",), "'til": ("until",),
              "outta": ("out", "of"), "coulda": ("could", "have"), "woulda": ("would", "have"),
              "shoulda": ("should", "have")}
# Function words beyond the closed class: connectives and adverbs a writer may use to join or repair a
# sentence without adding anything the speaker said. Counted by the function-word check, not the content check.
FUNCTION_EXTRA = frozenset("""where when how why now only still even yet already always often again once ever
    however therefore thus too very just also such both either each every other another own same much many
    more most few less least rather quite really actually well whether none nothing nobody never neither nor
    anything something everything anyone someone everyone somebody anybody everybody non anti semi multi pre
    maybe perhaps""".split())
# A currency written as its symbol ($, €, £) is not a missing name when the speaker said "Euros" or "Dollars".
CURRENCY_WORDS = frozenset("""euro euros dollar dollars pound pounds cent cents yen pence penny""".split())
FUNCTION_WORDS = CLOSED_CLASS | FUNCTION_EXTRA
SUBJECTS = frozenset("i we you they he she it there".split())
MODALS = frozenset("could would should can will may might must shall".split())
# Pairs a writer may swap as grammar repair; compared on stems, both directions.
EQUIVALENT_STEMS = frozenset({("fewer", "less"), ("many", "much"), ("further", "farther"), ("amount", "number")})
DISCOURSE_CAPITALS = frozenset("""okay ok oh yeah well so and but um uh right yes no alright hmm mm anyway actually
    now then sorry i i'm i'll i've i'd mm-hmm uh-huh like because""".split())
WORD = re.compile(r"[a-z0-9]+(?:'[a-z]+)?")


def words(text):
    return WORD.findall(text.lower().replace("’", "'").replace("-", " "))


def stem(word):
    word = word.strip("'")
    for suffix in ("'s", "s'"):
        if word.endswith(suffix):
            word = word[:-len(suffix)]
    if len(word) > 4 and word.endswith("ies"):
        word = word[:-3] + "y"
    elif len(word) > 5 and word.endswith("ing"):
        word = word[:-3]
    elif len(word) > 3 and word.endswith("ed"):
        word = word[:-2]
    elif len(word) > 3 and word.endswith("es"):
        word = word[:-2]
    elif len(word) > 3 and word.endswith("s") and not word.endswith("ss"):
        word = word[:-1]
    if len(word) > 3 and word.endswith("e"):
        word = word[:-1]
    if len(word) > 3 and word[-1] == word[-2] and word[-1] not in "ls":
        word = word[:-1]
    return word


SPECIAL_CONTRACTIONS = {"can't": ("can", "not"), "cannot": ("can", "not"), "won't": ("will", "not"),
                        "shan't": ("shall", "not"), "ain't": ("is", "not")}
CONTRACTION_PARTS = (("n't", ("not",)), ("'re", ("are",)), ("'ve", ("have",)), ("'ll", ("will",)),
                     ("'d", ("would", "had")), ("'m", ("am",)), ("'s", ("is", "has")))


def grammar_forms(word):
    """What a word counts as: a contraction is its pieces ("don't" is do + not, "it's" is it + is/has),
    a spoken reduction its expansion ("gonna" is going + to), anything else itself."""
    if word in SPECIAL_CONTRACTIONS:
        return set(SPECIAL_CONTRACTIONS[word])
    for contraction, parts in CONTRACTION_PARTS:
        if word.endswith(contraction) and len(word) > len(contraction):
            return {word[:-len(contraction)], *parts}
    return {word, *EXPANSIONS.get(word, ())}


def expand_sequence(word):
    """An ordered expansion, for adjacency tests: "we'll" is we will, "gonna" is going to."""
    if word in SPECIAL_CONTRACTIONS:
        return list(SPECIAL_CONTRACTIONS[word])
    for contraction, parts in CONTRACTION_PARTS:
        if word.endswith(contraction) and len(word) > len(contraction):
            return [word[:-len(contraction)], parts[0]]
    return list(EXPANSIONS.get(word, (word,)))


def content_stems(text):
    """Stems of the words that are not grammar words, in order."""
    out = []
    for word in words(text):
        if word[0].isdigit():
            continue
        for form in grammar_forms(word):
            if form not in FUNCTION_WORDS and not form[0].isdigit() and form not in HESITATIONS:
                out.append(stem(form))
    return out


def spoken_vocabulary(spoken):
    vocab = set()
    for word in words(spoken):
        for form in grammar_forms(word):
            vocab.add(stem(form))
    return vocab


def prep_spoken(spoken):
    """The spoken text without what the speaker abandoned or hesitated over: hesitation fillers, truncated
    fragments ("minut-") and lone interruption dashes. A tens fragment right before a unit ("thirty- two") is
    kept as the number it spells. Every "required" and "present" test reads this, so a number split by a
    filler ("seventy uh five") or cut off ("ten-") is read the way a listener would."""
    tokens = spoken.split()
    kept = []
    for i, token in enumerate(tokens):
        bare = re.sub(r"[^\w'-]", "", token.lower())
        if bare in ("-", "--") and kept and not kept[-1].endswith((".", "?", "!")):
            kept[-1] += "."  # an interrupted utterance ends a sentence for the capitalisation tests
            continue
        if bare in HESITATIONS or bare in ("-", "--", ""):
            continue
        if bare.endswith("-") and len(bare) > 1:
            following = re.sub(r"[^\w']", "", tokens[i + 1].lower()) if i + 1 < len(tokens) else ""
            if bare[:-1] in numbers.TENS and following in numbers.UNITS and numbers.UNITS[following] < 10:
                kept.append(bare[:-1])
            continue
        kept.append(token)
    return " ".join(kept)


def result(ok, **detail):
    return {"ok": bool(ok), **detail}
