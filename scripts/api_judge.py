#!/usr/bin/env python3
"""Blind pairwise judge of dictation cleanup outputs, using the Anthropic Messages API directly.

Only invented or public-benchmark text may be sent. Every input and output path is checked against
the repository's guards (heldout, sealed, Voice Lab, the app's data directory) and must sit inside
Evals/ or a --scratch-dir; `--invented-or-public` is the operator's statement that the text is
invented or public. The API key is read from ~/.config/hushy/anthropic_api_key at the first live
call, never earlier, never printed.

    python3 scripts/api_judge.py convert --case-file CASES.jsonl --report baseline=R0.json \\
        --report candidate=R3.json --out items.jsonl --scratch-dir DIR --invented-or-public
    python3 scripts/api_judge.py judge --items items.jsonl --out DIR/judge-run --scratch-dir DIR \\
        --invented-or-public --dry-run          # call count and estimated cost, nothing sent
    python3 scripts/api_judge.py judge ... --max-dollars 8      # the real run

Items file (JSONL): {"id": "...", "spoken": "...", "outputs": {"baseline": "...", "candidate": "..."}}
"""

import argparse
from contextlib import contextmanager
import fcntl
import hashlib
import itertools
import json
import math
import os
from pathlib import Path
import random
import sys
import threading
import time
import uuid
from concurrent.futures import ThreadPoolExecutor

sys.path.insert(0, str(Path(__file__).resolve().parent))

import api_judge_client as client_module  # noqa: E402
import api_judge_guard as guard  # noqa: E402
import api_judge_report as report_module  # noqa: E402
import api_judge_verdict as verdicts  # noqa: E402
from api_judge_client import ApiError, FatalApiError  # noqa: E402
from api_judge_guard import GuardError  # noqa: E402

DEFAULT_RUBRIC = guard.EVALS / "judge" / "TYPED-READ-RUBRIC.md"
DEFAULT_STATE = guard.EVALS / "runs" / "api-judge"
DEFAULT_MODEL = "claude-opus-5-5"
DEFAULT_MAX_DOLLARS = 1.0
DEFAULT_MAX_TOKENS = 10_000
MAX_TOKENS_CEILING = 32_000
DEFAULT_EST_OUTPUT_TOKENS = 2_500  # a guess: thinking is billed as output and its volume is unknown
TRANSPORT_FAILURE_LIMIT = 5
SLEEP = time.sleep  # tests replace this so backoff does not wait


class JudgeError(Exception):
    """Bad input to the tool (not an API failure)."""


# ---- items and the converter -------------------------------------------------------------------

def read_json_or_lines(path):
    text = Path(path).read_text(encoding="utf-8")
    try:
        value = json.loads(text)
        return value if isinstance(value, list) else [value]
    except ValueError:
        pass
    try:
        return [json.loads(line) for line in text.splitlines() if line.strip()]
    except ValueError as exc:
        raise JudgeError(f"{path} is neither JSON nor JSON lines: {exc}") from None


def validate_items(rows):
    seen = set()
    for number, row in enumerate(rows, 1):
        if not isinstance(row, dict) or not isinstance(row.get("id"), str) or not row["id"]:
            raise JudgeError(f"item {number} needs a non-empty string id")
        if row["id"] in seen:
            raise JudgeError(f"duplicate item id {row['id']!r}")
        seen.add(row["id"])
        if not isinstance(row.get("spoken"), str) or not row["spoken"].strip():
            raise JudgeError(f"item {row['id']} needs non-empty spoken text")
        outputs = row.get("outputs")
        if not isinstance(outputs, dict) or len(outputs) < 2 or \
                any(not isinstance(k, str) or not isinstance(v, str) for k, v in outputs.items()):
            raise JudgeError(f"item {row['id']} needs two or more named string outputs")
    if not rows:
        raise JudgeError("the items file is empty")
    return rows


def load_items(path, scratch, limit=None, arms=None):
    rows = validate_items(read_json_or_lines(guard.safe_input(path, scratch)))
    if arms:
        for row in rows:
            row["outputs"] = {k: v for k, v in row["outputs"].items() if k in arms}
        validate_items(rows)
    return rows[:limit] if limit else rows


def parse_report_arg(value):
    name, separator, path = value.partition("=")
    if separator and name and path:
        return name, path
    return Path(value).stem, value


