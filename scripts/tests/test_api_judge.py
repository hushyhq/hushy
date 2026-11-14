#!/usr/bin/env python3
"""Offline tests for the Anthropic API judge. No network beyond a loopback fake server, no real key."""
import contextlib
import io
import json
import math
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))

import api_judge  # noqa: E402
import api_judge_client as client_module  # noqa: E402
import api_judge_guard as guard  # noqa: E402
import api_judge_verdict as verdicts  # noqa: E402
from sealed_guard import SealedEvalRefusal  # noqa: E402

FAKE_KEY = "sk-ant-FAKEKEY-do-not-leak-0123456789"
ARM_A, ARM_B = "ARMNAME-ALPHA", "ARMNAME-BRAVO"
GOOD = "GOODMARK"


def verdict(choice="version_1", v1=None, v2=None):
    empty = {"meaning_changes": [], "faults": []}
    return {"more_typed": choice, "version_1": v1 or empty, "version_2": v2 or empty, "reason": "r"}


def message(payload, usage=None, stop="end_turn", text=None):
    return {"id": "msg_x", "type": "message", "role": "assistant", "model": "m", "stop_reason": stop,
            "content": [{"type": "thinking", "thinking": "", "signature": "s"},
                        {"type": "text", "text": text if text is not None else json.dumps(payload)}],
            "usage": usage or {"input_tokens": 1000, "output_tokens": 500,
                               "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0}}


def texts_of(request):
    content = request["messages"][0]["content"]
    return [re.search(f"<{tag}>\n(.*?)\n</{tag}>", content, re.S).group(1)
            for tag in ("spoken", "version_1", "version_2")]


def prefer_good(request):
    _, first, second = texts_of(request)
    return message(verdict("version_1" if GOOD in first else "version_2"))


class FakeApi:
    """Loopback server; `responder(index, request_json, headers)` returns (status, headers, payload)."""

    def __init__(self, responder):
        self.requests, self.headers, self.responder = [], [], responder
        outer = self

        class Handler(BaseHTTPRequestHandler):
            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers["content-length"])))
                outer.requests.append(body)
                outer.headers.append({k.lower(): v for k, v in self.headers.items()})
                status, headers, payload = outer.responder(len(outer.requests) - 1, body, outer.headers[-1])
                data = json.dumps(payload).encode()
                self.send_response(status)
                for name, value in headers.items():
                    self.send_header(name, value)
                self.send_header("content-length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def log_message(self, *args):
                pass

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.url = f"http://127.0.0.1:{self.server.server_address[1]}"
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def close(self):
        self.server.shutdown()
        self.server.server_close()


def ok(responder):
    return lambda index, request, headers: (200, {}, responder(request))


MARKER = {"type": "ephemeral"}
CACHED_PREFIX, AFTER_PREFIX, OUTPUT = 700, 300, 500


def cache_aware(answer, delay=0.05):
    """Bills the way the documentation describes the prompt cache: a marked prefix is written by every
    request that arrives before the first marked response has gone out, and read by those after it.
    `answer(request)` is a whole message; its usage is replaced."""
    state = {"warm": False}

    def respond(index, request, headers):
        marked, warm = client_module.has_cache_marker(request), state["warm"]
        time.sleep(delay)
        usage = {"input_tokens": AFTER_PREFIX + (0 if marked else CACHED_PREFIX), "output_tokens": OUTPUT,
                 "cache_creation_input_tokens": CACHED_PREFIX if marked and not warm else 0,
                 "cache_read_input_tokens": CACHED_PREFIX if marked and warm else 0}
        state["warm"] = state["warm"] or marked
        return 200, {}, {**answer(request), "usage": usage}
    return respond


def system_text(request):
    """The instruction a request carries, whether it was sent plain or as marked blocks."""
    system = request["system"]
    return system if isinstance(system, str) else "".join(block["text"] for block in system)


class ApiJudgeTestCase(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="api-judge-test-")
        self.addCleanup(self.temp.cleanup)
        self.dir = Path(self.temp.name).resolve()
        self.secret_temp = tempfile.TemporaryDirectory(prefix="api-judge-key-")
        self.addCleanup(self.secret_temp.cleanup)
        self.key_file = Path(self.secret_temp.name) / "key"
        self.key_file.write_text(FAKE_KEY + "\n")
        self.key_file.chmod(0o600)
        self.sleeps = []
        patcher = patch.object(api_judge, "SLEEP", self.sleeps.append)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.items = self.dir / "items.jsonl"
        self.write_items([
            {"id": "i1", "spoken": "um so the thing is on tuesday no wednesday",
             "outputs": {ARM_A: f"The thing is on Wednesday. {GOOD}", ARM_B: "so the thing is on tuesday"}},
            {"id": "i2", "spoken": "we should not ship friday",
             "outputs": {ARM_A: "We ship Friday.", ARM_B: f"We should not ship Friday. {GOOD}"}}])

    def write_items(self, rows):
        self.items.write_text("".join(json.dumps(r) + "\n" for r in rows))

    def fake(self, responder):
        server = FakeApi(responder)
        self.addCleanup(server.close)
        return server

    def run_cli(self, *extra, server=None, key_file=None, command="judge", out="run"):
        argv = [command, "--scratch-dir", str(self.dir), "--invented-or-public"]
        if command == "judge":
            argv += ["--items", str(self.items), "--out", str(self.dir / out),
                     "--state-dir", str(self.dir / "state"), "--key-file", str(key_file or self.key_file)]
            if "--dry-run" not in extra and "--max-dollars" not in extra:
                argv += ["--max-dollars", "5"]
            if server:
                argv += ["--base-url", server.url]
        argv += list(extra)
        out_buffer, err_buffer = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out_buffer), contextlib.redirect_stderr(err_buffer):
            code = api_judge.main(argv)
        return code, out_buffer.getvalue(), err_buffer.getvalue()

    def report(self, out="run"):
        return json.loads((self.dir / f"{out}.json").read_text())

    def everything_written(self):
        return "".join(p.read_text(errors="replace") for p in self.dir.rglob("*") if p.is_file())


