#!/usr/bin/env python3
"""Readers for the licensed long-form corpora, giving tokens shaped like a recogniser's output.

Tokens are lower-case words without punctuation. Contractions stay whole with one apostrophe
character ("don't"). Numbers stay as the transcript writes them, as ONE token each, with their
signs attached: a decimal ("2.5"), separated thousands ("10,000"), a clock time ("3:05"), currency
("$100", "€9"), percent ("75%") and a range or run of numbers joined by hyphens ("4-5", "10-15%").
Hyphenated compounds are two words ("well known", "5 year").

Annotation is never passed through as words:

- words are missing -> the token next to the gap is marked `missing`, and the extractor REJECTS
  any stretch holding one (it is not cleaned, because the sentence is incomplete):
  Earnings `<inaudible>`, `<unk>`, `<crosstalk>`, `<foreign>`, `<phonetic>` and any marker not
  listed below; AMI `<gap>` and `<transformerror>`; ICSI the `@@` symbol pair and comments that
  say censored, uncodeable, inaudible, unintelligible, uncertain or foreign; and any token whose
  words would lose something that was said (`loses_speech`): a sign written apart from its number
  or between two words ("%", "$", "/", "+", "×", "*", "#", "@"), a minus sign, or a number broken
  at anything but a hyphen ("2031's", "3,45,000", "sek3.75"). "&" is not one of these:
  "birch&oak" stays the two words "birch oak", as before;
- non-speech -> dropped: Earnings `<laugh>`, `<silence>`, `<cough>`, `<clear_throat>` and
  `<affirmative>` (a backchannel sound); AMI/ICSI `vocalsound`, `nonvocalsound`, `disfmarker`,
  `pause` and every other comment;
- cut-off word fragments -> dropped: Earnings tokens ending in a hyphen ("th-"), AMI
  `trunc="true"`, ICSI class `TRUNCW`. Earnings also writes a prefix apart from its word
  ("non- lantern"): a prefix in `PREFIXES` is kept as a word unless the next token restarts it
  ("re- reuse"), because dropping "non" would reverse the meaning.

ICSI writes a possessive or contracted ending as its own element ("'s" in class `APOSS`; "'re",
"'m", "'ll", "'ve" and "'d" as plain words); it is joined back onto the word directly before it, and
dropped when that word is not there (a cut-off fragment, a sound). ICSI also times only some word
edges: a host and its ending share one span, and whole runs of words carry no time. A word is
never dropped for want of a time; it takes the time of the edge before it. Read-out digit strings
(ICSI comment "Digits") are a reading task, not speech: they reject the stretch like missing words.

Every file is passed through the fine-tune path guard before it is opened."""

import csv
import html
from pathlib import Path
import re
import sys
import xml.etree.ElementTree as ET

sys.path.insert(0, str(Path(__file__).resolve().parent / "finetune"))
from pathguard import check  # noqa: E402


CURRENCY = "$€£¥₽"
WORD = r"[^\W_]+(?:'[^\W_]+)*"
ONE_NUMBER = rf"[{CURRENCY}]?(?:\d{{1,3}}(?:,\d{{3}})+|\d+)(?:[.:]\d+)*%?"
NUMBER = (rf"{ONE_NUMBER}(?:-{ONE_NUMBER})*(?![^\W_])"
          rf"|[{CURRENCY}]?\.\d+%?(?![^\W_])")
TOKEN = re.compile(f"{NUMBER}|{WORD}", re.UNICODE)
# Signs that are said aloud ("percent", "dollars", "over", "plus", "times", "star", "number", "at").
SPOKEN_SIGNS = frozenset("%/+×÷=#*@" + CURRENCY)
MINUS = re.compile(rf"[-−][{CURRENCY}]?\.?\d")
FRAGMENT = re.compile(rf"{WORD}-+", re.UNICODE)
MARKER = re.compile(r"[<\[(]\s*([^<>\[\]()]+?)\s*[>\])]")
NON_SPEECH_MARKERS = frozenset("""laugh laughs laughter laughing silence pause cough coughs coughing clear_throat
    throat breath breathing sigh sneeze noise music applause affirmative""".split())
