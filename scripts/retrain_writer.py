#!/usr/bin/env python3
"""Asks a model to write the typed version of each spoken passage, then runs the automatic checks.

Reuses the API judge's client, key handling, money ledger and cap, cache and path guards
(scripts/api_judge_*.py). Only invented, public or public-corpus text may be sent: every input and
output path must pass the repository guards and sit in Evals/ or a --scratch-dir, and the operator
states with --invented-or-public that the text is invented or from a public corpus. The key is read from
~/.config/hushy/anthropic_api_key at the first live call, never earlier.

    python3 scripts/retrain_writer.py write --passages P.jsonl --out PREFIX --scratch-dir DIR \\
        --invented-or-public --dry-run --assume 20 500 3000      # calls and estimated cost, nothing sent
    python3 scripts/retrain_writer.py write --passages P.jsonl --out PREFIX --scratch-dir DIR \\
        --invented-or-public --limit 20 --max-dollars 3          # the real batch
    python3 scripts/retrain_writer.py check --rows PREFIX.accepted.jsonl --out PREFIX2 ...   # no API

Passages file (JSONL): {"id": "...", "spoken": "...", optional "ami_layer": {...}, other fields kept}.
Writes PREFIX.accepted.jsonl, PREFIX.quarantine.jsonl (every wrong-looking row, with its reasons), PREFIX.not_typed.jsonl (faithful rows with two
or more garbled spots kept),
PREFIX.failed.jsonl (calls that produced no valid row) and PREFIX.report.json. Nothing is dropped
silently and nothing is repaired.
"""

import argparse
import json
from pathlib import Path
import re
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parent))

import api_judge  # noqa: E402
import api_judge_client as client_module  # noqa: E402
import api_judge_guard as guard  # noqa: E402
import api_judge_verdict as verdicts  # noqa: E402
import retrain_checks as checks  # noqa: E402
from api_judge_client import ApiError, FatalApiError  # noqa: E402
from api_judge_guard import GuardError  # noqa: E402

DEFAULT_INSTRUCTIONS = guard.EVALS / "judge" / "TYPED-WRITER-INSTRUCTIONS.md"
DEFAULT_STATE = guard.EVALS / "runs" / "retrain-writer"
DEFAULT_MODEL = "claude-opus-5-5"
DEFAULT_MAX_TOKENS = 8_000
DEFAULT_EST_OUTPUT_TOKENS = 1_800  # a guess: typed text ~250 tokens, lists ~150, thinking unknown
VERSION_PATTERN = re.compile(r"^Writer version:\s*(\S+)\s*$", re.MULTILINE)
TOP_FIELDS = {"typed", "corrections", "unsure", "usable", "unusable_reason"}
UNSURE_KINDS = ("context", "garbled", "meaning")
GARBLED_LIMIT = 2  # this many "garbled" items mark a row as not reading as typed


class WriterError(Exception):
    """Bad input to the tool (not an API failure)."""


# ---- request and response ------------------------------------------------------------------------

def writer_schema():
    text = {"type": "string"}
    pair = lambda *names: {"type": "object", "properties": {n: text for n in names},  # noqa: E731
                           "required": list(names), "additionalProperties": False}
    return {"type": "object",
            "properties": {"typed": text, "corrections": {"type": "array", "items": pair("said_first", "ended_on")},
                           "unsure": {"type": "array", "items": {
                               "type": "object",
                               "properties": {"kind": {"type": "string", "enum": list(UNSURE_KINDS)},
                                              "quote": text, "note": text},
                               "required": ["kind", "quote", "note"], "additionalProperties": False}},
                           "usable": {"type": "boolean"}, "unusable_reason": text},
            "required": sorted(TOP_FIELDS), "additionalProperties": False}


def instructions_version(text):
    found = VERSION_PATTERN.search(text)
    if not found:
        raise WriterError("instructions have no 'Writer version: <id>' line")
    return found.group(1)


def user_message(spoken):
    if "</spoken>" in spoken:
        raise WriterError("a passage contains the text '</spoken>'")
    return "<spoken>\n" + spoken + "\n</spoken>\n\nWrite the typed version and record it."


def request_body(model, instructions, spoken, max_tokens, effort=None):
    body = {"model": model, "max_tokens": max_tokens, "system": instructions,
            "messages": [{"role": "user", "content": user_message(spoken)}],
            "output_config": {"format": {"type": "json_schema", "schema": writer_schema()}}}
    if effort:
        body["output_config"]["effort"] = effort
    return body


