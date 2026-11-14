#!/usr/bin/env python3
"""Score model answers against the number probe or the prompt probe (invented cases, frozen, never trained on).

usage: python3 -I scripts/probe_score.py <cases.jsonl> <answers.jsonl> [--rows]

<cases.jsonl> is Evals/number-probe.jsonl (rows with "expect") or Evals/prompt-probe.jsonl (rows with "must").
<answers.jsonl> is the output of `murmur-eval intent-app` (id, text, usedModel) or of the training PC's
`intent_box.py` (id, text; no usedModel, so no refusal count). Standard library only, so it runs on the box.

A case passes when every check holds. `--rows` prints each failing case with the answer.

Number probe row: expect = list of groups, each a list of accepted spellings (any one must be present);
"digits:4471" means those digits are one run; spaces and punctuation inside the run are ignored, and a letter ends it. forbid = values that
must NOT appear (the ones the speaker took back). counts = {"45": 2} the value appears at least that often.
no_digits = the answer has no digit at all.

Prompt probe row: must = groups as above (case-insensitive text); ordered = groups appear in that order;
forbid = text that must not appear; min_list / max_list = lines that are list items; min_paragraphs = blocks
separated by a blank line; qmark = a question mark; max_ratio = answer words / spoken words at most this.
"""
import json
import re
import sys

LIST_LINE = re.compile(r"^\s*(?:[-*•]|\d+[.)])\s+")


def norm(text):
    text = text.lower().replace("’", "'").replace("‘", "'")
    text = re.sub(r"(?<=\d),(?=\d{3}\b)", "", text)
    return re.sub(r"\s+", " ", text).strip()


def digits_of(text):
    return re.sub(r"\D", "", text)


def has_digit_run(text, digits):
    """True when `digits` is one run. Spaces and punctuation may sit inside it; a letter ends it.

    Gluing every digit in the answer made `4471` pass inside `144719` and inside `44 and 71`.
    """
    buf = []

    def matches():
        return "".join(buf) == digits

    for ch in text:
        if ch.isdigit():
            buf.append(ch)
        elif buf and not ch.isalpha():
            continue
        elif matches():
            return True
        else:
            buf.clear()
    return matches()


def find_value(text, variant):
    """Position of a value spelling in normalised text, or -1. A digit string is not found inside a longer one."""
    variant = norm(variant)
    pattern = r"(?<![\w.:])" + re.escape(variant) + r"(?![\w:]|[.,]\d)"
    match = re.search(pattern, text)
    return match.start() if match else -1


def find_phrase(text, variant):
    return text.find(norm(variant))


def group_position(text, group, finder):
    for variant in group:
        if variant.startswith("digits:"):
            if has_digit_run(text, variant[7:]):
                return 0
            continue
        at = finder(text, variant)
        if at >= 0:
            return at
    return -1


def score_number(case, answer):
    text, failures = norm(answer), []
    for group in case.get("expect", []):
        if group_position(text, group, find_value) < 0:
            failures.append(f"missing {group[0]}")
    for value in case.get("forbid", []):
        if find_value(text, value) >= 0:
            failures.append(f"kept {value}")
    for value, times in case.get("counts", {}).items():
        if len(re.findall(r"(?<![\w.:])" + re.escape(norm(value)) + r"(?![\w:]|[.,]\d)", text)) < times:
            failures.append(f"{value} fewer than {times} times")
    if case.get("no_digits") and re.search(r"\d", answer):
        failures.append("digits added")
    return failures


def score_prompt(case, answer):
    text, failures = norm(answer), []
    spoken_words = max(1, len(case["spoken"].split()))
    positions = []
    for group in case.get("must", []):
        at = group_position(text, group, find_phrase)
        if at < 0:
            failures.append(f"missing {group[0]}")
        positions.append(at)
    found = [p for p in positions if p >= 0]
    if case.get("ordered") and found != sorted(found):
        failures.append("items out of order")
    for value in case.get("forbid", []):
        # as written: "return " needs its space, and "here is" must not match inside "where is"
        pattern = re.escape(value.lower().replace("\u2019", "'"))
        if value[:1].isalpha():
            pattern = r"(?<![a-z])" + pattern
        if re.search(pattern, text):
            failures.append(f"contains {value}")
    list_lines = sum(1 for line in answer.splitlines() if LIST_LINE.match(line))
    if list_lines < case.get("min_list", 0):
        failures.append(f"list lines {list_lines} < {case['min_list']}")
    if "max_list" in case and list_lines > case["max_list"]:
        failures.append(f"list lines {list_lines} > {case['max_list']}")
    paragraphs = len([block for block in re.split(r"\n\s*\n", answer.strip()) if block.strip()])
    if paragraphs < case.get("min_paragraphs", 0):
        failures.append(f"paragraphs {paragraphs} < {case['min_paragraphs']}")
    if case.get("qmark") and "?" not in answer:
        failures.append("no question mark")
    if "max_ratio" in case and len(answer.split()) > case["max_ratio"] * spoken_words:
        failures.append(f"longer than {case['max_ratio']}x the speech")
    if "```" in answer:
        failures.append("code fence")
    return failures


def rows(path):
    with open(path, encoding="utf-8") as handle:
        return [json.loads(line) for line in handle if line.strip()]


def main(argv):
    paths = [a for a in argv if not a.startswith("--")]
    if len(paths) != 2:
        sys.exit(__doc__)
    cases = {c["id"]: c for c in rows(paths[0])}
    answers = rows(paths[1])
    scorer = score_number if any("expect" in c for c in cases.values()) else score_prompt
    kinds, refused, failed = {}, 0, []
    for result in answers:
        case = cases[result["id"]]
        problems = scorer(case, result["text"])
        used = result.get("usedModel", True)
        refused += 0 if used else 1
        passed, total = kinds.get(case["kind"], (0, 0))
        kinds[case["kind"]] = (passed + (not problems), total + 1)
        if problems:
            failed.append((case, result, problems, used))
    passed_all = sum(p for p, _ in kinds.values())
    print(f"cases {len(answers)} passed {passed_all} refused {refused}")
    print("  " + ", ".join(f"{k} {p}/{t}" for k, (p, t) in sorted(kinds.items())))
    if "--rows" in argv:
        for case, result, problems, used in failed:
            print(f"[{case['id']}] {'; '.join(problems)}{'' if used else ' REFUSED'}")
            print("   in :", case["spoken"])
            print("   out:", result["text"].replace("\n", " | "))


if __name__ == "__main__":
    main(sys.argv[1:])