class BlindAndOrderTests(ApiJudgeTestCase):
    def test_arm_names_never_sent_and_both_orders_asked(self):
        server = self.fake(ok(prefer_good))
        code, _, _ = self.run_cli(server=server)
        self.assertEqual(code, 0)
        self.assertEqual(len(server.requests), 4)
        sent = json.dumps(server.requests)
        self.assertNotIn("ARMNAME", sent)
        self.assertNotIn(ARM_A, sent)
        firsts = {(texts_of(r)[0], texts_of(r)[1]) for r in server.requests}
        self.assertEqual(len(firsts), 4)  # per item, each arm's text appeared first once
        self.assertIn("Version 1", system_text(server.requests[0]) + json.dumps(server.requests[0]))

    def test_consistent_preference_is_a_win_for_the_right_arm(self):
        server = self.fake(ok(prefer_good))
        self.run_cli(server=server)
        rows = {r["item"]: r for r in self.report()["pairs"]}
        self.assertEqual((rows["i1"]["status"], rows["i1"]["winner"]), ("win", ARM_A))
        self.assertEqual((rows["i2"]["status"], rows["i2"]["winner"]), ("win", ARM_B))
        summary = self.report()["pair_summary"][f"{ARM_A} vs {ARM_B}"]
        self.assertEqual((summary["wins"][ARM_A], summary["wins"][ARM_B], summary["inconsistent"]), (1, 1, 0))

    def test_position_bias_makes_pairs_inconsistent_not_wins(self):
        server = self.fake(ok(lambda request: message(verdict("version_1"))))
        self.run_cli(server=server)
        report = self.report()
        self.assertEqual({r["status"] for r in report["pairs"]}, {"inconsistent"})
        summary = report["pair_summary"][f"{ARM_A} vs {ARM_B}"]
        self.assertEqual((summary["inconsistent"], sum(summary["wins"].values())), (2, 0))
        self.assertEqual(report["position_bias"]["version_1_share"], 1.0)

    def test_tie_in_both_orders_is_a_tie_and_tie_versus_pick_is_inconsistent(self):
        server = self.fake(ok(lambda request: message(verdict("tie"))))
        self.run_cli(server=server)
        self.assertEqual({r["status"] for r in self.report()["pairs"]}, {"tie"})

        def mixed(request):
            _, first, _ = texts_of(request)
            return message(verdict("tie" if first.startswith("so the") or first.startswith("We ship") else "version_1"))
        other = self.fake(ok(mixed))
        self.run_cli("--state-dir", str(self.dir / "state2"), server=other, out="run2")
        self.assertEqual({r["status"] for r in self.report("run2")["pairs"]}, {"inconsistent"})

    def test_seed_fixes_call_order(self):
        args = api_judge.parser().parse_args(["judge", "--items", "x", "--out", "y"])
        rows = api_judge.load_items(self.items, [self.dir])
        order = lambda seed: [(t["item"], t["order"]) for t in api_judge.plan_tasks(
            rows, type("A", (), {**vars(args), "seed": seed})(), "r\nRubric version: v", "v")]
        self.assertEqual(order(3), order(3))
        self.assertNotEqual(order(3), order(4))

    def test_evidence_is_mapped_back_to_the_arm_that_was_shown(self):
        def flag(request):
            _, first, second = texts_of(request)
            change = {"meaning_changes": [{"kind": "date", "quote": "tuesday", "said": "tuesday no wednesday"}],
                      "faults": [{"kind": "filler", "quote": "so the"}]}
            empty = {"meaning_changes": [], "faults": []}
            return message(verdict("version_2", v1=change if first.startswith("so the") else empty,
                                   v2=change if second.startswith("so the") else empty))
        server = self.fake(ok(flag))
        self.run_cli(server=server)
        arms = self.report()["arms"]
        self.assertEqual(arms[ARM_B]["meaning_items_confirmed"], 1)
        self.assertEqual(arms[ARM_A]["meaning_items_any"], 0)
        self.assertEqual(arms[ARM_B]["meaning_changes"][0]["quote"], "tuesday")
        self.assertTrue(arms[ARM_B]["meaning_changes"][0]["grounded"])
        self.assertEqual(arms[ARM_B]["faults_confirmed"]["filler"], 1)


