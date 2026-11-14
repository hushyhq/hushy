"""The pilot's two generation calls (typed text, then the spoken version) and the checks that need no API.

Reuses the example writer's call loop, cache and ledger (retrain_writer.WriterRunner) with a different
validator, so the key handling, worst-case budget reservation and path guards are the same code.
"""

import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import api_judge  # noqa: E402
import api_judge_verdict as verdicts  # noqa: E402
import retrain_checks as checks  # noqa: E402
import retrain_writer as writer  # noqa: E402
from retrain_lexicon import INFORMAL_NEGATIONS, NEGATIONS, words  # noqa: E402
from collections import Counter  # noqa: E402

PLANT_KINDS = ("value_cue", "value_restart", "negation_corrected", "opening_adds", "plan_reversal")
CORRECTING_KINDS = ("value_cue", "value_restart", "negation_corrected", "plan_reversal")
FACT_PHRASES = {
    "names": "one or two first names taken from `names`, used where a name is natural",
    "numbers": "at least one count or measurement (digits if over ten)",
    "dates": "at least one weekday or calendar date",
    "times": "at least one clock time",
    "amounts": "at least one money amount",
}
FILLER_PATTERN = re.compile(r"\b(?:um+|uh+|you know|i mean|basically|kind of|sort of)\b|\blike\b", re.I)
LIST_LINE = re.compile(r"^\s*(?:[-*•#>]|\d+[.)])\s", re.M)
SHINGLE = 3
DUPLICATE_JACCARD = 0.25
TYPED_LENGTH_TOLERANCE = 0.30
BAND_SLACK = 0.10
RESTART_WINDOW = 12  # a negation word said again this close is a restart, not a second negation


# ---- cards ---------------------------------------------------------------------------------------

def typed_card(slot):
    card = {"kind": slot["kind"], "role": slot["role"], "domain": slot["domain"], "register": slot["register"],
            "typed_words": slot["typed_words_target"],
            "must_include": [FACT_PHRASES[k] for k, on in slot["facts"].items() if on],
            "names": slot["names"]}
    if slot["file_hint"]:
        card["name_inside_a_sentence"] = slot["file_hint"]
    return card


def spoken_card(slot, typed):
    return {"typed": typed, "surface": slot["surface"], "stray_full_stop": slot["stray_full_stop"],
            "profile": slot["profile"], "ingredients": slot["ingredients"], "plants": slot["plants"],
            "spoken_words": slot["spoken_words_target"]}


def user_message(card, closing):
    blob = json.dumps(card, indent=1, ensure_ascii=False)
    if "</card>" in blob:
        raise writer.WriterError("a card contains the text '</card>'")
    return f"<card>\n{blob}\n</card>\n\n{closing}"


# ---- schemas and validators ----------------------------------------------------------------------

def typed_schema():
    return {"type": "object", "properties": {"typed": {"type": "string"}}, "required": ["typed"],
            "additionalProperties": False}


def spoken_schema():
    text = {"type": "string"}
    plant = {"type": "object", "properties": {"kind": {"type": "string", "enum": list(PLANT_KINDS)},
                                              "said_first": text, "ended_on": text},
             "required": ["kind", "said_first", "ended_on"], "additionalProperties": False}
    return {"type": "object", "properties": {"spoken": text, "plants": {"type": "array", "items": plant}},
            "required": ["spoken", "plants"], "additionalProperties": False}


def validate_typed(raw):
    if not isinstance(raw, dict) or set(raw) != {"typed"} or type(raw["typed"]) is not str or not raw["typed"].strip():
        raise verdicts.VerdictError("typed answer must be {typed: non-empty string}")
    return {"typed": raw["typed"].strip()}


def validate_spoken(raw):
    if not isinstance(raw, dict) or set(raw) != {"spoken", "plants"} or type(raw["spoken"]) is not str \
            or not raw["spoken"].strip() or not isinstance(raw["plants"], list):
        raise verdicts.VerdictError("spoken answer must be {spoken, plants}")
    plants = []
    for item in raw["plants"]:
        if not isinstance(item, dict) or set(item) != {"kind", "said_first", "ended_on"} \
                or item["kind"] not in PLANT_KINDS or any(type(item[k]) is not str for k in item):
            raise verdicts.VerdictError("a plant has the wrong fields")
        plants.append({k: item[k] for k in ("kind", "said_first", "ended_on")})
    return {"spoken": " ".join(raw["spoken"].split()), "plants": plants}


class StepCache(api_judge.Cache):
    def __init__(self, directory, validate):
        super().__init__(directory)
        self.validate = validate

    def get(self, key):
        try:
            entry = json.loads((self.directory / f"{key}.json").read_text(encoding="utf-8"))
            return {**entry, "written": self.validate(entry["written"])}
        except (OSError, ValueError, KeyError, TypeError, verdicts.VerdictError):
            return None


class TypedRunner(writer.WriterRunner):
    validate = staticmethod(validate_typed)
    tool = "retrain_pilot_typed"


class SpokenRunner(writer.WriterRunner):
    validate = staticmethod(validate_spoken)
    tool = "retrain_pilot_spoken"


def request_body(model, instructions, user, schema, max_tokens, effort=None):
    body = {"model": model, "max_tokens": max_tokens, "system": instructions,
            "messages": [{"role": "user", "content": user}],
            "output_config": {"format": {"type": "json_schema", "schema": schema}}}
    if effort:
        body["output_config"]["effort"] = effort
    return body


