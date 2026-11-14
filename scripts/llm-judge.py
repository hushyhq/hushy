#!/usr/bin/env python3
"""Judge synthetic dev evals only; never send real dictations or sealed cases to a model.

Build and run accept inputs only from this repository's Evals directory. The
report case file must be explicitly allowlisted, and sealed_guard checks bytes.
"""

import argparse
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile

from sealed_guard import SealedEvalRefusal, assert_tuning_safe


ROOT = Path(__file__).resolve().parent.parent
EVALS = ROOT / "Evals"
RUBRIC = EVALS / "judge" / "RUBRIC.md"
ALLOWED_CASE_FILES = {"developer-messages-dev.json"}
INPUT_FIELDS = ("n", "id", "level", "app", "windowTitle", "destination", "spoken", "written")
TAGS = {
    "meaning_changed", "content_added", "content_dropped", "filler_left",
    "technical_token_wrong", "capital_or_punctuation", "layout", "tone", "other",
}


class JudgeError(Exception):
    """A report, judge input, or verdict cannot be used."""


# Substrings. `voicelab` is included here even though sealed_guard's filename prefixes omit it.
_FORBIDDEN_NAME_PARTS = (
    "heldout", "sealed", "voicelab", "voice-lab", "voice_lab", "ab-", "eval-long64-b", "longb",
)


def refuse_sealed_name(path):
    for name in (str(path), str(Path(path).resolve())):
        lowered = name.lower()
        if any(part in lowered for part in _FORBIDDEN_NAME_PARTS):
            raise JudgeError(f"refused path containing a sealed name: {path}")


def safe_read(path):
    """Every file this script opens: refused by name, then by sealed-set contents."""
    refuse_sealed_name(path)
    checked = Path(path).resolve()
    if not checked.is_file():
        raise JudgeError(f"file does not exist: {path}")
    assert_tuning_safe(checked, purpose="LLM judge")
    return checked


def safe_source(path):
    """Files whose contents can reach a judge model: only from this repository's Evals/."""
    source = safe_read(path)
    if not source.is_relative_to(EVALS):
        raise JudgeError(f"refused file outside repository Evals/: {path}")
    return source


def safe_output(path):
    refuse_sealed_name(path)


