#!/usr/bin/env python3
"""The rewrite-to-intent measurement (Task 142): a strong model as the ceiling, and a blind judge.

    ceiling  a strong model rewrites each case's transcript under Evals/judge/INTENT-LADDER-INSTRUCTIONS.md
    judge    every arm's text for a case goes to the judge together, in a seeded shuffled order under letter
             labels; meaning (facts missing, changed, invented) and writing (reads, register) are scored apart
    summary  the judge's rows as a table per arm
    muddle   a paid writer invents muddled dictations with the facts the speaker settled on (pilot data)
    rows     pilot training rows: the muddled dictations whose rewrite a fact check passed in full
    facts    a strong model lists the checkable facts of each case that has none (real speech from public
             corpora), under Evals/judge/INTENT-FACTS-INSTRUCTIONS.md; the output is the case plus `facts`
    pick-groups  choose whole groups of cases (for example meetings) at random, or drop them; no model call

An arm is NAME=PATH: a long-dictation report (a JSON list of {id, output}) or JSON lines of {id, text}.
Paid steps reuse the pilot's call step (client, key handling, ledger, cap, path guards). Invented text only.
"""

import argparse
import json
from pathlib import Path
import random
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))

import api_judge  # noqa: E402
import api_judge_client as client_module  # noqa: E402
import api_judge_guard as guard  # noqa: E402
import api_judge_verdict as verdicts  # noqa: E402
import retrain_intent_pick as picker  # noqa: E402
import retrain_pilot as pilot  # noqa: E402
import retrain_writer as writer  # noqa: E402
from api_judge_guard import GuardError  # noqa: E402

LADDER = guard.EVALS / "judge" / "INTENT-LADDER-INSTRUCTIONS.md"
RUBRIC = guard.EVALS / "judge" / "INTENT-JUDGE-RUBRIC.md"
REGISTERS = ("refined", "professional", "casual")


def text_schema():
    return {"type": "object", "properties": {"text": {"type": "string"}}, "required": ["text"], "additionalProperties": False}


def validate_text(raw):
    if not isinstance(raw, dict) or set(raw) != {"text"} or type(raw["text"]) is not str or not raw["text"].strip():
        raise verdicts.VerdictError("need a non-empty text")
    return {"text": raw["text"].strip()}


class CeilingRunner(writer.WriterRunner):
    validate = staticmethod(validate_text)
    tool = "retrain_intent_ceiling"


def run_ceiling(args):
    scratch = guard.scratch_roots(args.scratch_dir)
    pilot.check_run_flags(args)
    cases = pilot.read_lines(args.cases, scratch)
    outcome = pilot.call_step(
        args, scratch, cases,
        lambda c: {"setting": args.register, "destination": c.get("domain", "a message"), "transcript": c["spoken"]},
        text_schema(), validate_text, CeilingRunner, LADDER, "Write the message.")
    if outcome is None:
        return 0
    results, dollars, fatal = outcome
    rows = [{"id": c["id"], "text": r["written"]["text"]} for c, r in zip(cases, results) if r["written"]]
    pilot.write_lines(guard.safe_output(args.out, scratch), rows)
    print(f"ceiling ({args.register}): {len(rows)} of {len(cases)} written; ${dollars:.4f}")
    return 2 if fatal else 0


def read_arm(path, scratch):
    rows = api_judge.read_json_or_lines(guard.safe_input(path, scratch))
    return {r["id"]: (r["text"] if "text" in r else r["output"]) for r in rows}


def judge_schema():
    ints = {"type": "array", "items": {"type": "integer"}}
    candidate = {"type": "object",
                 "properties": {"label": {"type": "string"}, "facts_missing": ints, "facts_changed": ints,
                                "invented": {"type": "array", "items": {"type": "string"}},
                                "reads": {"type": "integer"}, "register": {"type": "integer"}},
                 "required": ["label", "facts_missing", "facts_changed", "invented", "reads", "register"],
                 "additionalProperties": False}
    return {"type": "object", "properties": {"candidates": {"type": "array", "items": candidate}},
            "required": ["candidates"], "additionalProperties": False}


