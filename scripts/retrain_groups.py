"""Pilot steps 4 to 7 support: merging the two routes, left context, the per-group target call, the group-level checks,
and the training rows for both arms. The groups themselves and the guard verdicts come from the app's own code through
`murmur-eval finetune groups` and `finetune prepare`; nothing here cuts text.
"""

import json
from pathlib import Path
import re
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))

import api_judge_verdict as verdicts  # noqa: E402
import retrain_checks as checks  # noqa: E402
import retrain_numbers as numbers  # noqa: E402
import retrain_pilot_steps as pilot_steps  # noqa: E402
import retrain_writer as writer  # noqa: E402
from retrain_lexicon import FUNCTION_WORDS, stem, words  # noqa: E402

LEFT_MIN_WORDS, LEFT_MAX_WORDS = 15, 25
SENTENCE_END = re.compile(r"(?<=[.!?])\s+")
GROUP_LENGTH_BAND = (0.4, 1.15)  # typed words / draft words; a group is short, so wider than a whole passage


# ---- left context ---------------------------------------------------------------------------------

def left_context(previous_draft):
    """The last sentence (about 15 to 25 words) of the previous group's rules draft; "none" for the first group.
    A sentence shorter than 15 words takes the sentence before it too; a longer one keeps its last 25 words. The app's
    own sentence splitter is internal to MurmurCore, so this splits on . ! ? followed by a space."""
    if not previous_draft or not previous_draft.strip():
        return "none"
    sentences = [s for s in SENTENCE_END.split(previous_draft.strip()) if s]
    picked = []
    while sentences and len(" ".join(picked).split()) < LEFT_MIN_WORDS:
        picked.insert(0, sentences.pop())
    tokens = " ".join(picked).split()
    return " ".join(tokens[-LEFT_MAX_WORDS:])


# ---- the per-group target call ----------------------------------------------------------------------

def targets_card(row, group_row):
    groups = [{"index": g["index"], "continues_sentence": g["continuesSentence"], "text": g["text"], "draft": g["draft"]}
              for g in group_row["groups"]]
    return {"typed": row["typed"], "groups": groups,
            "planted": [{"said_first": p["said_first"], "ended_on": p["ended_on"]} for p in row["plants"]
                        if p["kind"] != "opening_adds"]}


def targets_schema():
    text = {"type": "string"}
    piece = {"type": "object", "properties": {"index": {"type": "integer"}, "piece": text,
                                              "new_paragraph": {"type": "boolean"},
                                              "span_representable": {"type": "boolean"}, "reason": text},
             "required": ["index", "piece", "new_paragraph", "span_representable", "reason"],
             "additionalProperties": False}
    return {"type": "object", "properties": {"pieces": {"type": "array", "items": piece}}, "required": ["pieces"],
            "additionalProperties": False}


def validate_targets(raw):
    if not isinstance(raw, dict) or set(raw) != {"pieces"} or not isinstance(raw["pieces"], list) or not raw["pieces"]:
        raise verdicts.VerdictError("targets need a non-empty pieces list")
    pieces = []
    for item in raw["pieces"]:
        if not isinstance(item, dict) or set(item) != {"index", "piece", "new_paragraph", "span_representable", "reason"} \
                or type(item["index"]) is not int or type(item["piece"]) is not str \
                or type(item["new_paragraph"]) is not bool or type(item["span_representable"]) is not bool \
                or type(item["reason"]) is not str:
            raise verdicts.VerdictError("a piece has the wrong fields")
        pieces.append(dict(item))
    return {"pieces": pieces}


def targets_schema_v3():
    schema = targets_schema()
    return {"type": "object", "properties": {"typed": {"type": "string"}, **schema["properties"]},
            "required": ["typed", "pieces"], "additionalProperties": False}


def validate_targets_v3(raw):
    if not isinstance(raw, dict) or set(raw) != {"typed", "pieces"} or type(raw["typed"]) is not str:
        raise verdicts.VerdictError("targets need typed and pieces")
    return {"typed": raw["typed"], **validate_targets({"pieces": raw["pieces"]})}


class TargetsRunnerV3(writer.WriterRunner):
    validate = staticmethod(validate_targets_v3)
    tool = "retrain_group_targets_v3"


class TargetsRunnerV4(writer.WriterRunner):
    validate = staticmethod(validate_targets_v3)
    tool = "retrain_group_targets_v4"


