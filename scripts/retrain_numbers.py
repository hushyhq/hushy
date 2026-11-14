"""Number values in text, whether written as digits or as English words, so a spoken "twenty five" and
a typed "25" compare equal. Handles digits with commas, "$", "%", ordinals ("27th", "twenty seventh"),
decimals ("three point five"), "forty two hundred" (4200), "a hundred", years ("nineteen ninety"),
colon times ("3:30" is 3 and 30) and runs of single digits ("three three six" is 3, 3, 6).

A lone "one" is returned as a number but marked weak: it is mostly a pronoun ("one of the things"), so
the "is it missing from the typed text" test ignores weak numbers while the "is it in the spoken text"
test accepts them."""

from __future__ import annotations

import re
from dataclasses import dataclass

UNITS = {w: i for i, w in enumerate(
    "zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen "
    "sixteen seventeen eighteen nineteen".split())}
TENS = {w: 10 * i for i, w in enumerate(
    "_ _ twenty thirty forty fifty sixty seventy eighty ninety".split()) if w != "_"}
SCALES = {"hundred": 100, "thousand": 1000, "million": 1_000_000, "billion": 1_000_000_000}
ORDINAL_WORDS = {"first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6, "seventh": 7,
                 "eighth": 8, "ninth": 9, "tenth": 10, "eleventh": 11, "twelfth": 12, "thirteenth": 13,
                 "fourteenth": 14, "fifteenth": 15, "sixteenth": 16, "seventeenth": 17, "eighteenth": 18,
                 "nineteenth": 19, "twentieth": 20, "thirtieth": 30, "fortieth": 40, "fiftieth": 50}
NUMBER_TOKEN = re.compile(r"\d[\d,]*(?:\.\d+)?(?:st|nd|rd|th)?|[a-z]+(?:'[a-z]+)?")


@dataclass(frozen=True)
class Number:
    value: float
    weak: bool = False  # a lone "one" or a bare ordinal word
    alternates: frozenset = frozenset()  # other readings of the same words (a year, digit by digit)


def tokenize(text):
    return NUMBER_TOKEN.findall(text.lower().replace("-", " ").replace("’", "'"))


def digits_value(token):
    token = re.sub(r"(st|nd|rd|th)$", "", token).replace(",", "")
    try:
        value = float(token)
    except ValueError:
        return None
    return int(value) if value.is_integer() else value


def is_number_word(word):
    return word in UNITS or word in TENS or word in SCALES or word in ORDINAL_WORDS


def parse_run(words):
    """Numbers in a run of consecutive number words, as a list of Number."""
    results, i = [], 0
    while i < len(words):
        word = words[i]
        if word in ORDINAL_WORDS:
            results.append(Number(ORDINAL_WORDS[word], weak=True))
            i += 1
            continue
        total, current, consumed, last_kind = 0, 0, 0, None
        j = i
        while j < len(words):
            w = words[j]
            if w == "and" and consumed and last_kind == "scale" and j + 1 < len(words) \
                    and (words[j + 1] in UNITS or words[j + 1] in TENS or words[j + 1] in ORDINAL_WORDS):
                j += 1
                continue
            if w in TENS and last_kind in (None, "scale"):
                current += TENS[w]; last_kind = "tens"
            elif w in UNITS and UNITS[w] >= 10 and last_kind in (None, "scale"):
                current += UNITS[w]; last_kind = "teen"
            elif w in UNITS and UNITS[w] < 10 and last_kind in (None, "tens", "scale") \
                    and not (UNITS[w] == 0 and last_kind):
                if last_kind == "tens" and w == "zero":
                    break
                current += UNITS[w]; last_kind = "unit"
            elif w in ORDINAL_WORDS and ((last_kind == "tens" and ORDINAL_WORDS[w] < 10) or last_kind == "scale"):
                current += ORDINAL_WORDS[w]; last_kind = "ordinal"
                consumed += 1
                j += 1
                break
            elif w in SCALES and (current or last_kind is None) and last_kind != "scale":
                factor = SCALES[w]
                if factor == 100:
                    current = (current or 1) * 100
                else:
                    total += (current or 1) * factor
                    current = 0
                last_kind = "scale"
            else:
                break
            consumed += 1
            j += 1
        if consumed == 0:
            i += 1
            continue
        span = words[i:j]
        value = total + current
        weak = len(span) == 1 and span[0] == "one"
        results.append(Number(value, weak=weak, alternates=_alternates(span, value)))
        i = j
    return _join_years(results)