class MoneyAndCacheTests(ApiJudgeTestCase):
    def test_live_cap_is_explicit_finite_and_includes_prior_ledger(self):
        args = api_judge.parser().parse_args(["judge", "--items", "x", "--out", "y"])
        self.assertIsNone(args.max_dollars)
        for value in ("nan", "inf", "-inf", "0", "-1"):
            args.max_dollars = float(value)
            with self.assertRaises(api_judge.JudgeError):
                api_judge.validate_spend_cap(args)
        ledger = api_judge.Ledger(self.dir / "ledger.jsonl")
        ledger.append({"dollars": 0.2})
        budget = api_judge.Budget(0.25, spent=ledger.total_dollars())
        self.assertFalse(budget.reserve(0.1))

    def test_two_stale_budgets_share_atomic_reservations_and_crashes_fail_closed(self):
        path = self.dir / "state" / "ledger.jsonl"
        first = api_judge.Budget(1.0, ledger=api_judge.Ledger(path))
        second = api_judge.Budget(1.0, ledger=api_judge.Ledger(path))
        self.assertTrue(first.reserve(0.7))
        self.assertFalse(second.reserve(0.4))
        self.assertAlmostEqual(api_judge.Ledger(path).total_dollars(), 0.7)
        first.settle(0.7, 0.2)
        self.assertAlmostEqual(api_judge.Ledger(path).total_dollars(), 0.2)
        third = api_judge.Budget(1.0, ledger=api_judge.Ledger(path))
        self.assertTrue(third.reserve(0.7))
        self.assertAlmostEqual(api_judge.Ledger(path).total_dollars(), 0.9)

    def test_settlement_over_reservation_is_counted_and_exhausts_cap(self):
        ledger = api_judge.Ledger(self.dir / "ledger.jsonl")
        budget = api_judge.Budget(1.0, ledger=ledger)
        self.assertTrue(budget.reserve(0.5))
        budget.settle(0.5, 1.1)
        self.assertAlmostEqual(ledger.total_dollars(), 1.1)
        self.assertTrue(budget.exhausted)
        self.assertFalse(budget.reserve(0.01))

    def test_reservation_prices_max_output_and_margin_on_input(self):
        body = {"messages": [{"role": "user", "content": "sample"}], "max_tokens": 1000}
        model = "claude-sonnet-5-5"
        expected = client_module.usage_cost(model, {"input_tokens": math.ceil(
            client_module.estimate_input_tokens(body) * client_module.INPUT_RESERVATION_MARGIN),
            "output_tokens": body["max_tokens"]})
        self.assertAlmostEqual(client_module.reservation_cost(model, body), expected)
        self.assertGreater(client_module.reservation_cost(model, body),
                           client_module.estimate_cost(model, body, body["max_tokens"]))

    def test_dry_run_reads_ledger_without_taking_lock(self):
        ledger = api_judge.Ledger(self.dir / "state" / "ledger.jsonl")
        ledger.append({"dollars": 0.25})
        with patch.object(api_judge.Ledger, "locked", side_effect=OSError("lock unavailable")):
            code, out, _ = self.run_cli("--dry-run", "--max-dollars", "1")
        self.assertEqual(code, 0)
        self.assertIn("ledger so far $0.25", out)
        self.assertIn("may be stale", out)

    def test_processes_cannot_reserve_past_one_shared_cap(self):
        path = self.dir / "state" / "ledger.jsonl"
        code = ("import sys; sys.path.insert(0, 'scripts'); import api_judge; "
                "sys.stdin.read(1); print(bool(api_judge.Ledger(sys.argv[1]).reserve(1.0, 0.7)))")
        children = [subprocess.Popen([sys.executable, "-I", "-c", code, str(path)],
                                     stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                     text=True) for _ in range(2)]
        outputs = [child.communicate("go", timeout=10) for child in children]
        self.assertEqual([child.returncode for child in children], [0, 0], outputs)
        self.assertEqual(sorted(out.strip() for out, _ in outputs), ["False", "True"])
        self.assertAlmostEqual(api_judge.Ledger(path).total_dollars(), 0.7)

    def test_resumed_dry_run_reports_ledger_spend_and_headroom(self):
        api_judge.Ledger(self.dir / "state" / "ledger.jsonl").append({"dollars": 0.25})
        code, out, _ = self.run_cli("--dry-run", "--max-dollars", "1")
        self.assertEqual(code, 0)
        self.assertIn("ledger so far $0.25", out)
        self.assertIn("remaining $0.75", out)

    def test_request_id_is_safe_for_storage(self):
        saved = api_judge.safe_request_id("ok_/\nsecret!")
        self.assertRegex(saved, r"^[A-Za-z0-9_-]{1,32}$")
        self.assertNotIn("secret", saved)
        self.assertEqual(len(api_judge.safe_request_id("x" * 500)), 32)

    def test_resume_ledger_blocks_calls_before_client_is_opened(self):
        ledger = api_judge.Ledger(self.dir / "state" / "ledger.jsonl")
        ledger.append({"dollars": 0.5})
        code, _, _ = self.run_cli("--max-dollars", "0.5", key_file=self.dir / "missing")
        self.assertEqual(code, 3)
        self.assertEqual({call["status"] for call in self.report()["calls"]}, {"skipped"})

    def test_nonfinite_prior_ledger_spend_fails_closed(self):
        ledger = api_judge.Ledger(self.dir / "ledger.jsonl")
        ledger.append({"dollars": float("nan")})
        with self.assertRaises(api_judge.JudgeError):
            ledger.total_dollars()

    def test_cap_below_one_call_stops_before_any_call(self):
        server = self.fake(ok(prefer_good))
        code, out, _ = self.run_cli("--max-dollars", "0.01", server=server)
        self.assertEqual(server.requests, [])
        self.assertEqual(code, 3)
        self.assertIn("skipped 4", out)
        self.assertEqual({c["status"] for c in self.report()["calls"]}, {"skipped"})

    def test_cap_stops_before_the_call_that_could_exceed_it(self):
        big = {"input_tokens": 1000, "output_tokens": 9000}  # $0.184 at Opus 5.5 prices
        server = self.fake(ok(lambda request: message(verdict("version_1"), usage=big)))
        code, out, _ = self.run_cli("--max-dollars", "0.25", server=server)  # one worst case is about $0.21
        self.assertEqual(len(server.requests), 1)
        self.assertIn("calls 1", out)
        self.assertIn("skipped 3", out)

    def test_cache_prevents_second_call_and_needs_no_key(self):
        server = self.fake(ok(prefer_good))
        self.run_cli(server=server)
        self.assertEqual(len(server.requests), 4)
        code, out, _ = self.run_cli(server=server, key_file=self.dir / "no-such-key")
        self.assertEqual((code, len(server.requests)), (0, 4))
        self.assertIn("calls 0 (cached 4", out)
        self.assertEqual(self.report()["meta"]["dollars"], 0.0)

    def test_cache_key_changes_with_model_rubric_and_request(self):
        body = verdicts.request_body("m", "r", "s", "a", "b", 100)
        keys = {api_judge.cache_key("m", "v1", body), api_judge.cache_key("n", "v1", body),
                api_judge.cache_key("m", "v2", body),
                api_judge.cache_key("m", "v1", verdicts.request_body("m", "r", "s", "a", "c", 100))}
        self.assertEqual(len(keys), 4)

    def test_ledger_and_summary_line_count_tokens_and_dollars(self):
        server = self.fake(ok(prefer_good))
        _, out, _ = self.run_cli(server=server)
        lines = [json.loads(l) for l in (self.dir / "state" / "ledger.jsonl").read_text().splitlines()]
        reservations = [row for row in lines if "reservation" in row]
        settled = [row for row in lines if "settles" in row]
        self.assertEqual(len(reservations), len(settled))
        self.assertEqual(len(settled), 4)
        self.assertEqual({row["reservation"] for row in reservations}, {row["settles"] for row in settled})
        self.assertEqual((settled[0]["input_tokens"], settled[0]["output_tokens"]), (1000, 500))
        self.assertAlmostEqual(settled[0]["dollars"], 0.014)
        self.assertIn("calls 4", out)
        self.assertIn("tokens in 4000 out 2000", out)
        self.assertIn("$0.0560 this run", out)

    def test_usage_cost_and_unknown_model(self):
        self.assertAlmostEqual(client_module.usage_cost("claude-sonnet-5-5", {"input_tokens": 1_000_000,
                               "output_tokens": 1_000_000}), 12.0)
        self.assertAlmostEqual(client_module.usage_cost("claude-haiku-5-5", {"input_tokens": 200_000}), 0.1)
        with self.assertRaises(guard.GuardError):
            client_module.price_for("claude-unknown")

    def test_dry_run_counts_calls_and_never_touches_network_or_key(self):
        server = self.fake(ok(prefer_good))
        code, out, _ = self.run_cli("--dry-run", server=server, key_file=self.dir / "absent")
        self.assertEqual((code, server.requests), (0, []))
        self.assertIn("4 calls", out)
        self.assertIn("estimated cost $", out)
        self.assertFalse((self.dir / "run.json").exists())