def validate_judgement(raw):
    if not isinstance(raw, dict) or not isinstance(raw.get("candidates"), list) or not raw["candidates"]:
        raise verdicts.VerdictError("need candidates")
    for item in raw["candidates"]:
        if not isinstance(item, dict) or type(item.get("label")) is not str or type(item.get("reads")) is not int \
                or type(item.get("register")) is not int or not 1 <= item["reads"] <= 5 or not 1 <= item["register"] <= 5 \
                or not all(isinstance(item.get(k), list) for k in ("facts_missing", "facts_changed", "invented")):
            raise verdicts.VerdictError("a candidate judgement has the wrong fields")
    return {"candidates": raw["candidates"]}


class JudgeRunner(writer.WriterRunner):
    validate = staticmethod(validate_judgement)
    tool = "retrain_intent_judge"


def blind_items(cases, arms, register, seed):
    """One item per case: the card the judge sees and, kept apart, which letter is which arm."""
    rng = random.Random(seed)
    items = []
    for case in cases:
        names = [n for n in arms if case["id"] in arms[n]]
        rng.shuffle(names)
        letters = {chr(65 + i): name for i, name in enumerate(names)}
        items.append({"id": case["id"], "letters": letters, "facts": len(case["facts"]),
                      "card": {"transcript": case["spoken"], "register": register,
                               "facts": [f"{i}. {fact}" for i, fact in enumerate(case["facts"], 1)],
                               "candidates": [{"label": letter, "text": arms[name][case["id"]]}
                                              for letter, name in letters.items()]}})
    return items


def run_judge(args):
    scratch = guard.scratch_roots(args.scratch_dir)
    pilot.check_run_flags(args)
    cases = pilot.read_lines(args.cases, scratch)
    arms = {}
    for spec in args.arm:
        name, path = spec.split("=", 1)
        arms[name] = read_arm(path, scratch)
    items = blind_items(cases, arms, args.register, args.seed)
    outcome = pilot.call_step(args, scratch, items, lambda item: item["card"], judge_schema(), validate_judgement,
                              JudgeRunner, RUBRIC, "Judge every candidate.")
    if outcome is None:
        return 0
    results, dollars, fatal = outcome
    rows = []
    for item, result in zip(items, results):
        for judged in (result["written"]["candidates"] if result["written"] else []):
            arm = item["letters"].get(judged["label"])
            if arm:
                rows.append({"id": item["id"], "arm": arm, "facts": item["facts"],
                             **{k: judged[k] for k in ("facts_missing", "facts_changed", "invented", "reads", "register")}})
    pilot.write_lines(guard.safe_output(args.out, scratch), rows)
    print(f"judge: {len(items)} cases, {len(rows)} judgements; ${dollars:.4f}")
    print(summary(rows))
    return 2 if fatal else 0


def summary(rows):
    lines = ["| arm | cases | facts kept | cases with every fact intact | cases with something invented | reads (mean) | reads 4 or 5 | register (mean) |",
             "|---|---|---|---|---|---|---|---|"]
    for arm in sorted({r["arm"] for r in rows}):
        mine = [r for r in rows if r["arm"] == arm]
        facts = sum(r["facts"] for r in mine)
        lost = sum(len(set(r["facts_missing"]) | set(r["facts_changed"])) for r in mine)
        intact = sum(not r["facts_missing"] and not r["facts_changed"] for r in mine)
        lines.append(f"| {arm} | {len(mine)} | {facts - lost} of {facts} | {intact} | {sum(bool(r['invented']) for r in mine)} | "
                     f"{sum(r['reads'] for r in mine) / len(mine):.2f} | {sum(r['reads'] >= 4 for r in mine)} | "
                     f"{sum(r['register'] for r in mine) / len(mine):.2f} |")
    return "\n".join(lines)


def run_summary(args):
    scratch = guard.scratch_roots(args.scratch_dir)
    rows = pilot.read_lines(args.rows, scratch)
    for label, keep in (("all", lambda r: True), ("short", lambda r: "-s" in r["id"]), ("long", lambda r: "-l" in r["id"])):
        part = [r for r in rows if keep(r)]
        if part:
            print(f"\n{label}\n{summary(part)}")
    return 0


# ---- pilot data: invented muddled dictations ------------------------------------------------------------