MISSING_COMMENTS = ("censored", "uncodeable", "inaudible", "unintelligible", "uncertain", "foreign")
READING_COMMENT = "digits"
ENDINGS = frozenset({"'s", "'re", "'m", "'ll", "'ve", "'d"})
PREFIXES = frozenset("""non pre post mid anti multi sub semi inter intra counter ultra quasi trans micro macro extra
    super cross self over under co ex re de un dis pro bi tri""".split())
PUNCTUATION_CLASSES = frozenset({".", ",", "?", "!", ":", ";"})
SENTENCE_ENDS = frozenset({".", "?", "!"})
STRETCH_GAP_SECONDS = 2


def plain(text):
    return html.unescape(text).lower().replace("’", "'")


def words(text):
    return TOKEN.findall(plain(text))


def loses_speech(text):
    """True when `words(text)` drops something that was said, for one transcript token.

    That is a spoken sign no word carries ("%" written apart from its number, "and/or"), a leading
    minus sign, or a number broken anywhere but at a hyphen ("2031's" -> "2031 s")."""
    text = plain(text).strip()
    found = list(TOKEN.finditer(text))
    kept = "".join(match[0] for match in found)
    if any(char in SPOKEN_SIGNS and char not in kept for char in text) or MINUS.match(text):
        return True
    for before, after in zip(found, found[1:]):
        between = text[before.end():after.start()]
        if "-" not in between and not between.isspace() and (before[0][-1].isdigit() or after[0][0].isdigit()
                                                              or after[0][0] == "."):
            return True
    return False


def marker_kind(token):
    """"missing" when a marker stands for words that are not there, "drop" for non-speech, else None."""
    match = MARKER.fullmatch(token.strip())
    if match is None:
        return None
    name = re.split(r"[\s:]", match[1].lower())[0]
    return "drop" if name in NON_SPEECH_MARKERS else "missing"


def is_fragment(token):
    """A cut-off word such as "th-": word characters ending in a hyphen."""
    return FRAGMENT.fullmatch(token.strip()) is not None


def detached_prefix(token, following):
    """"non" for a prefix written apart from its word ("non-", then "lantern"); None for anything else,
    including a cut-off start that the next token restarts ("re-", then "reuse")."""
    stem = plain(token).strip().rstrip("-")
    if is_fragment(token) and stem in PREFIXES and not plain(following).strip().startswith(stem):
        return stem
    return None


def series_of(source, meeting):
    """The run of meetings with the same speakers: AMI ES2015a-d share ES2015, ICSI Bmr007 shares Bmr.
    An earnings call is its own series."""
    if source == "ami":
        return re.sub(r"(?<=\d)[a-z]$", "", meeting)
    if source == "icsi":
        return re.match(r"[A-Za-z]*", meeting)[0] or meeting
    return meeting


class Stretch:
    """One speaker's unbroken run of tokens; a missing-words mark sticks to the nearest token."""

    def __init__(self):
        self.tokens = []
        self.pending_missing = False

    def add_text(self, text, start=0, end=0):
        kind = marker_kind(text)
        if kind == "missing":
            self.mark_missing()
        if kind is not None or is_fragment(text):
            return
        if loses_speech(text):
            self.pending_missing = True
        for word in words(text):
            pause = max(0, start - self.tokens[-1]["end"]) if self.tokens else 0
            self.tokens.append({"word": word, "pause": pause, "end": end, "sentence": False,
                                "missing": self.pending_missing})
            self.pending_missing = False
        if self.pending_missing and self.tokens:  # a sign with no word of its own, such as "%"
            self.tokens[-1]["missing"] = True
            self.pending_missing = False

    def mark_missing(self):
        if self.tokens:
            self.tokens[-1]["missing"] = True
        else:
            self.pending_missing = True

    def end_sentence(self):
        if self.tokens:
            self.tokens[-1]["sentence"] = True

    def mark_reading(self):
        """Read-out text starts here: the token before it and the token after it are both marked."""
        self.mark_missing()
        self.pending_missing = True

    def attach(self, text, end=None):
        """Joins an ending written as its own element ("'s", "'re") onto the last token, its host."""
        letters = words(text)
        if self.tokens and letters:
            if not self.tokens[-1]["word"].endswith("'" + letters[0]):  # a stuttered ending is said once
                self.tokens[-1]["word"] += "'" + letters[0]
            if end is not None:
                self.tokens[-1]["end"] = end