class PathGuardTests(ApiJudgeTestCase):
    def refused(self, path, extra=()):
        argv = ["judge", "--scratch-dir", str(self.dir), "--invented-or-public", "--items", str(path),
                "--out", str(self.dir / "o"), "--state-dir", str(self.dir / "s"), "--dry-run", *extra]
        err = io.StringIO()
        with contextlib.redirect_stderr(err), contextlib.redirect_stdout(io.StringIO()):
            code = api_judge.main(argv)
        self.assertEqual(code, 1, err.getvalue())
        return err.getvalue()

    def test_forbidden_names_are_refused(self):
        for name in ("heldout-v2-x", "sealed-set", "Voice Lab", "VoiceLab", "Application Support/Hushy",
                     "ab-session", "eval-long64-b1", "longb-notes"):
            with self.subTest(name=name):
                folder = self.dir / name
                folder.mkdir(parents=True, exist_ok=True)
                target = folder / "items.jsonl"
                target.write_text(self.items.read_text())
                self.assertIn("refused", self.refused(target))

    def test_outside_evals_and_scratch_is_refused(self):
        self.assertIn("outside", self.refused(guard.ROOT / "CLAUDE.md" if (guard.ROOT / "CLAUDE.md").exists()
                                              else guard.ROOT / "README.md"))

    def test_scratch_folders_that_hold_credentials_or_home_are_refused(self):
        for folder in (Path.home(), Path.home() / ".config", Path("/")):
            with self.subTest(folder=folder), self.assertRaises(guard.GuardError):
                guard.scratch_roots([folder])

    def test_key_file_cannot_be_an_input(self):
        with self.assertRaises(guard.GuardError):
            guard.safe_input(self.key_file, [self.dir])

    def test_sealed_hash_is_refused(self):
        with patch.object(guard, "assert_tuning_safe", side_effect=SealedEvalRefusal("sealed hash")):
            self.assertIn("sealed hash", self.refused(self.items))

    def test_output_paths_are_guarded_too(self):
        err = io.StringIO()
        with contextlib.redirect_stderr(err), contextlib.redirect_stdout(io.StringIO()):
            code = api_judge.main(["judge", "--scratch-dir", str(self.dir), "--invented-or-public",
                                   "--items", str(self.items), "--out", str(self.dir / "heldout-report"),
                                   "--dry-run", "--state-dir", str(self.dir / "s")])
        self.assertEqual(code, 1)
        self.assertIn("heldout", err.getvalue())

    def test_invented_flag_is_required(self):
        err = io.StringIO()
        with contextlib.redirect_stderr(err), contextlib.redirect_stdout(io.StringIO()):
            code = api_judge.main(["judge", "--scratch-dir", str(self.dir), "--items", str(self.items),
                                   "--out", str(self.dir / "o"), "--dry-run"])
        self.assertEqual(code, 1)
        self.assertIn("--invented-or-public", err.getvalue())

    def test_evals_folder_is_allowed_without_scratch(self):
        runs = guard.EVALS / "runs"
        runs.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=runs, prefix="api-judge-test-") as folder:
            path = Path(folder) / "items.jsonl"
            path.write_text(self.items.read_text())
            self.assertEqual(guard.safe_input(path, []), path.resolve())

    def test_base_url_must_be_the_real_api_or_loopback(self):
        for url in ("https://evil.example", "http://api.anthropic.com", "https://api.anthropic.com:8443"):
            with self.subTest(url=url), self.assertRaises(guard.GuardError):
                client_module.base_url_parts(url)
        self.assertEqual(client_module.base_url_parts("https://api.anthropic.com")[1], "api.anthropic.com")