class TargetsRunner(writer.WriterRunner):
    validate = staticmethod(validate_targets)
    tool = "retrain_group_targets"


# ---- joining and locating -----------------------------------------------------------------------------

def join_pieces(pieces):
    out = ""
    for item in pieces:
        text = item["piece"].strip()
        if not text:
            continue
        out += ("" if not out else ("\n\n" if item["new_paragraph"] else " ")) + text
    return out


def same_text(a, b):
    return [t for t in re.split(r"\s+", a.strip()) if t] == [t for t in re.split(r"\s+", b.strip()) if t] \
        and a.count("\n\n") == b.count("\n\n")


def _norm(text):
    return " ".join(words(text))


def plant_group(plant_text, group_texts):
    """Index of the first group whose speech contains `plant_text` (word-normalised), or None."""
    needle = _norm(plant_text)
    return next((i for i, text in enumerate(group_texts) if needle and needle in _norm(text)), None)


def seam_spanning(plants, group_texts):
    """{group index: reason} for groups touched by a correction whose two ends are in different groups, or whose ends
    cannot be found. Mechanical: it does not depend on what the target writer said."""
    flagged = {}
    for plant in plants:
        if plant["kind"] == "opening_adds":
            continue
        first, last = plant_group(plant["said_first"], group_texts), plant_group(plant["ended_on"], group_texts)
        if first is None or last is None:
            continue
        if first != last:
            for index in range(first, last + 1):
                flagged[index] = f"{plant['kind']} spans groups {first}-{last}"
    return flagged


# ---- group-level checks --------------------------------------------------------------------------------

def group_checks(draft, piece, plants, group_text):
    """The writer's checks between a group's rules draft and its piece, each separate. Plants located inside this
    group are passed as corrections so a legitimate take-back is not a loss."""
    here = [{"said_first": p["said_first"], "ended_on": p["ended_on"]} for p in plants
            if p["kind"] != "opening_adds" and plant_group(p["said_first"], [group_text]) == 0]
    outcome = {
        "numbers": checks.check_numbers(draft, piece, here, []), "dates": checks.check_dates(draft, piece, here, []),
        "names": checks.check_names(draft, piece, here, []),
        "negation": pilot_steps.negation_faithful(draft, piece, [p for p in plants if p["kind"] != "opening_adds"
                                                                  and plant_group(p["said_first"], [group_text]) == 0]),
        "length": checks.check_length(draft, piece, GROUP_LENGTH_BAND)}
    cues = {"actually", "no", "wait", "sorry", "mean", "scratch", "that", "i", "okay", "so", "well", "oh", "um", "uh"}
    resolved = [stem(w) for item in here for w in words(item["ended_on"])
                if w not in cues and w not in FUNCTION_WORDS and not w[0].isdigit() and not numbers.is_number_word(w)]
    outcome["corrections_resolved"] = checks.result(all(w in {stem(x) for x in words(piece)} for w in resolved),
                                                    expected=resolved)
    return outcome, [name for name, value in outcome.items() if not value["ok"]]


# ---- rows for both arms ----------------------------------------------------------------------------------

def prompt_sections(path):
    """(system, user template) from a draft prompt file under Evals/finetune-prompts."""
    text = Path(path).read_text(encoding="utf-8")
    system = text.split("--- system turn ---", 1)[1].split("--- user turn ---", 1)[0].strip()
    return system


def group_row(source, group, previous_draft, piece, system):
    user = f"Left context: {left_context(previous_draft)}\nTranscript: {group['draft']}\nOutput:"
    answer = json.dumps({"text": piece["piece"].strip(), "new_paragraph": piece["new_paragraph"]},
                        ensure_ascii=False, separators=(",", ":"))
    return {"id": f"{source['id']}-g{group['index']}", "passage": source["id"], "route": source["route"],
            "arm": "group", "messages": [{"role": "system", "content": system}, {"role": "user", "content": user},
                                         {"role": "assistant", "content": answer}]}


def whole_row(source, whole_draft, system):
    answer = json.dumps({"text": source["typed"]}, ensure_ascii=False, separators=(",", ":"))
    return {"id": f"{source['id']}-whole", "passage": source["id"], "route": source["route"], "arm": "whole",
            "messages": [{"role": "system", "content": system},
                         {"role": "user", "content": f"Transcript: {whole_draft}\nOutput:"},
                         {"role": "assistant", "content": answer}]}