def convert(args):
    scratch = guard.scratch_roots(args.scratch_dir)
    spoken = {}
    for case in read_json_or_lines(guard.safe_input(args.case_file, scratch)):
        if not isinstance(case, dict) or not isinstance(case.get("id"), str) or \
                not isinstance(case.get("spoken"), str):
            raise JudgeError("every case needs a string id and a string spoken")
        spoken[case["id"]] = case["spoken"]
    outputs = {}
    for name, path in map(parse_report_arg, args.report):
        if name in outputs:
            raise JudgeError(f"two reports are named {name!r}; name them NAME=PATH")
        entries = read_json_or_lines(guard.safe_input(path, scratch))
        if any(not isinstance(e, dict) or not isinstance(e.get("id"), str)
               or not isinstance(e.get("output"), str) for e in entries):
            raise JudgeError(f"report {path} needs objects with a string id and a string output")
        outputs[name] = {e["id"]: e["output"] for e in entries}
    if len(outputs) < 2:
        raise JudgeError("give at least two --report files")
    ids = set(spoken)
    for name, by_id in outputs.items():
        if set(by_id) != ids:
            raise JudgeError(f"report {name} and the case file do not have the same ids "
                             f"(missing {sorted(ids - set(by_id))[:3]}, extra {sorted(set(by_id) - ids)[:3]})")
    out = guard.safe_output(args.out, scratch)
    out.parent.mkdir(parents=True, exist_ok=True)
    rows = [{"id": i, "spoken": spoken[i], "outputs": {n: outputs[n][i] for n in outputs}}
            for i in spoken]
    out.write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in rows), encoding="utf-8")
    print(f"api-judge: wrote {len(rows)} items with arms {', '.join(outputs)} to {out}")


# ---- state: cache, ledger, budget --------------------------------------------------------------

def cache_key(model, rubric_id, body):
    blob = json.dumps({"model": model, "rubric": rubric_id, "request": body}, sort_keys=True,
                      ensure_ascii=False, separators=(",", ":"))
    return hashlib.sha256(blob.encode("utf-8")).hexdigest()


class Cache:
    """Verdicts keyed by hash of model, rubric version and exact request. No key, no headers."""

    def __init__(self, directory):
        self.directory = Path(directory)

    def get(self, key):
        try:
            entry = json.loads((self.directory / f"{key}.json").read_text(encoding="utf-8"))
            return entry if verdicts.validate_verdict(entry["verdict"]) else None
        except (OSError, ValueError, KeyError, TypeError, verdicts.VerdictError):
            return None

    def put(self, key, entry):
        self.directory.mkdir(parents=True, exist_ok=True)
        target = self.directory / f"{key}.json"
        temporary = target.with_suffix(f".{os.getpid()}.{threading.get_ident()}.tmp")
        temporary.write_text(json.dumps(entry, ensure_ascii=False), encoding="utf-8")
        os.replace(temporary, target)


class Ledger:
    """Append-only spending and reservation records, guarded across processes."""

    def __init__(self, path):
        self.path = Path(path)
        self._lock = threading.Lock()

    @contextmanager
    def locked(self):
        with self._lock:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            with self.path.with_name(self.path.name + ".lock").open("a+b") as handle:
                fcntl.flock(handle, fcntl.LOCK_EX)
                try:
                    yield
                finally:
                    fcntl.flock(handle, fcntl.LOCK_UN)

    def _append_unlocked(self, record):
        with self.path.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(record, ensure_ascii=False) + "\n")
            handle.flush()
            os.fsync(handle.fileno())

    def append(self, record):
        with self.locked():
            self._append_unlocked(record)

    def _total_unlocked(self):
        try:
            lines = self.path.read_text(encoding="utf-8").splitlines()
        except FileNotFoundError:
            return 0.0
        try:
            amounts, reservations = [], {}
            for line in lines:
                if not line.strip():
                    continue
                row = json.loads(line)
                amount = row["dollars"]
                if type(amount) not in (int, float) or not math.isfinite(amount) or amount < 0:
                    raise ValueError
                if "reservation" in row:
                    ident = row["reservation"]
                    if not isinstance(ident, str) or not ident or ident in reservations:
                        raise ValueError
                    reservations[ident] = amount
                elif "settles" in row:
                    ident = row["settles"]
                    if ident not in reservations or reservations[ident] is None:
                        raise ValueError
                    reservations[ident] = None
                    amounts.append(amount)
                else:
                    amounts.append(amount)
            total = math.fsum(amounts + [value for value in reservations.values() if value is not None])
            if not math.isfinite(total):
                raise ValueError
            return total
        except (ValueError, KeyError, TypeError) as exc:
            raise JudgeError("invalid spending ledger") from exc

    def reserve(self, cap, worst):
        with self.locked():
            total = self._total_unlocked()
            if total >= cap or total + worst > cap:
                return None
            ident = uuid.uuid4().hex
            self._append_unlocked({"reservation": ident, "dollars": worst})
            return ident

    def settle(self, ident, actual, record=None):
        with self.locked():
            self._append_unlocked({**(record or {}), "settles": ident, "dollars": actual})

    def total_dollars(self):
        if not self.path.exists():
            return 0.0
        with self.locked():
            return self._total_unlocked()

    def dry_run_total_dollars(self):
        """Best-effort snapshot for a dry run; no ledger lock is needed."""
        return self._total_unlocked()