class KeyAndLeakTests(ApiJudgeTestCase):
    def test_key_is_sent_as_header_and_never_written_anywhere(self):
        server = self.fake(ok(prefer_good))
        code, out, err = self.run_cli(server=server)
        self.assertEqual(code, 0)
        self.assertEqual({h["x-api-key"] for h in server.headers}, {FAKE_KEY})
        self.assertEqual({h["anthropic-version"] for h in server.headers}, {"2023-06-01"})
        self.assertNotIn(FAKE_KEY, out + err + self.everything_written())
        self.assertNotIn("x-api-key", self.everything_written().lower())

    def test_key_echoed_by_server_error_is_scrubbed(self):
        def echo(index, request, headers):
            return 401, {}, {"type": "error", "error": {"type": "authentication_error",
                                                        "message": f"bad key {headers['x-api-key']}"}}
        server = self.fake(echo)
        code, out, err = self.run_cli(server=server)
        self.assertEqual(code, 2)
        self.assertEqual(len(server.requests), 1)  # a 401 stops the run
        self.assertIn("authentication_error", err)
        self.assertNotIn(FAKE_KEY, out + err + self.everything_written())

    def test_exception_text_and_repr_never_hold_the_key(self):
        client = client_module.AnthropicClient(FAKE_KEY, base_url="http://127.0.0.1:9", max_retries=0)
        self.assertNotIn(FAKE_KEY, repr(client))
        with self.assertRaises(client_module.ApiError) as caught:
            client.send({"model": "m"})
        self.assertNotIn(FAKE_KEY, str(caught.exception))

    def test_missing_key_file_message(self):
        server = self.fake(ok(prefer_good))
        code, out, err = self.run_cli(server=server, key_file=self.dir / "nope")
        self.assertEqual((code, server.requests), (2, []))
        self.assertIn("cannot be opened", err)

    def test_loose_permissions_are_refused_without_printing_the_key(self):
        self.key_file.chmod(0o644)
        server = self.fake(ok(prefer_good))
        code, out, err = self.run_cli(server=server)
        self.assertEqual((code, server.requests), (2, []))
        self.assertIn("looser than 600", err)
        self.assertNotIn(FAKE_KEY, out + err)
        self.assertEqual(stat.S_IMODE(self.key_file.stat().st_mode), 0o644)

    def test_malformed_key_file_is_refused(self):
        for content in ("", "two words\n", "line one\nline two\n"):
            with self.subTest(content=content):
                self.key_file.write_text(content)
                self.key_file.chmod(0o600)
                with self.assertRaises(guard.GuardError) as caught:
                    guard.load_key(self.key_file)
                self.assertNotIn("two words", str(caught.exception))

    def test_redirect_is_not_followed(self):
        target = self.fake(ok(prefer_good))
        server = self.fake(lambda i, r, h: (302, {"location": target.url + "/v1/messages"}, {}))
        code, _, err = self.run_cli(server=server)
        self.assertEqual(target.requests, [])
        self.assertNotEqual(code, 0)