def _join_years(results):
    """Two neighbouring numbers of 10-99 ('nineteen ninety', 'twenty twenty') may be one year."""
    joined = list(results)
    for k in range(len(joined) - 1):
        a, b = joined[k], joined[k + 1]
        if all(isinstance(x.value, int) and 10 <= x.value <= 99 and not x.weak for x in (a, b)):
            year = a.value * 100 + b.value
            joined[k] = Number(a.value, a.weak, a.alternates | {year})
            joined[k + 1] = Number(b.value, b.weak, b.alternates | {year})
    return joined


def _alternates(span, value):
    """Other readings: 'nineteen ninety' as 1990, 'twenty twenty' as 2020, single digits read out."""
    options = set()
    if len(span) == 3 and span[0] in UNITS and UNITS[span[0]] >= 10 and span[1] in TENS and span[2] in UNITS:
        options.add(UNITS[span[0]] * 100 + TENS[span[1]] + UNITS[span[2]])
    if len(span) == 3 and span[0] in UNITS and span[1] == "hundred" and span[2] in UNITS:
        options.add(UNITS[span[0]] * 100 + UNITS[span[2]])
    options.discard(value)
    return frozenset(options)


def extract(text):
    """Every Number in `text`, in order. "N and a half" is N.5; digits followed by a scale word ("50 million")
    are one number, 50000000."""
    found, run = [], []
    text = re.sub(r"(?<=\d):00\b", "", text)  # "7:00" is the hour 7, as in "seven o'clock"

    def flush():
        nonlocal run
        if run:
            found.extend(_split_run(run))
            run = []

    tokens = tokenize(text)
    index = 0
    while index < len(tokens):
        token = tokens[index]
        following = tokens[index + 1:index + 3]
        if token[0].isdigit():
            flush()
            value = digits_value(token)
            if value is not None and following[:1] and following[0] in SCALES:
                value *= SCALES[following[0]]
                index += 1
            if value is not None:
                found.append(Number(value))
        elif token == "and" and following in (["a", "half"], ["half"]) and (run or found) \
                and (run or tokens[index - 1][0].isdigit()):
            flush()
            last = found[-1]
            found[-1] = Number(last.value + 0.5, False, last.alternates)
            index += len(following)
        elif is_number_word(token):
            run.append(token)
        elif token == "point" and run and following[:1] and following[0] in UNITS:
            run.append(token)
        elif token == "a" and following[:1] and following[0] in SCALES:
            flush()
            run.append("one")
        elif token == "and" and run and following[:1] and is_number_word(following[0]) and run[-1] in SCALES:
            run.append(token)
        else:
            flush()
        index += 1
    flush()
    return found


def _split_run(run):
    """Splits a run at 'point' into integer and decimal digits, then parses each side."""
    if "point" not in run:
        return _parse_digits_or_run(run)
    at = run.index("point")
    left = _parse_digits_or_run(run[:at])
    digits = [str(UNITS[w]) for w in run[at + 1:] if w in UNITS and UNITS[w] < 10]
    if left and digits:
        merged = float(f"{left[-1].value}.{''.join(digits)}")
        return left[:-1] + [Number(merged)]
    return left


def _parse_digits_or_run(run):
    """'three three six' is three single digits; 'twenty five' is 25."""
    if len(run) >= 2 and all(w in UNITS and UNITS[w] < 10 for w in run):
        return [Number(UNITS[w], weak=False) for w in run]
    return parse_run(run)