def element_kind(element):
    """What one AMI or ICSI element is: word, clitic, sentence (end mark), missing, reading, or skip."""
    tag = element.tag.rsplit("}", 1)[-1]
    text = (element.text or "").strip()
    if tag in ("gap", "transformerror"):
        return "missing"
    if tag == "comment":
        description = element.attrib.get("description", "").lower()
        if description.strip() == READING_COMMENT:
            return "reading"
        return "missing" if any(word in description for word in MISSING_COMMENTS) else "skip"
    if tag != "w":
        return "skip"
    word_class = element.attrib.get("c")
    if element.attrib.get("punc") == "true" or word_class in PUNCTUATION_CLASSES:
        return "sentence" if text in SENTENCE_ENDS else "skip"
    if word_class == "SYM" and text == "@":
        return "missing"
    if element.attrib.get("trunc") == "true" or word_class == "TRUNCW":
        return "skip"
    return "clitic" if word_class == "APOSS" or text.lower().replace("’", "'") in ENDINGS else "word"


def _time(element, name):
    """One edge of an element in seconds, or None when the corpus gives no time for it."""
    try:
        return float(element.attrib[name])
    except (KeyError, ValueError):
        return None


def meeting_stream(path):
    """(meeting, speaker, tokens) for each stretch in an AMI or ICSI words folder."""
    path = check(path)
    word_dir = next((path / name for name in ("words", "Words") if (path / name).is_dir()), path)
    for file in sorted(check(word_dir).glob("*.words.xml")):
        meeting, speaker = file.name.removesuffix(".words.xml").rsplit(".", 1)
        # host_here: the last token was added by the element just before this one, so an ending may join it
        stretch, previous_end, host_here = Stretch(), None, False
        for element in ET.parse(check(file)).getroot():
            kind = element_kind(element)
            if kind == "missing":
                stretch.mark_missing()
            elif kind == "reading":
                stretch.mark_reading()
            elif kind == "sentence":
                stretch.end_sentence()
            if kind not in ("word", "clitic"):
                host_here = False
                continue
            start, end = _time(element, "starttime"), _time(element, "endtime")
            if kind == "clitic":
                if host_here:
                    stretch.attach(element.text or "", end)
                    previous_end = end if end is not None else previous_end
                continue
            if start is not None and previous_end is not None and start - previous_end > STRETCH_GAP_SECONDS:
                if stretch.tokens:
                    yield meeting, speaker, stretch.tokens
                stretch = Stretch()
            if start is None:  # an untimed word starts where the last timed edge was
                start = previous_end if previous_end is not None else end if end is not None else 0
            previous_end = end = start if end is None else end
            before = len(stretch.tokens)
            stretch.add_text(element.text or "", start, end)
            host_here = len(stretch.tokens) > before or host_here and not words(element.text or "")
        if stretch.tokens:
            yield meeting, speaker, stretch.tokens


def earnings_stream(path):
    """(call, speaker, tokens) for each speaker turn in a folder of Earnings .nlp files."""
    for file in sorted(check(path).glob("*.nlp")):
        stretch, current_speaker = Stretch(), None
        with check(file).open(newline="", encoding="utf-8") as handle:
            rows = list(csv.DictReader(handle, delimiter="|"))
        for row, following in zip(rows, rows[1:] + [{}]):
            speaker = (row.get("speaker") or "").strip()
            if speaker != current_speaker:
                if stretch.tokens:
                    yield file.stem, current_speaker, stretch.tokens
                stretch, current_speaker = Stretch(), speaker
            if not speaker:
                continue
            token = row.get("token") or ""
            stretch.add_text(detached_prefix(token, following.get("token") or "") or token)
            if row.get("punctuation") in SENTENCE_ENDS:
                stretch.end_sentence()
        if stretch.tokens:
            yield file.stem, current_speaker, stretch.tokens