MUDDLE = guard.EVALS / "judge" / "MUDDLE-WRITER-INSTRUCTIONS.md"
INTENT_PROMPT = guard.ROOT / "Evals/finetune-prompts/intent-call-system.txt"
DESTINATIONS = ("a work chat message", "an email to a colleague", "a note to self", "a prompt to an AI assistant",
                "a status update to a team", "a message to a client", "a complaint to a company", "a request to a manager",
                "a message to a friend or family member")


# What a focused card asks the writer to build the dictation around (the brief's "focus" section). Each is a
# way round 3 changed meaning on long real speech: a rare term respelled, a phrase attached to the wrong
# sentence, a sound-alike left or wrongly repaired, a self-correction kept.
FOCUSES = ("terms", "readout", "soundalike", "corrections")


def muddle_plan(short_calls, long_calls, seed, focus_calls=0):
    import retrain_scale_pools as pools
    rng = random.Random(seed)
    domains, roles, given = list(pools.DOMAINS), list(pools.ROLES), list(pools.GIVEN_NAMES)
    for pool in (domains, roles, given):
        rng.shuffle(pool)
    slots = []
    for length, calls, count in (("short", short_calls, 12), ("long", long_calls, 8)):
        for _ in range(calls):
            n = len(slots)
            slots.append({"id": f"m{n:03d}", "length": length, "count": count, "setting": domains[n % len(domains)],
                          "role": roles[n % len(roles)], "names": [given[(n * 5 + k) % len(given)] for k in range(5)],
                          "destination": DESTINATIONS[n % len(DESTINATIONS)], "slips": n % 2 == 0,
                          "surface": "bare" if rng.random() < 0.65 else "punctuated"})
    for k in range(focus_calls):
        n = len(slots)
        slots.append({"id": f"f{k:03d}", "length": "long", "count": 4, "setting": domains[n % len(domains)],
                      "role": roles[n % len(roles)], "names": [given[(n * 5 + j) % len(given)] for j in range(5)],
                      "destination": DESTINATIONS[n % len(DESTINATIONS)], "slips": FOCUSES[k % len(FOCUSES)] == "soundalike",
                      "surface": "bare" if rng.random() < 0.8 else "punctuated", "focus": FOCUSES[k % len(FOCUSES)]})
    return slots


def muddle_schema():
    example = {"type": "object", "properties": {"spoken": {"type": "string"},
                                                "facts": {"type": "array", "items": {"type": "string"}}},
               "required": ["spoken", "facts"], "additionalProperties": False}
    return {"type": "object", "properties": {"examples": {"type": "array", "items": example}},
            "required": ["examples"], "additionalProperties": False}


def validate_muddle(raw):
    if not isinstance(raw, dict) or not isinstance(raw.get("examples"), list) or not raw["examples"]:
        raise verdicts.VerdictError("need examples")
    out = []
    for item in raw["examples"]:
        if not isinstance(item, dict) or type(item.get("spoken")) is not str or not isinstance(item.get("facts"), list) \
                or not item["facts"] or not all(type(f) is str for f in item["facts"]):
            raise verdicts.VerdictError("an example needs spoken and facts")
        out.append({"spoken": " ".join(item["spoken"].split()), "facts": item["facts"]})
    return {"examples": out}


class MuddleRunner(writer.WriterRunner):
    validate = staticmethod(validate_muddle)
    tool = "retrain_muddle_writer"


def shingles(text, size=6):
    words = "".join(c if c.isalnum() or c == "'" else " " for c in text.lower()).split()
    return {" ".join(words[i:i + size]) for i in range(len(words) - size + 1)}


def run_muddle(args):
    scratch = guard.scratch_roots(args.scratch_dir)
    pilot.check_run_flags(args)
    slots = muddle_plan(args.short_calls, args.long_calls, args.seed, args.focus_calls)
    held = set()
    for path in args.keep_out:
        for case in pilot.read_lines(path, scratch):
            held |= shingles(case["spoken"])
    outcome = pilot.call_step(args, scratch, slots, lambda s: {k: s[k] for k in s if k != "id"}, muddle_schema(),
                              validate_muddle, MuddleRunner, MUDDLE, "Write the dictations for this card.")
    if outcome is None:
        return 0
    results, dollars, fatal = outcome
    cases, refused = [], 0
    for slot, result in zip(slots, results):
        for number, example in enumerate(result["written"]["examples"] if result["written"] else []):
            words = len(example["spoken"].split())
            low, high = (18, 60) if slot["length"] == "short" else (80, 200)
            if not low <= words <= high or shingles(example["spoken"]) & held:
                refused += 1
                continue
            cases.append({"id": f"{slot['id']}x{number:02d}", "domain": slot["destination"], "length": slot["length"],
                          "slips": slot["slips"], "spoken": example["spoken"], "facts": example["facts"],
                          **({"focus": slot["focus"]} if "focus" in slot else {})})
    pilot.write_lines(guard.safe_output(args.out, scratch), cases)
    print(f"muddle: {len(slots)} calls, {len(cases)} dictations kept, {refused} refused by length or overlap; ${dollars:.4f}")
    return 2 if fatal else 0