def load_json(path, source=False):
    checked = safe_source(path) if source else safe_read(path)
    try:
        with checked.open(encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise JudgeError(f"cannot read JSON {path}: {exc}") from exc


def validate_report(report):
    if not isinstance(report, dict) or not isinstance(report.get("caseFile"), str):
        raise JudgeError("report needs a caseFile string")
    basename = Path(report["caseFile"]).name
    if basename not in ALLOWED_CASE_FILES:
        raise JudgeError(f"refused report caseFile: {basename}")
    if not isinstance(report.get("cases"), list):
        raise JudgeError("report needs a cases array")
    return report["cases"]


def validate_input(items):
    if not isinstance(items, list) or not items:
        raise JudgeError("judge input must be a nonempty JSON array")
    for n, item in enumerate(items, 1):
        if not isinstance(item, dict) or set(item) != set(INPUT_FIELDS):
            raise JudgeError(f"input item {n} has wrong fields")
        if type(item["n"]) is not int or item["n"] != n:
            raise JudgeError(f"input item {n} has wrong n")
        if any(not isinstance(item[key], str) for key in INPUT_FIELDS[1:]):
            raise JudgeError(f"input item {n} needs string fields")
    return items


def make_input(cases):
    items = []
    for n, case in enumerate(cases, 1):
        if not isinstance(case, dict):
            raise JudgeError(f"report case {n} is not an object")
        try:
            items.append(dict(n=n, id=case["id"], level=case["level"],
                              app=case["bundleID"], windowTitle=case["windowTitle"],
                              destination=case["expectedCategory"], spoken=case["input"],
                              written=case["output"]))
        except KeyError as exc:
            raise JudgeError(f"report case {n} is missing {exc}") from exc
    return validate_input(items)


def validate_verdicts(items, verdicts):
    if not isinstance(verdicts, list) or len(verdicts) != len(items):
        raise JudgeError(f"verdict count must be {len(items)}")
    for index, (item, verdict) in enumerate(zip(items, verdicts), 1):
        if not isinstance(verdict, dict):
            raise JudgeError(f"verdict {index} must be an object")
        for key in ("n", "id", "level"):
            if type(verdict.get(key)) is not type(item[key]) or verdict[key] != item[key]:
                raise JudgeError(f"verdict {index} has wrong {key} or order")
        for key in ("faithful", "mechanics", "sendable"):
            if type(verdict.get(key)) is not bool:
                raise JudgeError(f"verdict {index} needs boolean {key}")
        problems = verdict.get("problems")
        if not isinstance(problems, list) or any(type(tag) is not str or tag not in TAGS for tag in problems):
            raise JudgeError(f"verdict {index} has unknown or invalid problem tag")
        if not isinstance(verdict.get("note"), str):
            raise JudgeError(f"verdict {index} needs a string note")
    return verdicts


def write_json(path, value):
    with Path(path).open("w", encoding="utf-8") as handle:
        json.dump(value, handle, indent=2, ensure_ascii=False)
        handle.write("\n")


def build(args):
    safe_output(args.out)
    report = load_json(args.report, source=True)
    items = make_input(validate_report(report))
    write_json(args.out, items)


def run(args):
    safe_output(args.out)
    items = validate_input(load_json(args.input, source=True))
    with tempfile.TemporaryDirectory(prefix="llm-judge-") as directory:
        tmp = Path(directory)
        rubric = RUBRIC.read_text(encoding="utf-8")
        if rubric.count("{{ITEM_COUNT}}") != 1:
            raise JudgeError("rubric must have exactly one item-count placeholder")
        (tmp / "RUBRIC.md").write_text(rubric.replace("{{ITEM_COUNT}}", str(len(items))), encoding="utf-8")
        shutil.copyfile(safe_source(args.input), tmp / "judge_input.json")
        prompt = ("Follow RUBRIC.md in this directory exactly. Your final message must be only "
                  f"the JSON array described there, covering all {len(items)} items of judge_input.json.")
        command = (shlex.split(args.judge_cmd) + [directory] if args.judge_cmd else
                   ["codex", "exec", "-m", args.model, "-s", "read-only",
                    "--skip-git-repo-check", "-C", directory, "-o", str(tmp / "verdicts.json"), prompt])
        with open(os.devnull, "rb") as null:
            result = subprocess.run(command, cwd=directory, stdin=null, check=False)
        if result.returncode:
            raise JudgeError(f"judge command failed with exit code {result.returncode}")
        verdict_path = tmp / "verdicts.json"
        verdicts = validate_verdicts(items, load_json(verdict_path))
        write_json(args.out, verdicts)


def counts(items, verdicts):
    levels = {}
    for item, verdict in zip(items, verdicts):
        row = levels.setdefault(item["level"], dict(total=0, faithful=0, mechanics=0,
                                                       sendable=0, good=0, problems={}))
        row["total"] += 1
        for key in ("faithful", "mechanics", "sendable"):
            row[key] += verdict[key]
        row["good"] += verdict["faithful"] and verdict["mechanics"]
        for tag in verdict["problems"]:
            row["problems"][tag] = row["problems"].get(tag, 0) + 1
    return levels


def rule_comparison(items, verdicts, report):
    cases = validate_report(report)
    if len(cases) != len(items):
        raise JudgeError("report and input have different case counts")
    result = {}
    for index, (item, verdict, case) in enumerate(zip(items, verdicts, cases), 1):
        if case.get("id") != item["id"] or case.get("level") != item["level"]:
            raise JudgeError(f"report and input disagree at item {index}")
        if type(case.get("passed")) is not bool:
            raise JudgeError(f"report case {index} needs boolean passed")
        row = result.setdefault(item["level"], dict(rule_pass=0, rules_only=[], judge_only=[]))
        good = verdict["faithful"] and verdict["mechanics"]
        row["rule_pass"] += case["passed"]
        if case["passed"] and not good:
            row["rules_only"].append(item["id"])
        if good and not case["passed"]:
            row["judge_only"].append(item["id"])
    return result


def before_comparison(items, verdicts, old_items, old_verdicts):
    if len(items) != len(old_items):
        raise JudgeError("before and after have different item counts")
    result = {}
    for index, (item, verdict, old, prior) in enumerate(zip(items, verdicts, old_items, old_verdicts), 1):
        if (item["id"], item["level"]) != (old["id"], old["level"]):
            raise JudgeError(f"before and after disagree at item {index}")
        row = result.setdefault(item["level"], dict(unchanged_outputs=0,
                                                      changed_good_on_unchanged_outputs=[]))
        if item["written"] == old["written"]:
            row["unchanged_outputs"] += 1
            good = verdict["faithful"] and verdict["mechanics"]
            old_good = prior["faithful"] and prior["mechanics"]
            if good != old_good:
                row["changed_good_on_unchanged_outputs"].append(item["id"])
    return result


def summarise(args):
    items = validate_input(load_json(args.input, source=True))
    verdicts = validate_verdicts(items, load_json(args.verdicts))
    summary = {"levels": counts(items, verdicts)}
    if args.report:
        summary["rules"] = rule_comparison(items, verdicts, load_json(args.report, source=True))
    if args.before_input:
        old = validate_input(load_json(args.before_input, source=True))
        prior = validate_verdicts(old, load_json(args.before_verdicts))
        summary["before_levels"] = counts(old, prior)
        summary["repeatability"] = before_comparison(items, verdicts, old, prior)
    if args.json:
        print(json.dumps(summary, indent=2, ensure_ascii=False))
    else:
        for level, row in summary["levels"].items():
            print(f"{level}: faithful {row['faithful']}/{row['total']}, mechanics "
                  f"{row['mechanics']}/{row['total']}, sendable {row['sendable']}/{row['total']}, "
                  f"good {row['good']}/{row['total']}; problems {row['problems']}")
            if args.report:
                rule = summary["rules"][level]
                print(f"  rules {rule['rule_pass']}/{row['total']}; rules only "
                      f"{len(rule['rules_only'])}: {rule['rules_only']}; judge only "
                      f"{len(rule['judge_only'])}: {rule['judge_only']}")
            if args.before_input:
                old = summary["before_levels"][level]
                repeat = summary["repeatability"][level]
                print(f"  before -> after: faithful {old['faithful']} -> {row['faithful']}, "
                      f"mechanics {old['mechanics']} -> {row['mechanics']}, "
                      f"sendable {old['sendable']} -> {row['sendable']}, good {old['good']} -> {row['good']}")
                print(f"  problems before -> after: {old['problems']} -> {row['problems']}")
                print(f"  changed good on identical written: "
                      f"{len(repeat['changed_good_on_unchanged_outputs'])}/{repeat['unchanged_outputs']}: "
                      f"{repeat['changed_good_on_unchanged_outputs']}")


def parser():
    cli = argparse.ArgumentParser(description=__doc__)
    commands = cli.add_subparsers(dest="command", required=True)
    builder = commands.add_parser("build")
    builder.add_argument("--report", required=True)
    builder.add_argument("--out", required=True)
    runner = commands.add_parser("run")
    runner.add_argument("--input", required=True)
    runner.add_argument("--out", required=True)
    runner.add_argument("--model", default="gpt-6-sol")
    runner.add_argument("--judge-cmd")
    summary = commands.add_parser("summarise")
    summary.add_argument("--input", required=True)
    summary.add_argument("--verdicts", required=True)
    summary.add_argument("--report")
    summary.add_argument("--before-input")
    summary.add_argument("--before-verdicts")
    summary.add_argument("--json", action="store_true")
    return cli


def main():
    cli = parser()
    args = cli.parse_args()
    if bool(getattr(args, "before_input", None)) != bool(getattr(args, "before_verdicts", None)):
        cli.error("--before-input and --before-verdicts must be given together")
    try:
        {"build": build, "run": run, "summarise": summarise}[args.command](args)
    except (JudgeError, SealedEvalRefusal, OSError, ValueError) as exc:
        print(f"llm-judge: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