class Budget:
    """Reserves each call's worst-case cost before it is made; refuses once the cap could be crossed."""

    def __init__(self, cap, spent=0.0, ledger=None):
        self.cap, self.spent, self.reserved = cap, spent, 0.0
        self.ledger = ledger
        self._local = threading.local()
        self.exhausted = False
        self._lock = threading.Lock()

    def reserve(self, worst):
        with self._lock:
            if self.exhausted:
                return False
            ident = self.ledger.reserve(self.cap, worst) if self.ledger else None
            if (self.ledger and ident is None) or (not self.ledger and self.spent + self.reserved + worst > self.cap):
                self.exhausted = True
                return False
            if self.ledger:
                self._local.reservation = ident
            self.reserved += worst
            return True

    def settle(self, worst, actual, record=None):
        with self._lock:
            if self.ledger:
                self.ledger.settle(self._local.reservation, actual, record)
                del self._local.reservation
            self.reserved -= worst
            self.spent += actual
            total = self.ledger.total_dollars() if self.ledger else self.spent + self.reserved
            if total >= self.cap:
                self.exhausted = True

    def release(self, worst):
        self.settle(worst, 0.0)


def validate_spend_cap(args):
    if args.max_dollars is None and args.dry_run:
        return
    if args.max_dollars is None or not math.isfinite(args.max_dollars) or args.max_dollars <= 0:
        raise JudgeError("live runs require --max-dollars as a finite positive amount")


def safe_request_id(value):
    return hashlib.sha256(value.encode("utf-8")).hexdigest()[:32] if value else ""


class LazyClient:
    """Reads the key file and builds the HTTP client on the first call that needs it."""

    def __init__(self, args):
        self._args, self._client, self._lock = args, None, threading.Lock()

    def get(self):
        with self._lock:
            if self._client is None:
                key = guard.load_key(self._args.key_file)
                self._client = client_module.AnthropicClient(
                    key, base_url=self._args.base_url, timeout=self._args.timeout,
                    max_retries=self._args.max_retries, sleep=lambda s: SLEEP(s))
            return self._client


def map_warm_first(one, tasks, workers, pending, warm=True):
    """`one` over every task, results in task order.

    With `warm`, the first task that still needs a call finishes before the pool starts: a
    prompt-cache entry exists only once the first response has begun, so workers that start together
    would each pay to write it. If that call fails the pool simply starts cold.
    """
    first = next((i for i, task in enumerate(tasks) if pending(task)), None) if warm and workers > 1 else None
    head = [one(tasks[first])] if first is not None else []
    rest = [task for i, task in enumerate(tasks) if i != first]
    with ThreadPoolExecutor(max_workers=workers) as pool:
        results = list(pool.map(one, rest))
    return results if first is None else results[:first] + head + results[first:]


# ---- planning and running ----------------------------------------------------------------------

def plan_tasks(items, args, rubric, rubric_id):
    """Every pair of arms, in both orders, as ready-to-send requests; shuffled by the seed."""
    tasks = []
    for item in items:
        for a, b in itertools.combinations(item["outputs"], 2):
            for order, (first, second) in (("ab", (a, b)), ("ba", (b, a))):
                body = verdicts.request_body(
                    args.model, rubric, item["spoken"], item["outputs"][first],
                    item["outputs"][second], args.max_tokens, args.structured, args.effort)
                tasks.append({"item": item["id"], "a": a, "b": b, "order": order, "body": body,
                              "texts": (item["outputs"][first], item["outputs"][second]),
                              "spoken": item["spoken"], "key": cache_key(args.model, rubric_id, body)})
    random.Random(args.seed).shuffle(tasks)
    return tasks


