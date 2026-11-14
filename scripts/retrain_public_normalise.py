#!/usr/bin/env python3
"""The canonical word stream the public scorer compares: number words and digit forms meet in it.

Both sides of a comparison go through `normalize`, which never decides what a number "means".
Every number becomes its digits, one token per digit, so "twenty twenty four" and "2024" are both
2 0 2 4, "three oh five" and "3:05" are both 3 0 5, and "fifty fifty" is 5 0 5 0 (two numbers side
by side are never added together). Number words are only composed where English grammar does it:

- tens and units ("seventy five" is 75), "hundred" with what follows ("three hundred five",
  "one hundred and five") and the scale words ("one thousand two hundred", "one million");
- "and" joins only the last part of one number, never two numbers: "between twenty and thirty"
  and "one hundred and five hundred" keep their "and";
- "a hundred", "a thousand", "a million" count as one of them; a digit before a scale word is
  multiplied ("5 million"), a decimal is not ("2.5 million" stays 2 point 5 million);
- "oh" is a zero only between a number and a unit ("three oh five"), "a m" and "p m" join only
  after a number, "$100" reads "100 dollars" and "75%" reads "75 percent".

Ordinals are words on both sides: "1st" is spelled out as "first" and "21st" as "twenty first"
(up to "99th"), so "second" is never taken for a number and "wait one second" stays as it is.

Out of scope, and left unequal: a bare hour against a clock time ("ten" and "10:00"), ordinals
from "100th" up, and a decimal against the same amount in full ("2.5 million", "2,500,000")."""

import re

import retrain_numbers as numbers

UNITS, TENS = numbers.UNITS, numbers.TENS
SCALES = {"thousand": 10 ** 3, "million": 10 ** 6, "billion": 10 ** 9, "trillion": 10 ** 12}
ORDINALS = ("zeroth first second third fourth fifth sixth seventh eighth ninth tenth eleventh twelfth thirteenth "
            "fourteenth fifteenth sixteenth seventeenth eighteenth nineteenth").split()
ORDINAL_TENS = dict(zip(range(20, 100, 10),
                        "twentieth thirtieth fortieth fiftieth sixtieth seventieth eightieth ninetieth".split()))
TENS_WORDS = {value: word for word, value in TENS.items()}
CURRENCIES = {"$": "dollars", "€": "euros", "£": "pounds"}
# Spellings of one word, as token runs: the first form found is replaced by the second.
VARIANTS = {("e", "mail"): "email", ("per", "cent"): "percent", ("ok",): "okay", ("dollar",): "dollars",
            ("euro",): "euros", ("pound",): "pounds"}
THOUSANDS_COMMA = re.compile(r"(?<=\d),(?=\d{3}(?!\d))")
MONEY = re.compile(r"([$€£])\s?(\d+(?:\.\d+)?)(\s+(?:hundred|thousand|million|billion|trillion)\b)?")
ORDINAL_DIGITS = re.compile(r"\b(\d+)(?:st|nd|rd|th)\b")
TOKEN = re.compile(r"\d+(?:\.\d+)?|[^\W\d_]+(?:'[^\W\d_]+)?")


def _ordinal_words(match):
    value = int(match[1])
    if value < 20:
        return ORDINALS[value]
    if value >= 100:
        return match[0]
    if value % 10 == 0:
        return ORDINAL_TENS[value]
    return f"{TENS_WORDS[value - value % 10]} {ORDINALS[value % 10]}"


def lexical(text):
    """Lower-case tokens: words, whole numbers and decimals, with signs and digit ordinals spelled out."""
    text = text.casefold().replace("’", "'")
    text = THOUSANDS_COMMA.sub("", text)
    text = MONEY.sub(lambda match: f"{match[2]}{match[3] or ''} {CURRENCIES[match[1]]} ", text)
    text = text.replace("%", " percent ")
    text = ORDINAL_DIGITS.sub(_ordinal_words, text)
    return TOKEN.findall(text)


def _at(tokens, index):
    return tokens[index] if 0 <= index < len(tokens) else None


def _under_hundred(tokens, i):
    """(value, next index) for "forty two", "forty", "seventeen" or "six" at i, else None."""
    word = _at(tokens, i)
    if word in TENS:
        unit = UNITS.get(_at(tokens, i + 1), 0)
        return (TENS[word] + unit, i + 2) if 1 <= unit <= 9 else (TENS[word], i + 1)
    return (UNITS[word], i + 1) if word in UNITS else None


