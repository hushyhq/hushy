"""Speech-first pilot: the notes and spoken calls, and the independent check of the typed text against the notes.

Everything is pure except the exemplar file read. The call loop is the pilot's (retrain_pilot.call_step).
"""

import json
from pathlib import Path
import random
import re
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))

import api_judge_verdict as verdicts  # noqa: E402
import retrain_checks as checks  # noqa: E402
import retrain_numbers as numbers  # noqa: E402
import retrain_pilot_steps as pilot_steps  # noqa: E402
import retrain_writer as writer  # noqa: E402
from retrain_lexicon import FUNCTION_WORDS, MONTHS, WEEKDAYS, stem, words  # noqa: E402

NOTE_KINDS = ("name", "number", "date", "time", "amount", "file")
FACT_KIND_FOR_FLAG = {"names": "name", "numbers": "number", "dates": "date", "times": "time", "amounts": "amount",
                      "files": "file"}
SPOKEN_SYMBOLS = ((" dash dash ", " --"), (" dot ", "."), (" slash ", "/"), (" underscore ", "_"))
PLAIN_OK = re.compile(r"^[a-z0-9' ]+$")
PUNCTUATED_OK = re.compile(r"^[A-Za-z0-9 .,?!'$%:;\-\"]+$")
EXEMPLAR_WORDS = 70
NEGATION_WINDOW = 8
MANNER_NOTE = ("These are examples of manner only. Their topic, names and wording are irrelevant to what you write.")


# ---- cards ---------------------------------------------------------------------------------------

def notes_card(slot):
    wanted = [FACT_KIND_FOR_FLAG[k] for k, on in slot["facts"].items() if on]
    card = {"kind": slot["kind"], "role": slot["role"], "domain": slot["domain"], "register": slot["register"],
            "points": slot["points"], "fact_kinds_wanted": wanted, "names": slot["names"]}
    if slot["family"] == "agent":
        card["talking_to"] = "an AI coding or work agent, partway through a task"
    return card


def pick_exemplars(pool, seed, count=2):
    """`count` windows of real speech, different per seed, from distinct passages of the pool."""
    rng = random.Random(seed)
    chosen = []
    for row in rng.sample(pool, count):
        tokens = row["spoken"].split()
        start = rng.randrange(0, max(1, len(tokens) - EXEMPLAR_WORDS))
        chosen.append(" ".join(tokens[start:start + EXEMPLAR_WORDS]))
    return chosen


def spoken_card(slot, notes, exemplars):
    card = {"notes": notes, "manner_examples": exemplars, "manner_note": MANNER_NOTE, "surface": slot["surface"],
            "stray_full_stop": slot["stray_full_stop"], "profile": slot["profile"], "plants": slot["plants"],
            "spoken_words": slot["spoken_words_target"]}
    if slot["family"] == "agent":
        card["talking_to"] = "an AI coding or work agent, partway through a task"
    return card


# ---- schemas and validators ----------------------------------------------------------------------

def notes_schema():
    text = {"type": "string"}
    listed = lambda props: {"type": "array", "items": {"type": "object", "properties": props,  # noqa: E731
                                                       "required": list(props), "additionalProperties": False}}
    return {"type": "object", "properties": {
        "speaker": text, "addressee": text, "situation": text,
        "points": listed({"text": text, "anchors": {"type": "array", "items": text}}),
        "facts": listed({"kind": {"type": "string", "enum": list(NOTE_KINDS)}, "value": text, "about": text}),
        "negations": listed({"text": text, "anchor": text})},
        "required": ["speaker", "addressee", "situation", "points", "facts", "negations"], "additionalProperties": False}