def public_task(task, status, **extra):
    base = {k: task[k] for k in ("item", "a", "b", "order")}
    return {**base, "status": status, "error": None, "verdict": None, "input_tokens": 0,
            "output_tokens": 0, "cache_read_tokens": 0, "cache_write_tokens": 0, "dollars": 0.0,
            "request_id": "", "key": task["key"][:12], **extra}


class Runner:
    def __init__(self, args, cache, ledger, budget, lazy):
        self.args, self.cache, self.ledger, self.budget, self.lazy = args, cache, ledger, budget, lazy
        self.abort = threading.Event()
        self.fatal = None
        self.transport_failures = 0

    def execute(self, task):
        entry = self.cache.get(task["key"])
        if entry:
            return public_task(task, "cached", verdict=self.grounded(task, entry["verdict"]))
        if self.abort.is_set() or self.budget.exhausted:
            return public_task(task, "skipped", error="aborted" if self.abort.is_set() else "budget")
        try:
            return self.call(task)
        except FatalApiError as exc:
            self.fatal = self.fatal or str(exc)
            self.abort.set()
            return public_task(task, "skipped", error="aborted")
        except GuardError as exc:
            self.fatal = self.fatal or str(exc)
            self.abort.set()
            return public_task(task, "skipped", error="no usable key")

    @staticmethod
    def grounded(task, verdict):
        return verdicts.ground_verdict(verdict, task["spoken"], task["texts"])

    def call(self, task):
        body, reason, spent = task["body"], "no response", {}
        for attempt in (1, 2):
            wire = client_module.wire_body(body, client_module.prompt_cache_on(self.args))
            worst = client_module.reservation_cost(self.args.model, wire)
            if not self.budget.reserve(worst):
                return public_task(task, "skipped", error="budget", **spent)
            try:
                response, request_id = self.lazy.get().send(wire)
                request_id = safe_request_id(request_id)
            except FatalApiError:
                self.budget.release(worst)
                raise
            except ApiError as exc:
                self.budget.release(worst)
                self.transport_failures += 1
                if self.transport_failures >= TRANSPORT_FAILURE_LIMIT:
                    self.fatal = f"{TRANSPORT_FAILURE_LIMIT} calls in a row failed: {exc}"
                    self.abort.set()
                return public_task(task, "failed", error=str(exc), **spent)
            self.transport_failures = 0
            spent = self.account(task, response, request_id, worst, spent)
            try:
                verdict = verdicts.validate_verdict(verdicts.extract_verdict(response))
            except verdicts.VerdictError as exc:
                reason = str(exc)
                if response.get("stop_reason") == "max_tokens" and attempt == 1:
                    body = {**body, "max_tokens": min(body["max_tokens"] * 2, MAX_TOKENS_CEILING)}
                continue
            self.cache.put(task["key"], {"verdict": verdict, "request_id": request_id,
                                         "model": self.args.model})
            return public_task(task, "ok", verdict=self.grounded(task, verdict), **spent)
        return public_task(task, "failed", error=f"malformed verdict after one retry: {reason}", **spent)

    def account(self, task, response, request_id, worst, before):
        usage = response.get("usage")
        known = isinstance(usage, dict) and type(usage.get("output_tokens")) is int
        dollars = client_module.usage_cost(self.args.model, usage) if known else worst
        tokens = client_module._usage_tokens(usage)
        record = {"time": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                            "model": self.args.model, "item": task["item"], "order": task["order"],
                            "input_tokens": tokens["input"], "output_tokens": tokens["output"],
                            "cache_read_tokens": tokens["cache_read"], "cache_write_tokens": tokens["cache_write"],
                            "dollars": dollars, "usage_missing": not known,
                            "request_id": request_id, "key": task["key"][:12]}
        self.budget.settle(worst, record["dollars"], record if self.budget.ledger else None)
        if not self.budget.ledger:
            self.ledger.append(record)
        add = lambda k, v: before.get(k, 0) + v  # noqa: E731
        return {"input_tokens": add("input_tokens", tokens["input"]), "output_tokens": add("output_tokens", tokens["output"]),
                "cache_read_tokens": add("cache_read_tokens", tokens["cache_read"]),
                "cache_write_tokens": add("cache_write_tokens", tokens["cache_write"]),
                "dollars": add("dollars", dollars), "request_id": request_id}