def run_rows(args):
    scratch = guard.scratch_roots(args.scratch_dir)
    import retrain_groups
    system = retrain_groups.prompt_sections(INTENT_PROMPT)
    cases = {c["id"]: c for c in pilot.read_lines(args.cases, scratch)}
    labels = {r["id"]: r["text"] for r in pilot.read_lines(args.labels, scratch)}
    checks = {r["id"]: r for r in pilot.read_lines(args.checks, scratch)}
    rows, dropped = [], {"no label or check": 0, "fact missing": 0, "fact changed": 0, "invented": 0}
    for ident, case in cases.items():
        check = checks.get(ident)
        if ident not in labels or check is None:
            dropped["no label or check"] += 1
        elif check["facts_missing"]:
            dropped["fact missing"] += 1
        elif check["facts_changed"]:
            dropped["fact changed"] += 1
        elif check["invented"]:
            dropped["invented"] += 1
        else:
            answer = json.dumps({"text": labels[ident]}, ensure_ascii=False, separators=(",", ":"))
            for copy in range(args.copies):
                rows.append({"id": f"{ident}-intent{copy}", "passage": f"intent:{ident}", "arm": "intent",
                             "source": "intent_rewrite",
                             "messages": [{"role": "system", "content": system},
                                          {"role": "user", "content": f"Transcript: {case['spoken']}\nOutput:"},
                                          {"role": "assistant", "content": answer}]})
    pilot.write_lines(guard.safe_output(args.out, scratch), rows)
    print(json.dumps({"dictations": len(cases), "kept": len(rows) // args.copies, "rows": len(rows), "dropped": dropped}))
    return 0


# ---- facts for cases that have none (real speech from public corpora) -----------------------------------

FACTS = guard.EVALS / "judge" / "INTENT-FACTS-INSTRUCTIONS.md"
FACTS_MAX = 14          # the brief's upper limit; the bounds live here because the API's schema cannot carry them
FACT_MAX_CHARS = 240


def facts_schema():
    return {"type": "object", "properties": {"facts": {"type": "array", "items": {"type": "string"}}},
            "required": ["facts"], "additionalProperties": False}


def validate_facts(raw):
    if not isinstance(raw, dict) or set(raw) != {"facts"} or not isinstance(raw["facts"], list):
        raise verdicts.VerdictError("need a facts list and nothing else")
    if not 1 <= len(raw["facts"]) <= FACTS_MAX:
        raise verdicts.VerdictError(f"need between 1 and {FACTS_MAX} facts")
    if not all(type(fact) is str for fact in raw["facts"]):
        raise verdicts.VerdictError("every fact must be text")
    facts = [" ".join(fact.split()) for fact in raw["facts"]]
    if not all(0 < len(fact) <= FACT_MAX_CHARS for fact in facts):
        raise verdicts.VerdictError(f"every fact must be non-empty and at most {FACT_MAX_CHARS} characters")
    return {"facts": facts}


class FactsRunner(writer.WriterRunner):
    validate = staticmethod(validate_facts)
    tool = "retrain_intent_facts"


def facts_card(case):
    return {"context": case.get("domain") or case.get("source") or "speech", "transcript": case["spoken"]}


def check_fact_cases(cases):
    seen = set()
    for case in cases:
        if not isinstance(case, dict) or type(case.get("id")) is not str or not case["id"]:
            raise writer.WriterError("every case needs an id")
        if type(case.get("spoken")) is not str or not case["spoken"].strip():
            raise writer.WriterError(f"case {case['id']} has no spoken text")
        if case["id"] in seen:
            raise writer.WriterError(f"case id {case['id']} appears twice")
        seen.add(case["id"])


def left_out(results):
    """How many cases got no facts, and why, for the printed summary."""
    reasons = sorted(r["status"] for r in results if not r["written"])
    if not reasons:
        return "0 left out"
    return f"{len(reasons)} left out ({', '.join(f'{reasons.count(s)} {s}' for s in dict.fromkeys(reasons))})"


def run_facts(args):
    scratch = guard.scratch_roots(args.scratch_dir)
    pilot.check_run_flags(args)
    cases = pilot.read_lines(args.cases, scratch)
    check_fact_cases(cases)
    outcome = pilot.call_step(args, scratch, cases, facts_card, facts_schema(), validate_facts, FactsRunner, FACTS,
                              "List the facts.")
    if outcome is None:
        return 0
    results, dollars, fatal = outcome
    rows = [{**c, "facts": r["written"]["facts"]} for c, r in zip(cases, results) if r["written"]]
    pilot.write_lines(guard.safe_output(args.out, scratch), rows)
    replaced = sum("facts" in c for c, r in zip(cases, results) if r["written"])
    print(f"facts: {len(rows)} of {len(cases)} cases written, {left_out(results)}; ${dollars:.4f}"
          + (f" ({replaced} already had facts, replaced)" if replaced else ""))
    return 2 if fatal else 0


def parser():
    cli = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = cli.add_subparsers(dest="command", required=True)
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--scratch-dir", action="append", default=[])
    calls = argparse.ArgumentParser(add_help=False, parents=[common])
    calls.add_argument("--cases", default="")
    calls.add_argument("--out", required=True)
    calls.add_argument("--register", choices=REGISTERS, default="refined")
    calls.add_argument("--invented-or-public", action="store_true")
    calls.add_argument("--model", default=writer.DEFAULT_MODEL)
    calls.add_argument("--max-dollars", type=float)
    calls.add_argument("--scale-run", action="store_true")
    calls.add_argument("--dry-run", action="store_true")
    calls.add_argument("--state-dir", required=True)
    calls.add_argument("--key-file", default=guard.DEFAULT_KEY_FILE)
    calls.add_argument("--base-url", default=f"https://{client_module.API_HOST}")
    calls.add_argument("--workers", type=int, default=4)
    calls.add_argument("--max-tokens", type=int, default=4_000)
    calls.add_argument("--effort", choices=("low", "medium", "high", "xhigh", "max"))
    calls.add_argument("--est-output-tokens", type=int, default=600)
    calls.add_argument("--max-retries", type=int, default=5)
    calls.add_argument("--timeout", type=float, default=300.0)
    client_module.add_prompt_cache_flag(calls)
    commands.add_parser("ceiling", parents=[calls])
    judge = commands.add_parser("judge", parents=[calls])
    judge.add_argument("--arm", action="append", required=True, metavar="NAME=PATH")
    judge.add_argument("--seed", type=int, default=11)
    muddle = commands.add_parser("muddle", parents=[calls])
    muddle.add_argument("--short-calls", type=int, default=20)
    muddle.add_argument("--long-calls", type=int, default=22)
    muddle.add_argument("--seed", type=int, default=11)
    muddle.add_argument("--focus-calls", type=int, default=0,
                        help="extra long cards, each built around one way meaning gets changed (FOCUSES)")
    muddle.add_argument("--keep-out", action="append", default=[], help="dev cases whose word runs must not appear")
    make = commands.add_parser("rows", parents=[common])
    for name in ("cases", "labels", "checks", "out"):
        make.add_argument(f"--{name}", required=True)
    make.add_argument("--copies", type=int, default=1)
    show = commands.add_parser("summary", parents=[common])
    show.add_argument("--rows", required=True)
    commands.add_parser("facts", parents=[calls])
    picker.add_parser(commands, common)
    return cli


def main(argv=None):
    args = parser().parse_args(argv)
    handlers = {"ceiling": run_ceiling, "judge": run_judge, "summary": run_summary, "muddle": run_muddle, "rows": run_rows,
                "facts": run_facts, "pick-groups": picker.run}
    try:
        return handlers[args.command](args)
    except (writer.WriterError, GuardError, api_judge.JudgeError, verdicts.VerdictError, picker.PickError, OSError,
            KeyError) as exc:
        print(f"retrain-intent: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