def validate_notes(raw):
    fields = {"speaker", "addressee", "situation", "points", "facts", "negations"}
    if not isinstance(raw, dict) or set(raw) != fields:
        raise verdicts.VerdictError("notes have the wrong fields")
    for key in ("speaker", "addressee", "situation"):
        if type(raw[key]) is not str or not raw[key].strip():
            raise verdicts.VerdictError(f"notes {key} is empty")
    points = []
    for item in raw["points"] if isinstance(raw["points"], list) else []:
        anchors = item.get("anchors") if isinstance(item, dict) else None
        if not isinstance(anchors, list) or not 1 <= len(anchors) <= 3 or any(
                type(a) is not str or not re.fullmatch(r"[a-z']+", a) for a in anchors) or type(item.get("text")) is not str:
            raise verdicts.VerdictError("a point needs text and one to three plain lower-case anchor words")
        points.append({"text": item["text"], "anchors": list(anchors)})
    if not points:
        raise verdicts.VerdictError("notes have no points")
    facts = []
    for item in raw["facts"] if isinstance(raw["facts"], list) else []:
        if not isinstance(item, dict) or item.get("kind") not in NOTE_KINDS or type(item.get("value")) is not str \
                or not item["value"].strip() or type(item.get("about")) is not str:
            raise verdicts.VerdictError("a fact has the wrong fields")
        facts.append({"kind": item["kind"], "value": item["value"].strip(), "about": item["about"]})
    negations = []
    for item in raw["negations"] if isinstance(raw["negations"], list) else []:
        if not isinstance(item, dict) or type(item.get("text")) is not str or type(item.get("anchor")) is not str \
                or not re.fullmatch(r"[a-z']+", item["anchor"]):
            raise verdicts.VerdictError("a negation needs text and one plain lower-case anchor word")
        negations.append({"text": item["text"], "anchor": item["anchor"]})
    return {"speaker": raw["speaker"], "addressee": raw["addressee"], "situation": raw["situation"],
            "points": points, "facts": facts, "negations": negations}


spoken_schema = pilot_steps.spoken_schema
validate_spoken = pilot_steps.validate_spoken


class NotesRunner(writer.WriterRunner):
    validate = staticmethod(validate_notes)
    tool = "retrain_speech_notes"


class SpokenRunner(writer.WriterRunner):
    validate = staticmethod(validate_spoken)
    tool = "retrain_speech_spoken"


# ---- the spoken text against the plan --------------------------------------------------------------

def spoken_form(value):
    """How a person says a file, flag or setting aloud: 'src/utils/parse.py' -> 'src slash utils slash parse dot py'."""
    text = " " + value.lower().replace("--", " dash dash ").replace("/", " slash ").replace(".", " dot ") \
        .replace("_", " underscore ").replace("-", " dash ") + " "
    return " ".join(text.split())


DIGIT_WORDS = dict(zip("0123456789", "zero one two three four five six seven eight nine".split()))


def spoken_variants(value):
    """Space-free ways a file, flag or setting may be heard: the full form, a single hyphen left unsaid ("dash dash dry
    run"), and digits as words ("q three"); spaces are ignored so spelled-out letters ("x l s x") still match."""
    form = spoken_form(value)
    quiet = form.replace(" dash dash ", "§").replace(" dash ", " ").replace("§", " dash dash ")
    digits = lambda text: "".join(" " + DIGIT_WORDS[c] + " " if c in DIGIT_WORDS else c for c in text)  # noqa: E731
    return {"".join(v.split()) for v in (form, quiet, digits(form), digits(quiet))}


def recogniser_problems(slot, spoken, notes):
    """Findings that make a spoken text something a recogniser would not write."""
    found = []
    allowed = PLAIN_OK if slot["surface"] == "plain" else PUNCTUATED_OK
    if not allowed.fullmatch(spoken):
        found.append("surface:characters_a_recogniser_would_not_write")
    heard = "".join(words(spoken))
    for fact in notes["facts"]:
        if fact["kind"] == "file" and not any(form in heard for form in spoken_variants(fact["value"])):
            found.append(f"surface:file_not_said_aloud:{fact['value']}")
    return found


# ---- the independent check: typed text against the notes ----------------------------------------------

def _typed_with_symbols(typed):
    padded = " " + " ".join(words(typed)) + " "
    for spoken, symbol in SPOKEN_SYMBOLS:
        padded = padded.replace(spoken, symbol)
    return padded.strip()