def version_of(text):
    found = re.search(r"^Pilot version:\s*(\S+)\s*$", text, re.M)
    if not found:
        raise writer.WriterError("instructions have no 'Pilot version: <id>' line")
    return found.group(1)


# ---- checks on the typed text ----------------------------------------------------------------------

def typed_problems(slot, typed):
    """Reasons a typed text is not what the card asked for. Empty when it is."""
    problems = []
    count = len(typed.split())
    target = slot["typed_words_target"]
    if abs(count - target) > TYPED_LENGTH_TOLERANCE * target:
        problems.append(f"length:{count}_vs_{target}")
    if "```" in typed or LIST_LINE.search(typed) or "`" in typed:
        problems.append("not_prose")
    if "</card>" in typed:
        problems.append("card_marker")
    return problems


def shingles(text):
    tokens = words(text)
    return {tuple(tokens[i:i + SHINGLE]) for i in range(len(tokens) - SHINGLE + 1)}


def near_duplicates(rows):
    """[(later_id, earlier_id, jaccard)] for every pair of typed texts whose word triples overlap too much."""
    found, kept = [], []
    for row in rows:
        mine = shingles(row["typed"])
        for other_id, other_shingles in kept:
            union = mine | other_shingles
            score = len(mine & other_shingles) / len(union) if union else 0.0
            if score >= DUPLICATE_JACCARD:
                found.append((row["id"], other_id, round(score, 3)))
                break
        else:
            kept.append((row["id"], mine))
    return found


def shared_openings(rows):
    """Report only: ids whose first five words equal an earlier row's (a habit of the writer, not a duplicate)."""
    seen, found = {}, []
    for row in rows:
        opening = tuple(words(row["typed"])[:5])
        if opening in seen:
            found.append((row["id"], seen[opening]))
        else:
            seen[opening] = row["id"]
    return found


# ---- checks on the spoken text ---------------------------------------------------------------------

def _present(phrase, spoken):
    return " ".join(words(phrase)) in " ".join(words(spoken))


def spoken_problems(slot, spoken, plants):
    """Named, separately reported findings about a spoken text against its plan (not against the typed text)."""
    found = []
    count = len(spoken.split())
    low, high = slot["band"]
    if count < low * (1 - BAND_SLACK) or count > high * (1 + BAND_SLACK):
        found.append(f"band:{count}_words_outside_{low}-{high}")
    if slot["surface"] == "plain" and re.search(r"[^a-z0-9' ]", spoken):
        found.append("surface:plain_has_case_or_marks")
    if slot["surface"] == "punctuated" and not ((spoken[:1].isupper() or spoken[:1].isdigit()) and re.search(r"[.?!,]", spoken)):
        found.append("surface:punctuated_lacks_case_or_marks")
    if "\n" in spoken:
        found.append("surface:line_break")
    if sorted(p["kind"] for p in plants) != sorted(slot["plants"]):
        found.append("plants:not_the_planned_kinds")
    for p in plants:
        if not (_present(p["said_first"], spoken) and _present(p["ended_on"], spoken)):
            found.append(f"plants:{p['kind']}_not_quoted_exactly")
    if slot["profile"] == "clean" and (FILLER_PATTERN.search(spoken) or re.search(r"\b(\w+) \1\b", spoken, re.I)):
        found.append("profile:clean_has_fillers_or_repeats")
    if slot["profile"] != "clean" and not plants and not FILLER_PATTERN.search(spoken) and not re.search(r"\b(\w+) \1\b", spoken, re.I):
        found.append("profile:rough_row_has_nothing_to_clean")
    return found


def _negation_words(text):
    return [w for w in checks._negation_tokens(text) if w in NEGATIONS or w in INFORMAL_NEGATIONS or w == "no"
            or w.endswith("n't")]


def negation_faithful(spoken, typed, plants):
    """The typed text is the truth here, so every negation it has must be in the spoken text (else the speech lost
    or flipped one); extra negations in the speech must be explained by a planted correction, a restart (the same
    negation word again within a few words) or a "no" cue. Blind to a negation that moved to another clause."""
    spoken_tokens = checks._negation_tokens(spoken)
    typed_count, spoken_count = Counter(_negation_words(typed)), Counter(_negation_words(spoken))
    lost = sorted(w for w, n in typed_count.items() if n > spoken_count[w])
    extra = sum((spoken_count - typed_count).values())
    last_seen, restarts = {}, 0
    for index, token in enumerate(spoken_tokens):
        if token in spoken_count or token == "no":
            restarts += token in last_seen and index - last_seen[token] <= RESTART_WINDOW
            last_seen[token] = index
    allowance = sum(1 for p in plants if p["kind"] in CORRECTING_KINDS) + restarts + spoken_count["no"]
    problems = (["negation_lost"] if lost else []) + (["negation_unexplained"] if extra > allowance else [])
    return checks.result(not problems, lost=lost, extra=extra, allowance=allowance, problems=problems)


def spoken_vs_typed(slot, spoken, typed, plants):
    """The example writer's checks run in the other direction: is the spoken text the typed text plus only the
    planted roughness? Its negation check (which counts a repeated phrase twice) is replaced by one that knows
    which side is the truth. Returns (failed check names, full outcome)."""
    corrections = [{"said_first": p["said_first"], "ended_on": p["ended_on"]}
                   for p in plants if p["kind"] in CORRECTING_KINDS]
    outcome = checks.run_checks(spoken, typed, corrections, ())
    outcome["negation"] = negation_faithful(spoken, typed, plants)
    return checks.failed(outcome), outcome