def _pairs(entries, fields, where, kinds=None):
    if not isinstance(entries, list):
        raise verdicts.VerdictError(f"{where} must be a list")
    clean = []
    for entry in entries:
        if not isinstance(entry, dict) or set(entry) != set(fields) \
                or any(type(entry[f]) is not str for f in fields):
            raise verdicts.VerdictError(f"{where} entry has the wrong fields")
        if kinds and entry["kind"] not in kinds:
            raise verdicts.VerdictError(f"{where} entry has an unknown kind")
        clean.append({f: entry[f] for f in fields})
    return clean


def validate_written(raw):
    """A clean copy of a valid writer answer, or VerdictError. Never repaired."""
    if not isinstance(raw, dict) or set(raw) != TOP_FIELDS:
        raise verdicts.VerdictError("writer answer has the wrong top-level fields")
    if type(raw["typed"]) is not str or type(raw["usable"]) is not bool or type(raw["unusable_reason"]) is not str:
        raise verdicts.VerdictError("writer answer has a field of the wrong type")
    return {"typed": raw["typed"], "usable": raw["usable"], "unusable_reason": raw["unusable_reason"],
            "corrections": _pairs(raw["corrections"], ("said_first", "ended_on"), "corrections"),
            "unsure": _pairs(raw["unsure"], ("kind", "quote", "note"), "unsure", UNSURE_KINDS)}


class WriterCache(api_judge.Cache):
    """The judge's on-disk cache, validating writer answers instead of verdicts."""

    def get(self, key):
        try:
            entry = json.loads((self.directory / f"{key}.json").read_text(encoding="utf-8"))
            return {**entry, "written": validate_written(entry["written"])}
        except (OSError, ValueError, KeyError, TypeError, verdicts.VerdictError):
            return None


# ---- input ---------------------------------------------------------------------------------------

def load_passages(path, scratch, limit=None):
    rows = api_judge.read_json_or_lines(guard.safe_input(path, scratch))
    seen = set()
    for number, row in enumerate(rows, 1):
        if not isinstance(row, dict) or not isinstance(row.get("id"), str) or not row["id"]:
            raise WriterError(f"passage {number} needs a non-empty string id")
        if row["id"] in seen:
            raise WriterError(f"duplicate passage id {row['id']!r}")
        seen.add(row["id"])
        if not isinstance(row.get("spoken"), str) or not row["spoken"].strip():
            raise WriterError(f"passage {row['id']} needs non-empty spoken text")
    if not rows:
        raise WriterError("the passages file is empty")
    return rows[:limit] if limit else rows


def plan_tasks(passages, args, instructions, version):
    tasks = []
    for passage in passages:
        body = request_body(args.model, instructions, passage["spoken"], args.max_tokens, args.effort)
        tasks.append({"passage": passage, "body": body, "key": api_judge.cache_key(args.model, version, body)})
    return tasks


# ---- the call loop -------------------------------------------------------------------------------