class FailureHandlingTests(ApiJudgeTestCase):
    def test_overload_and_rate_limit_are_retried_with_backoff(self):
        def flaky(index, request, headers):
            if index == 0:
                return 529, {}, {"type": "error", "error": {"type": "overloaded_error", "message": "busy"}}
            if index == 1:
                return 429, {"retry-after": "7"}, {"type": "error", "error": {"type": "rate_limit_error", "message": "slow"}}
            return 200, {}, prefer_good(request)
        server = self.fake(flaky)
        code, out, _ = self.run_cli(server=server)
        self.assertEqual(code, 0)
        self.assertEqual(len(server.requests), 6)  # 4 calls + 2 retried attempts
        self.assertEqual(len(self.sleeps), 2)
        self.assertGreaterEqual(self.sleeps[0], 2.0)
        self.assertGreaterEqual(self.sleeps[1], 7.0)

    def test_spend_cap_429_stops_the_run_without_retrying(self):
        capped = {"type": "error", "error": {"type": "rate_limit_error", "message": "limit",
                                             "details": {"error_code": "enforced_spend_limit_reached"}}}
        server = self.fake(lambda i, r, h: (429, {}, capped))
        code, _, err = self.run_cli(server=server)
        self.assertEqual((code, len(server.requests), self.sleeps), (2, 1, []))
        self.assertIn("run stopped", err)

    def test_persistent_overload_fails_the_call_after_retry_limit(self):
        server = self.fake(lambda i, r, h: (529, {}, {"type": "error", "error": {"type": "overloaded_error", "message": "x"}}))
        code, _, _ = self.run_cli("--max-retries", "2", "--limit", "1", server=server)
        self.assertEqual(code, 3)
        self.assertEqual(len(server.requests), 6)  # 2 calls x (1 + 2 retries)
        self.assertEqual({c["status"] for c in self.report()["calls"]}, {"failed"})

    def test_malformed_verdict_is_retried_once_then_recorded_failed(self):
        server = self.fake(ok(lambda request: message(None, text="this is not json")))
        code, out, _ = self.run_cli("--limit", "1", server=server)
        self.assertEqual(code, 3)
        self.assertEqual(len(server.requests), 4)  # two calls, each tried twice
        report = self.report()
        self.assertEqual({c["status"] for c in report["calls"]}, {"failed"})
        self.assertEqual(report["pairs"][0]["status"], "incomplete")
        self.assertEqual(sum(report["pair_summary"][f"{ARM_A} vs {ARM_B}"]["wins"].values()), 0)
        self.assertIn("failed 2", out)
        self.assertEqual(list((self.dir / "state" / "cache").glob("*.json")) if (self.dir / "state" / "cache").exists() else [], [])

    def test_malformed_then_valid_succeeds_on_the_retry(self):
        def first_bad(index, request, headers):
            bad = message(None, text=json.dumps({"more_typed": "version_9"}))
            return 200, {}, bad if index == 0 else prefer_good(request)
        server = self.fake(first_bad)
        code, _, _ = self.run_cli("--limit", "1", server=server)
        self.assertEqual((code, len(server.requests)), (0, 3))

    def test_validation_rejects_every_unguessable_shape(self):
        good = verdict()
        bad_cases = [
            {**good, "more_typed": "version_3"},
            {**good, "extra": 1},
            {**good, "version_1": {"meaning_changes": [{"kind": "color", "quote": "", "said": ""}], "faults": []}},
            {**good, "version_2": {"meaning_changes": [], "faults": [{"kind": "filler"}]}},
            {**good, "reason": 5},
            [], None,
        ]
        for case in bad_cases:
            with self.subTest(case=case), self.assertRaises(verdicts.VerdictError):
                verdicts.validate_verdict(case)
        self.assertEqual(verdicts.validate_verdict(good), good)

    def test_refusal_and_cut_off_are_not_verdicts(self):
        for stop in ("refusal", "max_tokens"):
            with self.subTest(stop=stop), self.assertRaises(verdicts.VerdictError):
                verdicts.extract_verdict(message(verdict(), stop=stop))

    def test_max_tokens_cut_off_retries_with_more_room(self):
        def cut(index, request, headers):
            if index == 0:
                return 200, {}, message(None, text="{", stop="max_tokens")
            return 200, {}, prefer_good(request)
        server = self.fake(cut)
        code, _, _ = self.run_cli("--limit", "1", "--max-tokens", "4000", server=server)
        self.assertEqual(code, 0)
        self.assertEqual((server.requests[0]["max_tokens"], server.requests[1]["max_tokens"]), (4000, 8000))

    def test_tool_mode_reads_a_tool_call_and_never_forces_the_tool(self):
        def tool(index, request, headers):
            self.assertEqual(request["tool_choice"], {"type": "auto"})
            self.assertTrue(request["tools"][0]["strict"])
            _, first, _ = texts_of(request)
            reply = message(None)
            reply["content"] = [{"type": "tool_use", "id": "t", "name": "record_verdict",
                                 "input": verdict("version_1" if GOOD in first else "version_2")}]
            return 200, {}, reply
        server = self.fake(tool)
        code, _, _ = self.run_cli("--structured", "tool", server=server)
        self.assertEqual(code, 0)
        self.assertNotIn("output_config", server.requests[0])

    def test_schema_mode_sends_only_supported_request_fields(self):
        server = self.fake(ok(prefer_good))
        self.run_cli("--effort", "low", server=server)
        request = server.requests[0]
        self.assertNotIn("temperature", request)
        self.assertNotIn("tool_choice", request)
        self.assertEqual(request["output_config"]["effort"], "low")
        self.assertEqual(request["output_config"]["format"]["type"], "json_schema")
        self.assertEqual(request["model"], "claude-opus-5-5")