def dry_run(args, tasks, cache, ledger=None):
    pending = [t for t in tasks if cache.get(t["key"]) is None]
    in_tokens = sum(client_module.estimate_input_tokens(t["body"]) for t in pending)
    typical = sum(client_module.estimate_cost(args.model, t["body"], args.est_output_tokens) for t in pending)
    worst = sum(client_module.reservation_cost(args.model, t["body"]) for t in pending)
    print(f"api-judge dry run: {len(tasks)} calls ({len(tasks) - len(pending)} already cached, "
          f"{len(pending)} to make), model {args.model}")
    print(f"  estimated input {in_tokens} tokens, output {len(pending) * args.est_output_tokens} tokens "
          f"(assumes {args.est_output_tokens} per call; thinking is billed as output)")
    print(f"  estimated cost ${typical:.2f}; worst case reservation ${worst:.2f} if every call uses max_tokens "
          f"{args.max_tokens} and input estimates include a {client_module.INPUT_RESERVATION_MARGIN:g}x margin; "
          f"prices as of {client_module.PRICES_AS_OF}")
    if pending:
        print(client_module.cache_prefix_line(args.model, pending[0]["body"], len(pending),
                                              client_module.prompt_cache_on(args)))
    if args.max_dollars is not None:
        print(f"  --max-dollars {args.max_dollars} {'covers' if args.max_dollars >= typical * 1.5 else 'is below 1.5x'} "
              f"the typical estimate; suggest at least {typical * 1.5:.2f}")
    else:
        print(f"  live run requires --max-dollars; suggest at least {typical * 1.5:.2f}")
    spent = ledger.dry_run_total_dollars() if ledger else 0.0
    print(f"  ledger so far ${spent:.2f} (may be stale); remaining "
          f"{'$%.2f' % max(0.0, args.max_dollars - spent) if args.max_dollars is not None else 'unknown without --max-dollars'}")
    print("  nothing was sent; the key file was not opened")


def run_calls(args, tasks, runner):
    done = itertools.count(1)
    lock = threading.Lock()

    def one(task):
        result = runner.execute(task)
        with lock:
            print(f"[{next(done)}/{len(tasks)}] {result['item']} {result['order']} {result['status']}"
                  f"{' $%.4f' % result['dollars'] if result['dollars'] else ''}", file=sys.stderr)
        return result
    return map_warm_first(one, tasks, args.workers, lambda task: runner.cache.get(task["key"]) is None,
                          client_module.prompt_cache_on(args))


def summarize(args, results, rubric_id, ledger):
    count = lambda s: sum(1 for r in results if r["status"] == s)  # noqa: E731
    share = client_module.cache_share(results)
    tokens_in = share["input_tokens"]
    meta = {"model": args.model, "rubric_version": rubric_id, "seed": args.seed, "structured": args.structured,
            "calls": count("ok") + count("failed"), "cached": count("cached"), "failed": count("failed"),
            "skipped": count("skipped"), "input_tokens": tokens_in,
            "output_tokens": sum(r["output_tokens"] for r in results),
            "dollars": round(sum(r["dollars"] for r in results), 6),
            "cache_read_tokens": share["cache_read_tokens"], "cache_write_tokens": share["cache_write_tokens"],
            "cache_read_share": share["cache_read_share"], "prompt_cache": client_module.prompt_cache_on(args),
            "prices_as_of": client_module.PRICES_AS_OF, "prices_source": client_module.PRICES_SOURCE}
    line = (f"api-judge: calls {meta['calls']} (cached {meta['cached']}, failed {meta['failed']}, "
            f"skipped {meta['skipped']}), tokens in {meta['input_tokens']} out {meta['output_tokens']}, "
            f"${meta['dollars']:.4f} this run, ${ledger.total_dollars():.4f} in the ledger\n"
            f"api-judge: {client_module.cache_share_line(results)}")
    return meta, line