class WriterRunner:
    validate = staticmethod(validate_written)  # other tools (the pilot's generators) swap in their own
    tool = "retrain_writer"

    def __init__(self, args, cache, ledger, budget, lazy):
        self.args, self.cache, self.ledger, self.budget, self.lazy = args, cache, ledger, budget, lazy
        self.fatal = None
        self.transport_failures = 0

    def execute(self, task):
        entry = self.cache.get(task["key"])
        if entry:
            return {"status": "cached", "written": entry["written"], "usage": self.no_usage(), "error": None}
        if self.fatal or self.budget.exhausted:
            return {"status": "skipped", "written": None, "usage": self.no_usage(),
                    "error": "aborted" if self.fatal else "budget"}
        try:
            return self.call(task)
        except FatalApiError as exc:
            self.fatal = self.fatal or str(exc)
        except GuardError as exc:
            self.fatal = self.fatal or str(exc)
        return {"status": "skipped", "written": None, "usage": self.no_usage(), "error": "aborted"}

    @staticmethod
    def no_usage():
        return {"input_tokens": 0, "output_tokens": 0, "cache_read_tokens": 0, "cache_write_tokens": 0,
                "dollars": 0.0, "request_id": ""}

    def call(self, task):
        body, reason, spent = task["body"], "no response", self.no_usage()
        for attempt in (1, 2):
            wire = client_module.wire_body(body, client_module.prompt_cache_on(self.args))
            worst = client_module.reservation_cost(self.args.model, wire)
            if not self.budget.reserve(worst):
                return {"status": "skipped", "written": None, "usage": spent, "error": "budget"}
            try:
                response, request_id = self.lazy.get().send(wire)
                request_id = api_judge.safe_request_id(request_id)
            except FatalApiError:
                self.budget.release(worst)
                raise
            except ApiError as exc:
                self.budget.release(worst)
                self.transport_failures += 1
                if self.transport_failures >= api_judge.TRANSPORT_FAILURE_LIMIT:
                    self.fatal = f"{api_judge.TRANSPORT_FAILURE_LIMIT} calls in a row failed: {exc}"
                return {"status": "failed", "written": None, "usage": spent, "error": str(exc)}
            self.transport_failures = 0
            spent = self.account(task, response, request_id, worst, spent)
            try:
                written = self.validate(verdicts.extract_verdict(response))
            except verdicts.VerdictError as exc:
                reason = str(exc)
                if response.get("stop_reason") == "max_tokens" and attempt == 1:
                    body = {**body, "max_tokens": min(body["max_tokens"] * 2, api_judge.MAX_TOKENS_CEILING)}
                continue
            self.cache.put(task["key"], {"written": written, "request_id": request_id, "model": self.args.model})
            return {"status": "ok", "written": written, "usage": spent, "error": None}
        return {"status": "failed", "written": None, "usage": spent,
                "error": f"malformed answer after one retry: {reason}"}

    def account(self, task, response, request_id, worst, before):
        usage = response.get("usage")
        known = isinstance(usage, dict) and type(usage.get("output_tokens")) is int
        dollars = client_module.usage_cost(self.args.model, usage) if known else worst
        tokens = client_module._usage_tokens(usage)
        record = {"time": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "tool": self.tool,
                            "model": self.args.model, "item": task["passage"]["id"],
                            "input_tokens": tokens["input"], "output_tokens": tokens["output"],
                            "cache_read_tokens": tokens["cache_read"], "cache_write_tokens": tokens["cache_write"],
                            "dollars": dollars, "usage_missing": not known,
                            "request_id": request_id, "key": task["key"][:12]}
        self.budget.settle(worst, record["dollars"], record if self.budget.ledger else None)
        if not self.budget.ledger:
            self.ledger.append(record)
        return {"input_tokens": before["input_tokens"] + tokens["input"],
                "output_tokens": before["output_tokens"] + tokens["output"],
                "cache_read_tokens": before["cache_read_tokens"] + tokens["cache_read"],
                "cache_write_tokens": before["cache_write_tokens"] + tokens["cache_write"],
                "dollars": before["dollars"] + dollars, "request_id": request_id}


# ---- dry run -------------------------------------------------------------------------------------

def dry_run(args, tasks, cache, ledger=None):
    pending = [t for t in tasks if cache.get(t["key"]) is None]
    print(f"retrain-writer dry run: {len(tasks)} passages, {len(tasks) - len(pending)} already cached, "
          f"{len(pending)} calls to make, model {args.model}")
    if pending:
        per_call = [(client_module.estimate_input_tokens(t["body"]),
                     client_module.estimate_cost(args.model, t["body"], args.est_output_tokens),
                     client_module.reservation_cost(args.model, t["body"])) for t in pending]
        tokens, typical, worst = (sum(x[i] for x in per_call) for i in range(3))
        print(f"  this file: input {tokens} tokens; typical ${typical:.2f} (assumes {args.est_output_tokens} output "
              f"tokens per call, thinking included); worst case reservation ${worst:.2f} (every call hits max_tokens "
              f"{args.max_tokens}, input estimate {client_module.INPUT_RESERVATION_MARGIN:g}x); "
              f"prices as of {client_module.PRICES_AS_OF}")
        mean_typical, mean_worst = typical / len(pending), worst / len(pending)
        for count in args.assume or ():
            print(f"  {count} passages (this file's average, cycled): {count} calls, typical "
                  f"${mean_typical * count:.2f}, worst case ${mean_worst * count:.2f}")
        print(client_module.cache_prefix_line(args.model, pending[0]["body"], len(pending),
                                              client_module.prompt_cache_on(args)))
        print(f"  --max-dollars {args.max_dollars if args.max_dollars is not None else 'required for live run'}; "
              f"suggest at least {typical * 1.5:.2f} for this file")
    spent = ledger.dry_run_total_dollars() if ledger else 0.0
    print(f"  ledger so far ${spent:.2f} (may be stale); remaining "
          f"{'$%.2f' % max(0.0, args.max_dollars - spent) if args.max_dollars is not None else 'unknown without --max-dollars'}")
    print("  nothing was sent; the key file was not opened")