def _starts_new_number(tokens, i, joined_by_and):
    """True when the word after a closing group shows that group began another number."""
    return _at(tokens, i) == "hundred" or (joined_by_and and _at(tokens, i) in SCALES)


def _under_thousand(tokens, i):
    """An under-hundred group, or "three hundred [and] five" / "a hundred" / "twelve hundred"."""
    a_hundred = _at(tokens, i) == "a" and _at(tokens, i + 1) == "hundred"
    head = (1, i + 1) if a_hundred else _under_hundred(tokens, i)
    if head is None or head[0] == 0 or _at(tokens, head[1]) != "hundred":
        return head
    value, j = head[0] * 100, head[1] + 1
    joined = _at(tokens, j) == "and"
    tail = _under_hundred(tokens, j + 1 if joined else j)
    if tail is None or _starts_new_number(tokens, tail[1], joined):
        return value, j
    return value + tail[0], tail[1]


def _group_after_scale(tokens, j):
    """The next part of a number after a scale word, optionally joined by "and"."""
    joined = _at(tokens, j) == "and"
    group = _under_thousand(tokens, j + 1 if joined else j)
    if group is None or (joined and (_at(tokens, group[1]) in SCALES or _at(tokens, group[1]) == "hundred")):
        return None
    return group


def cardinal(tokens, i):
    """(value, next index) for the number phrase starting at tokens[i], or None."""
    a_scale = _at(tokens, i) == "a" and _at(tokens, i + 1) in SCALES
    group = (1, i + 1) if a_scale else _under_thousand(tokens, i)
    total, ceiling, j = 0, None, i
    while group is not None:
        value, after = group
        scale = SCALES.get(_at(tokens, after))
        if scale is None:
            return total + value, after
        if ceiling is not None and scale >= ceiling:
            break  # "one thousand two thousand": the second is a new number
        total, ceiling, j = total + value * scale, scale, after + 1
        group = _group_after_scale(tokens, j)
    return (total, j) if j > i else None


def _digit_word(tokens, i):
    word = _at(tokens, i)
    if word == "oh":
        return "0"
    return str(UNITS[word]) if word in UNITS and UNITS[word] <= 9 else None


def _spoken_number(tokens, i):
    """Digit tokens for the number words at i, with "point five" decimals, or None."""
    found = cardinal(tokens, i)
    if found is None:
        return None
    pieces, j = list(str(found[0])), found[1]
    if _at(tokens, j) == "point" and _digit_word(tokens, j + 1) is not None:
        pieces.append("point")
        j += 1
        while _digit_word(tokens, j) is not None:
            pieces.append(_digit_word(tokens, j))
            j += 1
    return pieces, j


def _written_number(tokens, i):
    """Digit tokens for a digit form: a decimal, a whole number, or one before a scale word."""
    token = tokens[i]
    if "." in token:
        whole, fraction = token.split(".")
        return [*whole, "point", *fraction], i + 1
    scale = 100 if _at(tokens, i + 1) == "hundred" else SCALES.get(_at(tokens, i + 1))
    if scale and not token.startswith("0"):
        return list(str(int(token) * scale)), i + 2
    return list(token), i + 1


def _step(tokens, i, out):
    """The canonical tokens for what starts at tokens[i], and the index after it."""
    token = tokens[i]
    after_number = bool(out) and out[-1].isdigit()
    if token[0].isdigit():
        return _written_number(tokens, i)
    if after_number and token == "oh" and UNITS.get(_at(tokens, i + 1), 0) in range(1, 10):
        return ["0", str(UNITS[tokens[i + 1]])], i + 2
    if after_number and token in ("a", "p") and _at(tokens, i + 1) == "m":
        return [token + "m"], i + 2
    spoken = _spoken_number(tokens, i)
    if spoken is not None:
        return spoken
    for length in (2, 1):
        variant = VARIANTS.get(tuple(tokens[i:i + length]))
        if variant is not None:
            return [variant], i + length
    return [token], i + 1


def normalize(text):
    """The canonical token stream of `text`: words, with every number as one token per digit."""
    tokens, out, i = lexical(text), [], 0
    while i < len(tokens):
        pieces, i = _step(tokens, i, out)
        out.extend(pieces)
    return out


def group_numbers(tokens):
    """The stream with each run of digit tokens joined, so a number weighs one word in similarity.
    Equal streams give equal groupings and the reverse, so this never changes what is equal."""
    out = []
    for token in tokens:
        if token.isdigit() and out and out[-1].isdigit():
            out[-1] += token
        else:
            out.append(token)
    return out


def similarity_words(text):
    return group_numbers(normalize(text))