def _value_present(value, typed):
    wanted = {n.value for n in numbers.extract(value)}
    present = {n.value for n in numbers.extract(typed)} | {a for n in numbers.extract(typed) for a in n.alternates}
    day_words = {w for w in words(value) if w in WEEKDAYS | MONTHS}
    return wanted <= present and day_words <= set(words(typed))


def _fact_ok(fact, typed):
    kind, value = fact["kind"], fact["value"]
    if kind == "name":
        return all(part in words(typed) or stem(part) in {stem(w) for w in words(typed)} for part in words(value))
    if kind == "file":
        low = typed.lower()
        return value.lower() in low
    return _value_present(value, typed)


def _file_only_as_words(fact, typed):
    return fact["kind"] == "file" and fact["value"].lower() not in typed.lower() \
        and fact["value"].lower() in _typed_with_symbols(typed)


def _negation_near(anchor, typed):
    tokens = checks._negation_tokens(typed)
    negations = [i for i, t in enumerate(tokens) if t in checks.NEGATIONS or t in checks.INFORMAL_NEGATIONS
                 or t == "no" or t.endswith("n't")]
    spots = [i for i, t in enumerate(tokens) if stem(t) == stem(anchor)]
    return any(abs(i - j) <= NEGATION_WINDOW for i in spots for j in negations)


def _content(text):
    return {stem(w) for w in words(text) if w not in FUNCTION_WORDS and not w[0].isdigit()}


def check_against_notes(notes, plants, typed):
    """Named checks of the typed text against the notes: [(name, ok, detail)] as a dict. Anything failing sets the
    passage aside. Blind to a point that keeps its anchors but says something else."""
    typed_stems = {stem(w) for w in words(typed)}
    # an anchor may sit inside a longer typed word ("filter" in "ReleaseFilter")
    squashed = "".join(words(typed))  # "check-in" and "checkin" meet here
    anchored = lambda a: stem(a) in typed_stems or stem(a) in squashed  # noqa: E731
    facts_missing = [f["value"] for f in notes["facts"] if f["kind"] != "file" and not _fact_ok(f, typed)]
    files_missing = [f["value"] for f in notes["facts"] if f["kind"] == "file" and not _fact_ok(f, typed)
                     and not _file_only_as_words(f, typed)]
    files_as_words = [f["value"] for f in notes["facts"] if _file_only_as_words(f, typed)]
    # a point stands when all its anchors are there, or all but one of three: the notes' own words are not the
    # speaker's, so one anchor may be a synonym (limit of the check)
    points_missing = [p["text"] for p in notes["points"]
                      if sum(anchored(a) for a in p["anchors"]) < max(1, len(p["anchors"]) - (len(p["anchors"]) >= 3))]
    negations_missing = [n["text"] for n in notes["negations"] if not _negation_near(n["anchor"], typed)]
    known_values = {n.value for f in notes["facts"] if f["kind"] in ("number", "date", "time", "amount")
                    for n in numbers.extract(f["value"])}
    unresolved = []
    for plant in plants:
        if plant["kind"] == "opening_adds":
            continue
        wanted_numbers = {n.value for n in numbers.extract(plant["ended_on"])}
        typed_numbers = {n.value for n in numbers.extract(typed)} | {a for n in numbers.extract(typed)
                                                                      for a in n.alternates}
        wanted_words = [w for w in _content(plant["ended_on"]) if not numbers.is_number_word(w)]
        present = sum(anchored(w) for w in wanted_words)
        if not wanted_numbers <= typed_numbers or present < 0.6 * len(wanted_words):
            unresolved.append(f"{plant['kind']}: ended_on not in typed")
        if plant["kind"] in ("value_cue", "value_restart"):
            back = {n.value for n in numbers.extract(plant["said_first"])} - known_values
            if back & {n.value for n in numbers.extract(typed)}:
                unresolved.append(f"{plant['kind']}: the taken-back value is in typed")
    result = {"facts": facts_missing, "files": files_missing, "points": points_missing,
              "negations": negations_missing, "plants": unresolved}
    failed = [name for name, missing in result.items() if missing]
    return {"ok": not failed, "failed": failed, "missing": result, "files_left_as_words": files_as_words}