# ---- rows and outputs ----------------------------------------------------------------------------

def taken_back_words(passage):
    layer = passage.get("ami_layer")
    return [m["word"] for m in layer.get("taken_back", [])] if isinstance(layer, dict) else []


def build_row(passage, written, args):
    spoken, typed = passage["spoken"], written["typed"]
    taken = taken_back_words(passage)
    reasons = []
    if not written["usable"]:
        reasons.append("writer_flagged_unusable")
    has_text = bool(typed.strip())
    outcome = checks.run_checks(spoken, typed, written["corrections"], taken, (args.band_low, args.band_high),
                                args.max_added_words, args.function_tolerance) if has_text else {}
    noted = checks.run_report_only(spoken, typed, taken) if has_text else {}
    if written["usable"] and not has_text:
        reasons.append("empty_typed")
    failed = checks.failed(outcome)
    reasons += [f"check:{name}" for name in failed]
    if any(item["kind"] == "meaning" for item in written["unsure"]):
        reasons.append("unsure:meaning")
    garbled = sum(1 for item in written["unsure"] if item["kind"] == "garbled")
    meta = {k: v for k, v in passage.items() if k not in ("id", "spoken")}
    return {"id": passage["id"], "spoken": spoken, **written, "meta": meta, "taken_back_words": taken,
            "checks": outcome, "failed_checks": failed, "report_only": noted,
            "report_only_findings": checks.noted(noted), "reads_as_typed": garbled < GARBLED_LIMIT,
            "quarantine_reasons": reasons,
            "writer": {"model": getattr(args, "model", None), "instructions": args.instructions_version}}


def route(row):
    """accepted, quarantine or not_typed: a wrong row is quarantined; a faithful row that does not read as
    typed (two or more garbled spots kept) is set aside, neither accepted nor called wrong."""
    if row["quarantine_reasons"]:
        return "quarantine"
    return "accepted" if row["reads_as_typed"] else "not_typed"


def write_lines(path, rows):
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    Path(path).write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in rows), encoding="utf-8")


def build_report(rows, failed, meta):
    accepted = [r for r in rows if route(r) == "accepted"]
    per_check = {}
    for name in checks.CHECK_NAMES:
        ran = [r for r in rows if r["checks"]]
        per_check[name] = {"failed": sum(1 for r in ran if not r["checks"][name]["ok"]), "checked": len(ran)}
    lengths = [r["checks"]["length"]["label"] for r in rows if r["checks"]]
    ran = [r for r in rows if r["report_only"]]
    report_only = {name: {"flagged": sum(1 for r in ran if not r["report_only"][name]["ok"]), "checked": len(ran)}
                   for name in checks.REPORT_ONLY_NAMES}
    return {**meta, "rows": len(rows), "accepted": len(accepted),
            "quarantined": sum(1 for r in rows if route(r) == "quarantine"),
            "not_typed": sum(1 for r in rows if route(r) == "not_typed"), "report_only": report_only,
            "unsure_by_kind": _count(i["kind"] for r in rows for i in r["unsure"]),
            "call_failures": len(failed), "per_check": per_check,
            "length": {"over_deletion": lengths.count("over_deletion"), "under_deletion": lengths.count("under_deletion"),
                       "ok": lengths.count("ok")},
            "writer_flagged_unusable": sum(1 for r in rows if not r["usable"]),
            "rows_with_unsure": sum(1 for r in rows if r["unsure"]),
            "corrections_resolved": sum(len(r["corrections"]) for r in rows),
            "quarantine_reasons": _count(reason for r in rows for reason in r["quarantine_reasons"])}


def _count(items):
    counts = {}
    for item in items:
        counts[item] = counts.get(item, 0) + 1
    return counts