class PromptCacheTests(ApiJudgeTestCase):
    def rubric(self):
        return api_judge.DEFAULT_RUBRIC.read_text(encoding="utf-8")

    def settled(self):
        lines = [json.loads(l) for l in (self.dir / "state" / "ledger.jsonl").read_text().splitlines()]
        return [row for row in lines if "settles" in row and "input_tokens" in row]

    def test_the_instruction_is_sent_as_one_marked_block(self):
        server = self.fake(ok(prefer_good))
        self.assertEqual(self.run_cli(server=server)[0], 0)
        for request in server.requests:
            self.assertEqual(request["system"], [{"type": "text", "text": self.rubric(), "cache_control": MARKER}])
            self.assertNotIn("cache_control", request)
            self.assertIsInstance(request["messages"][0]["content"], str)

    def test_with_a_tool_the_one_marker_sits_after_the_tool_definitions(self):
        server = self.fake(ok(prefer_good))
        self.assertEqual(self.run_cli("--structured", "tool", server=server)[0], 0)
        request = server.requests[0]
        self.assertEqual([tool["name"] for tool in request["tools"]], [verdicts.TOOL_NAME])
        self.assertNotIn("cache_control", request["tools"][0])
        self.assertEqual(len(request["system"]), 1)
        self.assertEqual(request["system"][0]["cache_control"], MARKER)
        self.assertTrue(request["system"][0]["text"].startswith(self.rubric()))

    def test_the_switch_sends_the_plain_instruction(self):
        server = self.fake(ok(prefer_good))
        self.assertEqual(self.run_cli("--no-prompt-cache", server=server)[0], 0)
        for request in server.requests:
            self.assertEqual(request["system"], self.rubric())
            self.assertNotIn("cache_control", json.dumps(request))

    def test_marking_copies_the_request_and_does_it_once(self):
        body = verdicts.request_body("m", "rubric text", "s", "a", "b", 100, structured="tool")
        before = json.dumps(body, sort_keys=True)
        marked = client_module.with_cache_marker(body)
        self.assertEqual(json.dumps(body, sort_keys=True), before)
        self.assertFalse(client_module.has_cache_marker(body))
        self.assertTrue(client_module.has_cache_marker(marked))
        self.assertIs(client_module.with_cache_marker(marked), marked)
        self.assertEqual({k: v for k, v in marked.items() if k != "system"},
                         {k: v for k, v in body.items() if k != "system"})
        self.assertIs(client_module.wire_body(body, False), body)

    def test_without_an_instruction_the_last_tool_is_marked_and_nothing_else(self):
        tools = [{"name": "one", "input_schema": {}}, {"name": "two", "input_schema": {}}]
        marked = client_module.with_cache_marker({"tools": tools, "messages": []})
        self.assertEqual(marked["tools"], [tools[0], {**tools[1], "cache_control": MARKER}])
        bare = {"messages": [], "system": "  "}
        self.assertIs(client_module.with_cache_marker(bare), bare)

    def test_each_kind_of_input_token_has_its_own_price(self):
        usage = {"input_tokens": 1000, "cache_creation_input_tokens": 2000, "cache_read_input_tokens": 3000,
                 "output_tokens": 100}
        # Opus 5.5 per million: input $4, cache write $5, cache read $0.20, output $20
        self.assertAlmostEqual(client_module.usage_cost("claude-opus-5-5", usage),
                               (1000 * 4 + 2000 * 5 + 3000 * 0.20 + 100 * 20) / 1_000_000)
        self.assertAlmostEqual(client_module.usage_cost("claude-sonnet-5-5", usage),
                               (1000 * 2 + 2000 * 2.5 + 3000 * 0.10 + 100 * 10) / 1_000_000)
        rates = client_module.price_for("claude-opus-5-5")
        self.assertAlmostEqual(rates["cache_write"], rates["input"] * 1.25)
        self.assertAlmostEqual(rates["cache_read"], rates["input"] * 0.05)

    def test_a_marked_request_is_reserved_at_the_write_price(self):
        body = verdicts.request_body("claude-opus-5-5", "rubric " * 400, "s", "a", "b", 1000)
        marked = client_module.with_cache_marker(body)
        tokens = math.ceil(client_module.estimate_input_tokens(marked) * client_module.INPUT_RESERVATION_MARGIN)
        self.assertAlmostEqual(client_module.reservation_cost("claude-opus-5-5", marked),
                               (tokens * 5 + 1000 * 20) / 1_000_000)
        self.assertGreater(client_module.reservation_cost("claude-opus-5-5", marked),
                           client_module.reservation_cost("claude-opus-5-5", body))

    def test_ledger_rows_and_the_summary_count_cache_tokens_at_their_prices(self):
        server = self.fake(cache_aware(prefer_good))
        code, out, _ = self.run_cli("--workers", "4", server=server)
        self.assertEqual(code, 0)
        rows = self.settled()
        self.assertEqual(sorted(r["cache_write_tokens"] for r in rows), [0, 0, 0, CACHED_PREFIX])
        self.assertEqual(sorted(r["cache_read_tokens"] for r in rows), [0] + [CACHED_PREFIX] * 3)
        self.assertEqual({r["input_tokens"] for r in rows}, {AFTER_PREFIX})
        write = (AFTER_PREFIX * 4 + CACHED_PREFIX * 5 + OUTPUT * 20) / 1_000_000
        read = (AFTER_PREFIX * 4 + CACHED_PREFIX * 0.20 + OUTPUT * 20) / 1_000_000
        for row in rows:
            self.assertAlmostEqual(row["dollars"], write if row["cache_write_tokens"] else read)
        self.assertAlmostEqual(api_judge.Ledger(self.dir / "state" / "ledger.jsonl").total_dollars(), write + 3 * read)
        self.assertIn("tokens in 4000 out 2000", out)
        self.assertIn(f"${write + 3 * read:.4f} this run", out)
        self.assertIn("api-judge: prompt cache: 2100 of 4000 input tokens read from cache (52.5%), 700 written", out)
        meta = self.report()["meta"]
        self.assertEqual((meta["cache_read_tokens"], meta["cache_write_tokens"], meta["cache_read_share"]),
                         (2100, 700, 0.525))
        self.assertIs(meta["prompt_cache"], True)

    def test_switched_off_nothing_is_read_from_cache(self):
        server = self.fake(cache_aware(prefer_good))
        code, out, _ = self.run_cli("--workers", "4", "--no-prompt-cache", server=server)
        self.assertEqual(code, 0)
        self.assertIn("api-judge: prompt cache: 0 of 4000 input tokens read from cache (0.0%), 0 written", out)
        self.assertIs(self.report()["meta"]["prompt_cache"], False)

    def test_the_first_call_is_answered_before_the_workers_start(self):
        arrived = []

        def respond(index, request, headers):
            if index == 0:
                time.sleep(0.2)
                arrived.append(len(server.requests))
            return 200, {}, prefer_good(request)
        server = self.fake(respond)
        self.assertEqual(self.run_cli("--workers", "4", server=server)[0], 0)
        self.assertEqual((arrived, len(server.requests)), ([1], 4))

    def test_warm_first_keeps_task_order_and_skips_finished_tasks(self):
        order = []

        def one(task):
            order.append(task)
            return task * 10
        results = api_judge.map_warm_first(one, [1, 2, 3, 4], 3, lambda task: task >= 3)
        self.assertEqual(results, [10, 20, 30, 40])
        self.assertEqual(order[0], 3)  # the first task that still needs a call goes alone
        self.assertEqual(api_judge.map_warm_first(one, [1, 2], 3, lambda task: False), [10, 20])
        self.assertEqual(api_judge.map_warm_first(one, [], 3, lambda task: True), [])
        self.assertEqual(api_judge.map_warm_first(one, [5, 6], 2, lambda task: True, warm=False), [50, 60])

    def test_results_on_disk_are_reused_whichever_way_the_switch_is(self):
        server = self.fake(ok(prefer_good))
        self.run_cli("--no-prompt-cache", server=server)
        self.assertEqual(len(server.requests), 4)
        code, out, _ = self.run_cli(server=server, key_file=self.dir / "no-such-key")
        self.assertEqual((code, len(server.requests)), (0, 4))
        self.assertIn("calls 0 (cached 4", out)

    def test_the_result_key_is_the_one_used_before_the_marker_existed(self):
        body = verdicts.request_body("claude-opus-5-5", "Rubric version: r1\nJudge.", "spoken words", "First.",
                                     "Second.", 100)
        self.assertEqual(api_judge.cache_key("claude-opus-5-5", "r1", body),
                         "32d83aab1238b91596e483b1a6b2af6d0647a1e6c873ae15487f403e28aafd9f")

    def test_dry_run_measures_the_prefix_against_the_minimum(self):
        code, out, _ = self.run_cli("--dry-run")
        self.assertEqual(code, 0)
        self.assertRegex(out, r"prompt cache: prefix \(tools \+ system\) about \d+ tokens by the cost estimator, "
                              r"\d+ at a cautious 4 characters per token; the minimum for claude-opus-5-5 is 512: "
                              r"clears it; over 4 calls .* about \$\d+\.\d\d less than the estimate")
        _, out, _ = self.run_cli("--dry-run", "--no-prompt-cache")
        self.assertIn("clears it; switched off (--no-prompt-cache)", out)

    def test_the_prefix_verdict_has_three_answers_and_admits_an_unknown_model(self):
        line = lambda words, model="claude-opus-5-5": client_module.cache_prefix_line(  # noqa: E731
            model, {"system": "word " * words, "messages": []}, 10)
        self.assertIn("below it, so a marker would do nothing", line(100))
        self.assertNotIn("less than the estimate", line(100))
        self.assertIn("borderline; only a paid call can tell", line(350))
        self.assertIn("clears it", line(500))
        self.assertIn("no documented minimum is recorded for some-new-model", line(500, "some-new-model"))
        self.assertEqual(client_module.cache_prefix_tokens({"messages": []}), (0, 0))

    def test_the_saving_in_the_dry_run_is_one_write_then_reads(self):
        body = {"system": "x" * 3000, "messages": []}
        tokens = client_module.cache_prefix_tokens(body)[0]
        saving = tokens * (9 * (4 - 0.20) - (5 - 4)) / 1_000_000
        self.assertIn(f"about ${saving:.2f} less", client_module.cache_prefix_line("claude-opus-5-5", body, 10))


