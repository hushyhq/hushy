#!/usr/bin/env python3
"""Short invented dictations for named case classes, as one-group training rows (Task 142).

    plan     the seeded slots (shape, setting, role, names, destination, surface); no call
    write    one paid call per slot: `count` invented {spoken, typed} examples of that shape
    rows     after `murmur-eval finetune groups` and `finetune verdicts`: the examples that are one group,
             pass the app's pair check and add no word become group rows in a batch folder

Paid step: the pilot's call step (same client, key handling, ledger, cap and path guards). Invented text only.
"""

import argparse
import json
from pathlib import Path
import random
import re
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))

import api_judge  # noqa: E402
import api_judge_client as client_module  # noqa: E402
import api_judge_guard as guard  # noqa: E402
import api_judge_verdict as verdicts  # noqa: E402
import retrain_groups as groups_lib  # noqa: E402
import retrain_pilot as pilot  # noqa: E402
import retrain_release as release  # noqa: E402
import retrain_scale_pools as pools  # noqa: E402
import retrain_writer as writer  # noqa: E402
from api_judge_guard import GuardError  # noqa: E402

BRIEF = guard.EVALS / "judge" / "CASE-CLASS-INSTRUCTIONS.md"
PROMPT = guard.ROOT / "Evals/finetune-prompts/group-call-system.txt"
SHAPES = ("correction", "stutter", "boundary", "mishearing", "filler")
FAMILIES = ("chat", "email", "note", "agent", "status")
MAX_WORDS = 40  # the app cleans a dictation of at most this many words as one group


def _pool(text):
    return list(text) if not isinstance(text, str) else [i for line in text.strip().splitlines() for i in line.split("|") if i]


def plan(slots_per_shape, count, seed):
    rng = random.Random(seed)
    domains, roles, given = _pool(pools.DOMAINS), _pool(pools.ROLES), _pool(pools.GIVEN_NAMES)
    rng.shuffle(domains)
    rng.shuffle(roles)
    rng.shuffle(given)
    slots = []
    for shape in SHAPES:
        for index in range(slots_per_shape):
            number = len(slots)
            slots.append({"id": f"c{number:03d}", "shape": shape, "setting": domains[number % len(domains)],
                          "role": roles[number % len(roles)],
                          "names": [given[(number * 4 + k) % len(given)] for k in range(4)],
                          "family": FAMILIES[(number + index) % len(FAMILIES)],
                          "surface": "bare" if rng.random() < 0.6 else "punctuated", "count": count})
    return slots


DESTINATIONS = {"chat": "a work chat message", "email": "an email", "note": "a note to self",
                "agent": "a prompt to an AI assistant", "status": "a status update to a team"}


def card(slot):
    return {"shape": slot["shape"], "setting": slot["setting"], "role": slot["role"], "names": slot["names"],
            "destination": DESTINATIONS[slot["family"]], "surface": slot["surface"], "count": slot["count"]}


def schema():
    example = {"type": "object", "properties": {"spoken": {"type": "string"}, "typed": {"type": "string"}},
               "required": ["spoken", "typed"], "additionalProperties": False}
    return {"type": "object", "properties": {"examples": {"type": "array", "items": example}},
            "required": ["examples"], "additionalProperties": False}


def validate(raw):
    if not isinstance(raw, dict) or set(raw) != {"examples"} or not isinstance(raw["examples"], list) or not raw["examples"]:
        raise verdicts.VerdictError("need a non-empty examples list")
    out = []
    for item in raw["examples"]:
        if not isinstance(item, dict) or set(item) != {"spoken", "typed"} or type(item["spoken"]) is not str \
                or type(item["typed"]) is not str:
            raise verdicts.VerdictError("an example needs spoken and typed strings")
        out.append({"spoken": " ".join(item["spoken"].split()), "typed": " ".join(item["typed"].split())})
    return {"examples": out}


class CasesRunner(writer.WriterRunner):
    validate = staticmethod(validate)
    tool = "retrain_case_classes"


def run_write(args):
    scratch = guard.scratch_roots(args.scratch_dir)
    pilot.check_run_flags(args)
    slots = plan(args.slots, args.count, args.seed)
    outcome = pilot.call_step(args, scratch, slots, card, schema(), validate, CasesRunner, BRIEF,
                              "Write the examples for this card.")
    if outcome is None:
        return 0
    results, dollars, fatal = outcome
    sources = []
    for slot, result in zip(slots, results):
        for number, example in enumerate(result["written"]["examples"] if result["written"] else []):
            words = len(example["spoken"].split())
            if not example["typed"] or not 6 <= words <= MAX_WORDS:
                continue
            sources.append({"id": f"{slot['id']}x{number:02d}", "route": "case_class", "family": slot["family"],
                            "shape": slot["shape"], "band": [12, 40], "surface": slot["surface"],
                            "spoken": example["spoken"], "typed": example["typed"], "plants": []})
    folder = guard.safe_output(args.out, scratch)
    pilot.write_lines(folder / "sources.all.jsonl", sources)
    pilot.write_lines(folder / "groups_in.jsonl", release.groups_in_rows(sources))
    pilot.write_lines(folder / "verdicts_in.jsonl",
                      [{"id": s["id"], "raw": s["spoken"], "target": s["typed"], "bundle": release.bundle_for(s["family"])}
                       for s in sources])
    print(f"case classes: {len(slots)} calls, {len(sources)} examples kept by length; ${dollars:.4f}")
    return 2 if fatal else 0