def emit(args, scratch, rows, failed, meta):
    prefix = args.out
    targets = {name: guard.safe_output(f"{prefix}.{name}", scratch)
               for name in ("accepted.jsonl", "quarantine.jsonl", "not_typed.jsonl", "failed.jsonl", "report.json")}
    for name in ("accepted", "quarantine", "not_typed"):
        write_lines(targets[f"{name}.jsonl"], [r for r in rows if route(r) == name])
    write_lines(targets["failed.jsonl"], failed)
    report = build_report(rows, failed, meta)
    targets["report.json"].write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    return report


def print_report(report):
    print(f"retrain-writer: {report['rows']} rows, {report['accepted']} accepted, {report['quarantined']} quarantined, "
          f"{report['not_typed']} set aside as not reading as typed, {report['call_failures']} call failures")
    for name, counts in report["per_check"].items():
        print(f"  {name:22s} failed {counts['failed']:4d} of {counts['checked']}")
    for name, counts in report["report_only"].items():
        print(f"  {name:22s} flagged {counts['flagged']:3d} of {counts['checked']} (report only)")
    print(f"  length: {report['length']}; writer-flagged unusable {report['writer_flagged_unusable']}; "
          f"rows with unsure {report['rows_with_unsure']}")


# ---- commands ------------------------------------------------------------------------------------

def validate_spend_cap(args):
    try:
        api_judge.validate_spend_cap(args)
    except api_judge.JudgeError as exc:
        raise WriterError(str(exc)) from exc


def run_write(args):
    scratch = guard.scratch_roots(args.scratch_dir)
    if not args.invented_or_public:
        raise WriterError("pass --invented-or-public to state that the input is invented or public-corpus text")
    validate_spend_cap(args)
    client_module.price_for(args.model)
    instructions_path = guard.safe_input(args.instructions, scratch)
    instructions = instructions_path.read_text(encoding="utf-8")
    args.instructions_version = instructions_version(instructions)
    passages = load_passages(args.passages, scratch, args.limit)
    state = guard.check_path(args.state_dir, scratch, "state folder")
    cache, ledger = WriterCache(state / "cache"), api_judge.Ledger(state / "ledger.jsonl")
    tasks = plan_tasks(passages, args, instructions, args.instructions_version)
    if args.dry_run:
        return dry_run(args, tasks, cache, ledger) or 0
    for suffix in ("accepted.jsonl", "quarantine.jsonl", "not_typed.jsonl", "failed.jsonl", "report.json"):
        guard.safe_output(f"{args.out}.{suffix}", scratch)
    runner = WriterRunner(args, cache, ledger,
                          api_judge.Budget(args.max_dollars, ledger=ledger), api_judge.LazyClient(args))
    done = iter(range(1, len(tasks) + 1))
    results = []

    def one(task):
        outcome = runner.execute(task)
        print(f"[{next(done)}/{len(tasks)}] {task['passage']['id']} {outcome['status']}"
              f"{' $%.4f' % outcome['usage']['dollars'] if outcome['usage']['dollars'] else ''}", file=sys.stderr)
        return outcome
    results = api_judge.map_warm_first(one, tasks, args.workers, lambda task: cache.get(task["key"]) is None,
                                       client_module.prompt_cache_on(args))
    rows = [build_row(t["passage"], r["written"], args) for t, r in zip(tasks, results) if r["written"]]
    failed = [{"id": t["passage"]["id"], "status": r["status"], "error": r["error"]}
              for t, r in zip(tasks, results) if not r["written"]]
    dollars = sum(r["usage"]["dollars"] for r in results)
    meta = {"model": args.model, "writer_version": args.instructions_version, "dollars_this_run": round(dollars, 6),
            "calls": sum(1 for r in results if r["status"] in ("ok", "failed")),
            "cached": sum(1 for r in results if r["status"] == "cached"),
            "ledger_total_dollars": round(ledger.total_dollars(), 6), "prices_as_of": client_module.PRICES_AS_OF,
            "band": [args.band_low, args.band_high], "max_added_words": args.max_added_words,
            "function_tolerance_per100": args.function_tolerance}
    report = emit(args, scratch, rows, failed, meta)
    print_report(report)
    print(f"retrain-writer: ${dollars:.4f} this run, ${ledger.total_dollars():.4f} in the ledger")
    print(f"retrain-writer: {client_module.cache_share_line(results)}")
    if runner.fatal:
        print(f"retrain-writer: run stopped: {runner.fatal}", file=sys.stderr)
        return 2
    return 0 if not failed else 3


