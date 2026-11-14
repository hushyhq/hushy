"""The blind pairwise verdict: schema, request body, strict validation, quote grounding.

The judge sees "Version 1" and "Version 2" only; arm names never reach the request. The verdict
schema uses only keywords the API's structured output supports (type, enum, required,
additionalProperties false; no length or count limits), and `validate_verdict` re-checks every field
because a response that parses is not yet a response that is right.
"""

import json
import re

MEANING_KINDS = ("name", "number", "date", "negation", "dropped_point", "added_point", "other")
FAULT_KINDS = ("filler", "false_start", "restart", "run_on", "missing_sentence_break",
               "missing_paragraph_break", "correction_left_in")
CHOICES = ("version_1", "version_2", "tie")
VERSIONS = ("version_1", "version_2")
TOOL_NAME = "record_verdict"
RUBRIC_VERSION_PATTERN = re.compile(r"^Rubric version:\s*(\S+)\s*$", re.MULTILINE)


class VerdictError(Exception):
    """The model's answer is not a valid verdict. Never repaired or guessed."""


def _strings(properties):
    return {name: {"type": "string"} for name in properties}


def _list_of(kinds, extra):
    item = {"type": "object",
            "properties": {"kind": {"type": "string", "enum": list(kinds)}, **_strings(extra)},
            "required": ["kind", *extra], "additionalProperties": False}
    return {"type": "array", "items": item}


def _version_schema():
    return {"type": "object",
            "properties": {"meaning_changes": _list_of(MEANING_KINDS, ("quote", "said")),
                           "faults": _list_of(FAULT_KINDS, ("quote",))},
            "required": ["meaning_changes", "faults"], "additionalProperties": False}


def verdict_schema():
    return {"type": "object",
            "properties": {"more_typed": {"type": "string", "enum": list(CHOICES)},
                           "version_1": _version_schema(), "version_2": _version_schema(),
                           "reason": {"type": "string"}},
            "required": ["more_typed", "version_1", "version_2", "reason"],
            "additionalProperties": False}


def rubric_version(rubric_text):
    found = RUBRIC_VERSION_PATTERN.search(rubric_text)
    if not found:
        raise VerdictError("rubric has no 'Rubric version: <id>' line")
    return found.group(1)


def user_message(spoken, first, second):
    return ("<spoken>\n" + spoken + "\n</spoken>\n\n<version_1>\n" + first + "\n</version_1>\n\n"
            "<version_2>\n" + second + "\n</version_2>\n\n"
            "Judge the two versions against the rubric and record the verdict.")


def request_body(model, rubric, spoken, first, second, max_tokens, structured="schema", effort=None):
    """The exact request for one blind judgement. Deterministic, so it can be hashed for the cache."""
    body = {"model": model, "max_tokens": max_tokens, "system": rubric,
            "messages": [{"role": "user", "content": user_message(spoken, first, second)}]}
    if structured == "schema":
        body["output_config"] = {"format": {"type": "json_schema", "schema": verdict_schema()}}
    else:
        body["tools"] = [{"name": TOOL_NAME, "strict": True, "input_schema": verdict_schema(),
                          "description": "Record the verdict for this pair. Call this tool exactly "
                                         "once, with every field filled in."}]
        body["tool_choice"] = {"type": "auto"}
        body["system"] = rubric + f"\n\nRecord your verdict by calling the {TOOL_NAME} tool."
    if effort:
        body.setdefault("output_config", {})["effort"] = effort
    return body


def extract_verdict(response):
    """The verdict object inside a Messages response, or VerdictError (refusal, cut-off, no output)."""
    if not isinstance(response, dict):
        raise VerdictError("response is not an object")
    stop = response.get("stop_reason")
    if stop in ("refusal", "max_tokens"):
        raise VerdictError(f"stop_reason {stop}")
    blocks = response.get("content")
    if not isinstance(blocks, list):
        raise VerdictError("response has no content list")
    for block in blocks:
        if isinstance(block, dict) and block.get("type") == "tool_use" and block.get("name") == TOOL_NAME:
            return block.get("input")
    texts = [b.get("text") for b in blocks if isinstance(b, dict) and b.get("type") == "text"]
    if len(texts) != 1 or not isinstance(texts[0], str):
        raise VerdictError("response has neither a verdict tool call nor one text block")
    try:
        return json.loads(texts[0])
    except ValueError:
        raise VerdictError("text block is not valid JSON") from None


def _check_entries(entries, kinds, fields, where):
    if not isinstance(entries, list):
        raise VerdictError(f"{where} must be a list")
    checked = []
    for entry in entries:
        if not isinstance(entry, dict) or set(entry) != {"kind", *fields}:
            raise VerdictError(f"{where} entry has the wrong fields")
        if entry["kind"] not in kinds or any(type(entry[f]) is not str for f in fields):
            raise VerdictError(f"{where} entry has an unknown kind or a non-string field")
        checked.append({key: entry[key] for key in ("kind", *fields)})
    return checked


def validate_verdict(raw):
    """A clean copy of a valid verdict, or VerdictError."""
    if not isinstance(raw, dict) or set(raw) != {"more_typed", "version_1", "version_2", "reason"}:
        raise VerdictError("verdict has the wrong top-level fields")
    if raw["more_typed"] not in CHOICES or type(raw["reason"]) is not str:
        raise VerdictError("verdict has an unknown choice or a non-string reason")
    clean = {"more_typed": raw["more_typed"], "reason": raw["reason"]}
    for name in VERSIONS:
        side = raw[name]
        if not isinstance(side, dict) or set(side) != {"meaning_changes", "faults"}:
            raise VerdictError(f"{name} has the wrong fields")
        clean[name] = {
            "meaning_changes": _check_entries(side["meaning_changes"], MEANING_KINDS,
                                              ("quote", "said"), f"{name}.meaning_changes"),
            "faults": _check_entries(side["faults"], FAULT_KINDS, ("quote",), f"{name}.faults")}
    return clean


def normal_text(text):
    return " ".join(re.sub(r"[^\w$%]+", " ", text.lower()).split())


def ground_verdict(verdict, spoken, texts):
    """Adds `grounded` to each quote: true when it appears in the text it claims to quote.

    `texts` is (version_1 text, version_2 text). A quote that is not found is kept and flagged, not
    dropped; the report counts them so a judge that invents evidence is visible.
    """
    result = json.loads(json.dumps(verdict))
    for name, text in zip(VERSIONS, texts):
        for entry in result[name]["meaning_changes"]:
            entry["grounded"] = (not entry["quote"] or normal_text(entry["quote"]) in normal_text(text)) and \
                                (not entry["said"] or normal_text(entry["said"]) in normal_text(spoken))
        for entry in result[name]["faults"]:
            entry["grounded"] = not entry["quote"] or normal_text(entry["quote"]) in normal_text(text)
    return result
