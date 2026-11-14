"""Checks on the words a writer used: content words added, function words added, and (report only) mixed
number style. Each is a cheap lexical test; the docstrings say what it cannot see."""

from __future__ import annotations

import re
from collections import Counter

import retrain_numbers as numbers
from retrain_lexicon import (EQUIVALENT_STEMS, FUNCTION_WORDS, HESITATIONS, MODALS, SUBJECTS, content_stems,
                             expand_sequence, grammar_forms, prep_spoken, result, spoken_vocabulary, stem, words)

DEFAULT_MAX_ADDED_WORDS = 0
# Added function words per 100 typed words before the check fails. Set from the first live batch (20 rows, all
# read as faithful): their rates ran 0 to 6.5 because splitting run-ons and repairing grammar adds "and", "it",
# "of" and the like. 7.0 is therefore a loose net for gross additions; the added subject-plus-modal test below
# is the sharper tool. Tighten it when more batches have been read.
DEFAULT_FUNCTION_TOLERANCE_PER100 = 7.0
FAMILY_MIN_PREFIX = 4
FAMILY_PREFIX_SHARE = 0.75
FAMILY_MAX_EDIT = 2


def edit_distance(a, b):
    previous = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        current = [i]
        for j, cb in enumerate(b, 1):
            current.append(min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (ca != cb)))
        previous = current
    return previous[-1]


def common_prefix(a, b):
    n = 0
    for x, y in zip(a, b):
        if x != y:
            break
        n += 1
    return n


def same_family(a, b):
    """True when two stems are one word in another form: a shared stem ("high"/"highly",
    "technological"/"technologically"), a one-or-two-letter spelling variant ("spongy"/"spongey"), or a
    pair a grammar repair swaps ("less"/"fewer")."""
    if a == b or (a, b) in EQUIVALENT_STEMS or (b, a) in EQUIVALENT_STEMS:
        return True
    shortest = min(len(a), len(b))
    if shortest >= FAMILY_MIN_PREFIX and common_prefix(a, b) >= max(FAMILY_MIN_PREFIX, FAMILY_PREFIX_SHARE * shortest):
        return True
    return max(len(a), len(b)) >= 5 and edit_distance(a, b) <= FAMILY_MAX_EDIT


def compound_stems(spoken):
    """Stems of two neighbouring spoken words written as one ("wide screen" typed as "widescreen")."""
    heard = words(prep_spoken(spoken))
    joined = {stem(a + b) for a, b in zip(heard, heard[1:])}
    run = ""  # spelled-out letters typed as one word: "x l s x" -> "xlsx"
    for word in heard + [""]:
        if len(word) == 1 and word.isalpha():
            run += word
        else:
            if len(run) > 1:
                joined.add(stem(run))
            run = ""
    # a word and a digit word typed as one token: "v two" -> "v2", "co two" -> "co2"
    return joined | {stem(a + str(numbers.UNITS[b])) for a, b in zip(heard, heard[1:]) if b in numbers.UNITS and b != a}


def check_content_words_added(spoken, typed, max_added=DEFAULT_MAX_ADDED_WORDS):
    """Content words in the typed text that no spoken word accounts for. A typed word is accounted for when it
    shares a stem with a spoken word or is a near relative of one (same word family, spelling variant, a
    swap such as less/fewer, or two spoken words written as one); those are listed under `related`, not counted. Function words are the other
    check's business. Blind to an added content word that happens to be a relative of a spoken one."""
    vocabulary = spoken_vocabulary(spoken)
    vocabulary |= compound_stems(spoken)
    added, related = [], []
    typed_numbers = {stem(w) for w in words(typed) if numbers.is_number_word(w)}  # "four" for a spoken "4"
    for word in sorted(set(content_stems(typed)) - vocabulary - typed_numbers):
        (related if any(same_family(word, known) for known in vocabulary) else added).append(word)
    return result(len(added) <= max_added, added=added, related=related)


def function_counts(text):
    counts = Counter()
    for word in words(text):
        for form in grammar_forms(word):
            if form in FUNCTION_WORDS and form not in HESITATIONS:
                counts[form] += 1
    return counts


def sentence_starts(text):
    """The first two (expanded) words of every sentence and paragraph."""
    starts = []
    for piece in re.split(r"(?<=[.?!])\s+|\n+", text.strip()):
        flat = [x for w in words(piece)[:2] for x in expand_sequence(w)]
        if flat:
            starts.append(flat[:2])
    return starts


def spoken_bigrams(spoken):
    flat = [x for w in words(spoken) for x in expand_sequence(w)]
    return set(zip(flat, flat[1:]))


def check_function_words_added(spoken, typed, tolerance_per100=DEFAULT_FUNCTION_TOLERANCE_PER100):
    """Function words (articles, pronouns, auxiliaries, prepositions, connectives, common adverbs) the typed
    text has more of than the spoken text, per word, as a rate per 100 typed words; over the tolerance fails.
    Also fails on an added subject plus modal at a sentence start ("We could ...") whose two words are never
    adjacent in the speech, which the counts cannot see when both words occur elsewhere. Blind to an added
    subject or modal that is adjacent somewhere else in the passage, and to added words inside a sentence."""
    heard = prep_spoken(spoken)
    said, wrote = function_counts(heard), function_counts(typed)
    surplus = {w: wrote[w] - said[w] for w in wrote if wrote[w] > said[w]}
    typed_n = max(1, len(words(typed)))
    rate = round(100 * sum(surplus.values()) / typed_n, 2)
    known = spoken_bigrams(heard)
    supplied = sorted({" ".join(pair) for pair in (tuple(s) for s in sentence_starts(typed)
                                                    if len(s) == 2) if pair[0] in SUBJECTS and pair[1] in MODALS
                       and pair not in known})
    return result(rate <= tolerance_per100 and not supplied, per100=rate, tolerance_per100=tolerance_per100,
                  surplus=dict(sorted(surplus.items())), supplied_subject_modal=supplied)


NUMBER_WORDS_FOR_STYLE = frozenset(w for w in numbers.UNITS if w not in ("zero", "one")) | set(numbers.TENS)


def mixed_number_style(typed):
    """Report only. Sentences where one kind of quantity is written both spelled out and as digits ("five
    minutes ... 30 minutes"): the noun after the number is the kind. Sees adjacent "number noun" pairs only."""
    mixed = []
    for sentence in re.split(r"(?<=[.?!])\s+|\n+", typed):
        styles = {}
        tokens = re.findall(r"[\w'%$.,-]+", sentence.lower())
        for token, following in zip(tokens, tokens[1:]):
            bare = token.strip(".,-")
            noun = re.sub(r"[^\w]", "", following)
            if not noun or noun in FUNCTION_WORDS:
                continue
            if re.fullmatch(r"[\d][\d,.]*", bare):
                styles.setdefault(numbers_stem(noun), set()).add("digits")
            elif bare in NUMBER_WORDS_FOR_STYLE:
                styles.setdefault(numbers_stem(noun), set()).add("words")
        mixed += sorted(noun for noun, kinds in styles.items() if len(kinds) == 2)
    return result(not mixed, kinds=mixed)


def numbers_stem(noun):
    return noun[:-1] if noun.endswith("s") and len(noun) > 3 else noun