def judge(args):
    scratch = guard.scratch_roots(args.scratch_dir)
    if not args.invented_or_public:
        raise JudgeError("pass --invented-or-public to state that the input is invented or public text")
    validate_spend_cap(args)
    client_module.price_for(args.model)
    rubric_path = guard.safe_input(args.rubric, scratch)
    rubric = rubric_path.read_text(encoding="utf-8")
    rubric_id = verdicts.rubric_version(rubric)
    items = load_items(args.items, scratch, args.limit, set(args.arms.split(",")) if args.arms else None)
    outputs = [guard.safe_output(f"{args.out}{suffix}", scratch) for suffix in (".json", ".md")]
    state = guard.check_path(args.state_dir, scratch, "state folder")
    cache, ledger = Cache(state / "cache"), Ledger(state / "ledger.jsonl")
    tasks = plan_tasks(items, args, rubric, rubric_id)
    if args.dry_run:
        return dry_run(args, tasks, cache, ledger) or 0
    runner = Runner(args, cache, ledger, Budget(args.max_dollars, ledger=ledger), LazyClient(args))
    results = run_calls(args, tasks, runner)
    meta, line = summarize(args, results, rubric_id, ledger)
    report = report_module.build_report(meta, results)
    outputs[0].parent.mkdir(parents=True, exist_ok=True)
    outputs[0].write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    outputs[1].write_text(report_module.markdown(report), encoding="utf-8")
    print(line)
    if runner.fatal:
        print(f"api-judge: run stopped: {runner.fatal}", file=sys.stderr)
        return 2
    return 0 if meta["failed"] == 0 and meta["skipped"] == 0 else 3


# ---- command line ------------------------------------------------------------------------------

def parser():
    cli = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = cli.add_subparsers(dest="command", required=True)
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--scratch-dir", action="append", default=[],
                        help="extra folder (besides Evals/) that inputs and outputs may live in; repeatable")
    common.add_argument("--invented-or-public", action="store_true",
                        help="required: the operator states the text is invented or public-benchmark text")
    build = commands.add_parser("convert", parents=[common], help="build an items file from run reports")
    build.add_argument("--case-file", required=True, help="JSONL or JSON with id and spoken")
    build.add_argument("--report", action="append", required=True, metavar="NAME=PATH",
                       help="JSON array of {id, output}; repeat per arm")
    build.add_argument("--out", required=True)
    run = commands.add_parser("judge", parents=[common], help="judge every pair in both orders")
    run.add_argument("--items", required=True)
    run.add_argument("--out", required=True, help="report path prefix; writes PREFIX.json and PREFIX.md")
    run.add_argument("--model", default=DEFAULT_MODEL)
    run.add_argument("--rubric", default=str(DEFAULT_RUBRIC))
    run.add_argument("--seed", type=int, default=1)
    run.add_argument("--max-dollars", type=float)
    run.add_argument("--dry-run", action="store_true", help="print call count and estimated cost only")
    run.add_argument("--state-dir", default=str(DEFAULT_STATE), help="cache/ and ledger.jsonl live here")
    run.add_argument("--key-file", default=guard.DEFAULT_KEY_FILE)
    run.add_argument("--base-url", default=f"https://{client_module.API_HOST}")
    run.add_argument("--workers", type=int, default=1)
    run.add_argument("--max-tokens", type=int, default=DEFAULT_MAX_TOKENS,
                     help="output cap per call; thinking counts toward it")
    run.add_argument("--effort", choices=("low", "medium", "high", "xhigh", "max"))
    run.add_argument("--structured", choices=("schema", "tool"), default="schema")
    run.add_argument("--est-output-tokens", type=int, default=DEFAULT_EST_OUTPUT_TOKENS)
    run.add_argument("--max-retries", type=int, default=5)
    run.add_argument("--timeout", type=float, default=300.0)
    run.add_argument("--arms", help="comma-separated arm names to compare (default: all)")
    run.add_argument("--limit", type=int, help="judge only the first N items")
    client_module.add_prompt_cache_flag(run)
    return cli


def main(argv=None):
    args = parser().parse_args(argv)
    try:
        if args.command == "convert":
            if not args.invented_or_public:
                raise JudgeError("pass --invented-or-public to state that the input is invented or public text")
            convert(args)
            return 0
        return judge(args)
    except (JudgeError, GuardError, verdicts.VerdictError, OSError) as exc:
        print(f"api-judge: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