def run_check(args):
    scratch = guard.scratch_roots(args.scratch_dir)
    if not args.invented_or_public:
        raise WriterError("pass --invented-or-public to state that the input is invented or public-corpus text")
    rows = [row for path in args.rows for row in api_judge.read_json_or_lines(guard.safe_input(path, scratch))]
    args.instructions_version = args.instructions_version_label
    out = []
    for old in rows:
        # rows written under typed-writer-v1 have unsure items without a kind: kept, never gating
        legacy = {**{k: old[k] for k in TOP_FIELDS},
                  "unsure": [{"kind": i.get("kind", "unclassified"), "quote": i["quote"], "note": i["note"]}
                             for i in old["unsure"]]}
        written = validate_written({**legacy, "unsure": [{**i, "kind": "context"} for i in legacy["unsure"]]})
        written["unsure"] = legacy["unsure"]
        passage = {"id": old["id"], "spoken": old["spoken"], **old.get("meta", {})}
        if old.get("taken_back_words"):
            passage["ami_layer"] = {"taken_back": [{"word": w} for w in old["taken_back_words"]]}
        row = build_row(passage, written, args)
        row["writer"] = old.get("writer", row["writer"])
        out.append(row)
    report = emit(args, scratch, out, [], {"rechecked": True, "band": [args.band_low, args.band_high],
                                           "max_added_words": args.max_added_words,
                                           "function_tolerance_per100": args.function_tolerance})
    print_report(report)
    return 0


def parser():
    cli = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = cli.add_subparsers(dest="command", required=True)
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--scratch-dir", action="append", default=[],
                        help="extra folder (besides Evals/) that inputs and outputs may live in; repeatable")
    common.add_argument("--invented-or-public", action="store_true",
                        help="required: the text is invented or from a public corpus")
    common.add_argument("--out", required=True, help="output prefix")
    common.add_argument("--band-low", type=float, default=checks.LENGTH_BAND[0])
    common.add_argument("--band-high", type=float, default=checks.LENGTH_BAND[1])
    common.add_argument("--max-added-words", type=int, default=checks.DEFAULT_MAX_ADDED_WORDS,
                        help="content words the typed text may add before content_words_added fails")
    common.add_argument("--function-tolerance", type=float, default=checks.DEFAULT_FUNCTION_TOLERANCE_PER100,
                        help="added function words per 100 typed words before function_words_added fails")
    write = commands.add_parser("write", parents=[common], help="write typed versions, then check them")
    write.add_argument("--passages", required=True)
    write.add_argument("--instructions", default=str(DEFAULT_INSTRUCTIONS))
    write.add_argument("--model", default=DEFAULT_MODEL)
    write.add_argument("--max-dollars", type=float)
    write.add_argument("--dry-run", action="store_true", help="print call count and estimated cost only")
    write.add_argument("--assume", type=int, nargs="*", help="with --dry-run: also estimate for these passage counts")
    write.add_argument("--limit", type=int, help="use only the first N passages")
    write.add_argument("--state-dir", default=str(DEFAULT_STATE), help="cache/ and ledger.jsonl live here")
    write.add_argument("--key-file", default=guard.DEFAULT_KEY_FILE)
    write.add_argument("--base-url", default=f"https://{client_module.API_HOST}")
    write.add_argument("--workers", type=int, default=1)
    write.add_argument("--max-tokens", type=int, default=DEFAULT_MAX_TOKENS)
    write.add_argument("--effort", choices=("low", "medium", "high", "xhigh", "max"))
    write.add_argument("--est-output-tokens", type=int, default=DEFAULT_EST_OUTPUT_TOKENS)
    write.add_argument("--max-retries", type=int, default=5)
    write.add_argument("--timeout", type=float, default=300.0)
    client_module.add_prompt_cache_flag(write)
    check = commands.add_parser("check", parents=[common], help="re-run the checks on written rows, no API")
    check.add_argument("--rows", required=True, nargs="+",
                       help="accepted/quarantine/not_typed files from `write`")
    check.add_argument("--instructions-version-label", default="rechecked")
    return cli


def main(argv=None):
    args = parser().parse_args(argv)
    try:
        return {"write": run_write, "check": run_check}[args.command](args)
    except (WriterError, GuardError, verdicts.VerdictError, api_judge.JudgeError, OSError, KeyError) as exc:
        print(f"retrain-writer: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