WORD = re.compile(r"[a-z0-9]+(?:'[a-z]+)?")


def added_words(source, draft):
    """Words of the typed text that are in neither the speech nor the draft (ignoring case and punctuation)."""
    known = set(WORD.findall((source["spoken"] + " " + draft).lower().replace("’", "'")))
    return [w for w in WORD.findall(source["typed"].lower().replace("’", "'")) if w not in known]


def run_rows(args):
    scratch = guard.scratch_roots(args.scratch_dir)
    folder = guard.check_path(args.out, scratch, "batch folder")
    sources = pilot.read_lines(folder / "sources.all.jsonl", scratch)
    groups = {g["id"]: g for g in pilot.read_lines(folder / "groups.jsonl", scratch)}
    verdict = {v["id"]: release.release_verdict(v) for v in pilot.read_lines(folder / "verdicts.jsonl", scratch)}
    system = groups_lib.prompt_sections(PROMPT)
    kept, rows, dropped = [], [], []
    for source in sources:
        group_row, result = groups.get(source["id"]), verdict.get(source["id"])
        reason = None
        if group_row is None or group_row.get("groupCount") != 1:
            reason = "not one group"
        elif result is None or result["status"] != "accepted":
            reason = f"pair check: {release.reason_key(result['reason']) if result else 'not run'}"
        elif source["shape"] != "mishearing" and len(added_words(source, group_row["groups"][0]["draft"])) > 2:
            reason = "adds words"
        if reason:
            dropped.append({"id": source["id"], "shape": source["shape"], "reason": reason})
            continue
        piece = {"piece": source["typed"], "new_paragraph": False}
        rows.append(groups_lib.group_row(source, group_row["groups"][0], "", piece, system))
        kept.append(source)
    pilot.write_lines(folder / "sources.jsonl", kept)
    pilot.write_lines(folder / "batch.group_rows.jsonl", rows)
    pilot.write_lines(folder / "dropped.jsonl", dropped)
    by_shape = {shape: [sum(s["shape"] == shape for s in kept), sum(s["shape"] == shape for s in sources)] for shape in SHAPES}
    reasons = {}
    for item in dropped:
        key = f"{item['shape']}: {item['reason']}"
        reasons[key] = reasons.get(key, 0) + 1
    summary = {"examples": len(sources), "rows": len(rows), "kept_of_written_by_shape": by_shape,
               "dropped": dict(sorted(reasons.items(), key=lambda kv: -kv[1]))}
    (folder / "summary.json").write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(summary))
    return 0


def parser():
    cli = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = cli.add_subparsers(dest="command", required=True)
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--scratch-dir", action="append", default=[])
    common.add_argument("--out", required=True, help="batch folder under Evals/runs/retrain")
    write = commands.add_parser("write", parents=[common])
    write.add_argument("--slots", type=int, default=5, help="calls per shape")
    write.add_argument("--count", type=int, default=16, help="examples per call")
    write.add_argument("--seed", type=int, default=11)
    write.add_argument("--invented-or-public", action="store_true")
    write.add_argument("--model", default=writer.DEFAULT_MODEL)
    write.add_argument("--max-dollars", type=float)
    write.add_argument("--scale-run", action="store_true")
    write.add_argument("--dry-run", action="store_true")
    write.add_argument("--state-dir", required=True)
    write.add_argument("--key-file", default=guard.DEFAULT_KEY_FILE)
    write.add_argument("--base-url", default=f"https://{client_module.API_HOST}")
    write.add_argument("--workers", type=int, default=4)
    write.add_argument("--max-tokens", type=int, default=6_000)
    write.add_argument("--effort", choices=("low", "medium", "high", "xhigh", "max"))
    write.add_argument("--est-output-tokens", type=int, default=2_000)
    write.add_argument("--max-retries", type=int, default=5)
    write.add_argument("--timeout", type=float, default=300.0)
    client_module.add_prompt_cache_flag(write)
    commands.add_parser("rows", parents=[common])
    return cli


def main(argv=None):
    args = parser().parse_args(argv)
    try:
        return {"write": run_write, "rows": run_rows}[args.command](args)
    except (writer.WriterError, GuardError, api_judge.JudgeError, verdicts.VerdictError, OSError, KeyError) as exc:
        print(f"retrain-cases: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