class ConverterTests(ApiJudgeTestCase):
    def setUp(self):
        super().setUp()
        self.cases = self.dir / "cases.jsonl"
        self.cases.write_text("".join(json.dumps(c) + "\n" for c in [
            {"id": "a", "spoken": "um hello there", "reference": "ignored"},
            {"id": "b", "spoken": "second one"}]))
        self.base = self.dir / "R0.json"
        self.cand = self.dir / "R3.json"
        self.base.write_text(json.dumps([{"id": "a", "output": "Hello.", "faults": {}}, {"id": "b", "output": "Second."}]))
        self.cand.write_text(json.dumps([{"id": "b", "output": "Second one."}, {"id": "a", "output": "Hello there."}]))

    def convert(self, *reports, out="out.jsonl"):
        argv = ["convert", "--scratch-dir", str(self.dir), "--invented-or-public",
                "--case-file", str(self.cases), "--out", str(self.dir / out)]
        for report in reports:
            argv += ["--report", report]
        err = io.StringIO()
        with contextlib.redirect_stderr(err), contextlib.redirect_stdout(io.StringIO()):
            code = api_judge.main(argv)
        return code, err.getvalue()

    def test_builds_items_with_named_arms_in_case_order(self):
        code, _ = self.convert(f"baseline={self.base}", f"whole={self.cand}")
        self.assertEqual(code, 0)
        rows = [json.loads(l) for l in (self.dir / "out.jsonl").read_text().splitlines()]
        self.assertEqual([r["id"] for r in rows], ["a", "b"])
        self.assertEqual(rows[0], {"id": "a", "spoken": "um hello there",
                                   "outputs": {"baseline": "Hello.", "whole": "Hello there."}})
        self.assertEqual(api_judge.load_items(self.dir / "out.jsonl", [self.dir])[1]["outputs"]["whole"], "Second one.")

    def test_arm_names_default_to_file_stems(self):
        self.convert(str(self.base), str(self.cand))
        self.assertEqual(list(json.loads((self.dir / "out.jsonl").read_text().splitlines()[0])["outputs"]), ["R0", "R3"])

    def test_mismatched_ids_and_single_report_are_errors(self):
        self.cand.write_text(json.dumps([{"id": "a", "output": "x"}]))
        code, err = self.convert(f"b={self.base}", f"c={self.cand}")
        self.assertEqual(code, 1)
        self.assertIn("same ids", err)
        self.assertEqual(self.convert(f"b={self.base}")[0], 1)
        self.assertEqual(self.convert(f"b={self.base}", f"b={self.base}")[0], 1)

    def test_item_validation(self):
        for rows in ([{"id": "x", "spoken": "s", "outputs": {"only": "one"}}],
                     [{"id": "x", "spoken": " ", "outputs": {"a": "1", "b": "2"}}],
                     [{"id": "x", "spoken": "s", "outputs": {"a": "1", "b": 2}}],
                     [{"id": "x", "spoken": "s", "outputs": {"a": "1", "b": "2"}}] * 2, []):
            with self.subTest(rows=rows), self.assertRaises(api_judge.JudgeError):
                api_judge.validate_items(rows)


if __name__ == "__main__":
    unittest.main()
