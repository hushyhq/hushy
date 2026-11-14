#!/usr/bin/env python3
"""Offline tests for the intent tool's facts step and group picker. Loopback fake server only; no real key.
Every transcript here is invented."""
import contextlib
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
sys.path.insert(0, str(Path(__file__).resolve().parent))

import api_judge  # noqa: E402
import api_judge_client as client_module  # noqa: E402
import retrain_intent as intent  # noqa: E402
import retrain_intent_pick as pick  # noqa: E402
import retrain_pilot as pilot  # noqa: E402
import retrain_pilot_steps as steps  # noqa: E402
from api_judge_verdict import VerdictError  # noqa: E402
from test_api_judge import CACHED_PREFIX, FAKE_KEY, MARKER, FakeApi, cache_aware, message  # noqa: E402

CASES = [
    {"id": "inv-a1", "source": "invented-meetings", "meeting": "mtg-a", "speaker": "s1",
     "spoken": "so the the roof survey um it is booked for the ninth no sorry the eleventh and and tessaly said "
               "she can not be there so we need someone else to to let them in i think"},
    {"id": "inv-a2", "domain": "a meeting", "meeting": "mtg-a",
     "spoken": "right what i was going to ask is is the quote from harrowgate still the four thousand one or did "
               "they did they put it up because if they put it up we are not signing this week"},
    {"id": "inv-b1", "source": "invented-meetings", "meeting": "mtg-b", "words": 37,
     "spoken": "okay so um brambling wants the the samples by thursday and i said i said we would try but i did "
               "not promise so do not tell him it is definite you know"},
]
FACTS = {"inv-a1": ["The roof survey is booked for the 11th", "Tessaly cannot be there",
                    "Someone else is needed to let the surveyors in (the speaker thinks)"],
         "inv-a2": ["Question: is the quote from Harrowgate still 4,000, or did they raise it?",
                    "If Harrowgate raised the quote, we are not signing this week"],
         "inv-b1": ["Brambling wants the samples by Thursday", "The speaker said they would try, and did not promise",
                    "Request: do not tell Brambling it is definite"]}


def case_in(request):
    """Which invented case a request carries, found by its transcript."""
    content = request["messages"][0]["content"]
    return next(c["id"] for c in CASES if c["spoken"] in content)


class FactsValidatorTests(unittest.TestCase):
    def test_the_schema_is_closed_and_asks_only_for_facts(self):
        schema = intent.facts_schema()
        self.assertEqual(schema["required"], ["facts"])
        self.assertIs(schema["additionalProperties"], False)
        self.assertEqual(schema["properties"], {"facts": {"type": "array", "items": {"type": "string"}}})

    def test_a_good_list_is_kept_with_its_spacing_tidied(self):
        self.assertEqual(intent.validate_facts({"facts": ["  The survey  is on the 11th ", "Tessaly is away"]}),
                         {"facts": ["The survey is on the 11th", "Tessaly is away"]})

    def test_wrong_shapes_are_refused(self):
        for bad in (None, [], "x", {}, {"facts": []}, {"facts": "one"}, {"facts": ["a"], "extra": 1},
                    {"facts": ["a", ""]}, {"facts": ["a", "   "]}, {"facts": ["a", 3]}, {"facts": [["a"]]}):
            with self.assertRaises(VerdictError, msg=repr(bad)):
                intent.validate_facts(bad)

    def test_the_count_is_bounded(self):
        most = [f"fact {n}" for n in range(intent.FACTS_MAX)]
        self.assertEqual(len(intent.validate_facts({"facts": most})["facts"]), intent.FACTS_MAX)
        self.assertEqual(intent.validate_facts({"facts": ["only one"]}), {"facts": ["only one"]})
        with self.assertRaises(VerdictError):
            intent.validate_facts({"facts": most + ["one too many"]})

    def test_the_length_of_a_fact_is_bounded(self):
        longest = "x" * intent.FACT_MAX_CHARS
        self.assertEqual(intent.validate_facts({"facts": [longest]}), {"facts": [longest]})
        with self.assertRaises(VerdictError):
            intent.validate_facts({"facts": [longest + "x"]})

    def test_validation_is_stable_on_its_own_output(self):
        once = intent.validate_facts({"facts": [" a  b ", "c"]})
        self.assertEqual(intent.validate_facts(once), once)

    def test_the_brief_carries_its_version_on_the_first_line(self):
        text = intent.FACTS.read_text(encoding="utf-8")
        self.assertTrue(text.splitlines()[0].startswith("Pilot version: intent-facts-v"))
        self.assertEqual(steps.version_of(text), text.splitlines()[0].split()[-1])

    def test_the_card_holds_the_transcript_and_where_it_is_from(self):
        self.assertEqual(intent.facts_card(CASES[0]), {"context": "invented-meetings", "transcript": CASES[0]["spoken"]})
        self.assertEqual(intent.facts_card(CASES[1])["context"], "a meeting")
        self.assertEqual(intent.facts_card({"id": "x", "spoken": "hello there"})["context"], "speech")


class CliTestCase(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="retrain-intent-test-")
        self.addCleanup(self.temp.cleanup)
        self.dir = Path(self.temp.name).resolve()
        secret = tempfile.TemporaryDirectory(prefix="retrain-intent-key-")
        self.addCleanup(secret.cleanup)
        self.key_file = Path(secret.name) / "key"
        self.key_file.write_text(FAKE_KEY + "\n")
        self.key_file.chmod(0o600)
        patcher = patch.object(api_judge, "SLEEP", lambda s: None)
        patcher.start()
        self.addCleanup(patcher.stop)

    def server(self, answer):
        api = FakeApi(lambda index, request, headers: (200, {}, message(answer(request))))
        self.addCleanup(api.close)
        return api

    def run_cli(self, *argv):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = intent.main([argv[0], "--scratch-dir", str(self.dir), *argv[1:]])
        return code, out.getvalue(), err.getvalue()

    def call(self, command, *extra, server=None, dollars="5"):
        argv = [command, "--invented-or-public", "--scale-run", "--state-dir", str(self.dir / "state"),
                "--key-file", str(self.key_file), "--max-dollars", dollars, *extra]
        return self.run_cli(*argv, *(["--base-url", server.url] if server else []))

    def write(self, name, rows):
        pilot.write_lines(self.dir / name, rows)
        return str(self.dir / name)

    def lines(self, name):
        return [json.loads(x) for x in (self.dir / name).read_text().splitlines() if x.strip()]

    def paid_calls(self):
        """The ledger's records of calls that were made (its reservation rows carry no tool name)."""
        return [row for row in self.lines("state/ledger.jsonl") if "tool" in row]


class FactsRunTests(CliTestCase):
    def setUp(self):
        super().setUp()
        self.cases = self.write("cases.jsonl", CASES)
        self.out = str(self.dir / "with-facts.jsonl")

    def test_every_case_comes_back_with_its_fields_and_its_facts(self):
        api = self.server(lambda request: {"facts": FACTS[case_in(request)]})
        code, out, err = self.call("facts", "--cases", self.cases, "--out", self.out, "--workers", "2", server=api)
        self.assertEqual(code, 0, err)
        self.assertEqual(self.lines("with-facts.jsonl"), [{**c, "facts": FACTS[c["id"]]} for c in CASES])
        self.assertIn("facts: 3 of 3 cases written, 0 left out", out)
        self.assertEqual(len(api.requests), 3)
        for request in api.requests:
            self.assertEqual(request["system"], [{"type": "text", "text": intent.FACTS.read_text(encoding="utf-8"),
                                                  "cache_control": MARKER}])
            self.assertIn("<card>", request["messages"][0]["content"])
            self.assertEqual(request["output_config"]["format"]["schema"], intent.facts_schema())
        ledger = self.paid_calls()
        self.assertEqual([r["tool"] for r in ledger], ["retrain_intent_facts"] * 3)
        self.assertEqual(sorted(r["item"] for r in ledger), sorted(FACTS))
        self.assertNotIn(FAKE_KEY, out + err + "".join(p.read_text(errors="replace") for p in self.dir.rglob("*")
                                                       if p.is_file()))

    def test_a_second_run_reads_the_cache_and_pays_nothing(self):
        api = self.server(lambda request: {"facts": FACTS[case_in(request)]})
        self.call("facts", "--cases", self.cases, "--out", self.out, server=api)
        code, out, err = self.call("facts", "--cases", self.cases, "--out", self.out, server=api)
        self.assertEqual(code, 0, err)
        self.assertEqual(len(api.requests), 3)
        self.assertIn("3 of 3 cases written, 0 left out; $0.0000", out)
        self.assertEqual(len(self.paid_calls()), 3)

    def test_the_output_is_ready_for_the_judge(self):
        api = self.server(lambda request: {"facts": FACTS[case_in(request)]})
        self.call("facts", "--cases", self.cases, "--out", self.out, server=api)
        arm = {c["id"]: "A rewrite." for c in CASES}
        items = intent.blind_items(self.lines("with-facts.jsonl"), {"one": arm}, "refined", 11)
        self.assertEqual([item["facts"] for item in items], [len(FACTS[c["id"]]) for c in CASES])
        self.assertEqual(items[0]["card"]["facts"][0], "1. " + FACTS["inv-a1"][0])

    def test_a_case_whose_answer_fails_validation_is_left_out_and_counted(self):
        too_many = [f"fact {n}" for n in range(intent.FACTS_MAX + 1)]
        api = self.server(lambda request: {"facts": too_many if case_in(request) == "inv-a2" else FACTS[case_in(request)]})
        code, out, err = self.call("facts", "--cases", self.cases, "--out", self.out, server=api)
        self.assertEqual(code, 0, err)
        self.assertEqual([r["id"] for r in self.lines("with-facts.jsonl")], ["inv-a1", "inv-b1"])
        self.assertIn("facts: 2 of 3 cases written, 1 left out (1 failed)", out)
        self.assertIn("inv-a2 failed", err)
        self.assertEqual(len(api.requests), 4)  # the failing case is asked twice, then given up

    def test_an_empty_or_misshapen_answer_is_left_out_too(self):
        answers = {"inv-a1": {"facts": []}, "inv-a2": {"facts": ["ok"], "note": "extra"}, "inv-b1": {"facts": FACTS["inv-b1"]}}
        api = self.server(lambda request: answers[case_in(request)])
        code, out, err = self.call("facts", "--cases", self.cases, "--out", self.out, server=api)
        self.assertEqual(code, 0, err)
        self.assertEqual([r["id"] for r in self.lines("with-facts.jsonl")], ["inv-b1"])
        self.assertIn("1 of 3 cases written, 2 left out (2 failed)", out)

    def test_dry_run_prints_the_estimate_and_spends_nothing(self):
        self.key_file.unlink()
        api = self.server(lambda request: {"facts": ["never asked"]})
        code, out, err = self.call("facts", "--cases", self.cases, "--out", self.out, "--dry-run", server=api)
        self.assertEqual(code, 0, err)
        self.assertIn("3 items, 3 calls to make", out)
        self.assertIn("typical $", out)
        self.assertIn("of the $5.00 cap", out)
        self.assertIn("Nothing sent; the key file was not opened", out)
        self.assertEqual(api.requests, [])
        self.assertFalse(Path(self.out).exists())
        self.assertFalse((self.dir / "state" / "ledger.jsonl").exists())

    def test_the_run_flags_are_required(self):
        code, _, err = self.run_cli("facts", "--cases", self.cases, "--out", self.out, "--state-dir",
                                    str(self.dir / "state"), "--max-dollars", "5")
        self.assertEqual(code, 1)
        self.assertIn("--invented-or-public", err)
        code, _, err = self.run_cli("facts", "--cases", self.cases, "--out", self.out, "--state-dir",
                                    str(self.dir / "state"), "--invented-or-public")
        self.assertEqual(code, 1)
        self.assertIn("--max-dollars", err)

    def test_a_spent_cap_stops_the_step_before_any_call(self):
        (self.dir / "state").mkdir()
        (self.dir / "state" / "ledger.jsonl").write_text(json.dumps({"dollars": 5.0}) + "\n")
        api = self.server(lambda request: {"facts": ["never asked"]})
        code, _, err = self.call("facts", "--cases", self.cases, "--out", self.out, server=api)
        self.assertEqual(code, 1)
        self.assertIn("cumulative cap of $5.00 is spent", err)
        self.assertEqual(api.requests, [])

    def test_cases_without_an_id_or_words_are_refused_before_any_call(self):
        api = self.server(lambda request: {"facts": ["never asked"]})
        for rows, word in (([{"id": "x", "spoken": "  "}], "spoken"), ([{"spoken": "some words here"}], "id"),
                           ([CASES[0], CASES[0]], "twice")):
            code, _, err = self.call("facts", "--cases", self.write("bad.jsonl", rows), "--out", self.out, server=api)
            self.assertEqual(code, 1)
            self.assertIn(word, err)
        self.assertEqual(api.requests, [])

    def test_facts_already_on_a_case_are_replaced_and_said_so(self):
        cases = self.write("old.jsonl", [{**CASES[0], "facts": ["an older list"]}])
        api = self.server(lambda request: {"facts": FACTS["inv-a1"]})
        code, out, err = self.call("facts", "--cases", cases, "--out", self.out, server=api)
        self.assertEqual(code, 0, err)
        self.assertEqual(self.lines("with-facts.jsonl")[0]["facts"], FACTS["inv-a1"])
        self.assertIn("1 already had facts, replaced", out)
        self.assertNotIn("an older list", api.requests[0]["messages"][0]["content"])


class CeilingStillWorksTests(CliTestCase):
    def test_ceiling_writes_an_id_and_text_per_case(self):
        cases = self.write("cases.jsonl", CASES)
        api = self.server(lambda request: {"text": "Rewritten " + case_in(request)})
        code, out, err = self.call("ceiling", "--cases", cases, "--out", str(self.dir / "c.jsonl"), server=api)
        self.assertEqual(code, 0, err)
        self.assertEqual(self.lines("c.jsonl"), [{"id": c["id"], "text": "Rewritten " + c["id"]} for c in CASES])
        self.assertIn("ceiling (refined): 3 of 3 written", out)
        self.assertEqual({r["tool"] for r in self.paid_calls()}, {"retrain_intent_ceiling"})

    def test_the_older_commands_still_parse(self):
        cli = intent.parser()
        for argv in (["ceiling", "--out", "o", "--state-dir", "s"], ["judge", "--out", "o", "--state-dir", "s", "--arm", "a=b"],
                     ["muddle", "--out", "o", "--state-dir", "s"], ["summary", "--rows", "r"],
                     ["rows", "--cases", "c", "--labels", "l", "--checks", "k", "--out", "o"]):
            self.assertEqual(cli.parse_args(argv).command, argv[0])


class PromptCacheTests(CliTestCase):
    """The three paid jobs: rewriting (ceiling), listing facts, and judging."""

    def setUp(self):
        super().setUp()
        self.cases = self.write("cases.jsonl", [{**c, "facts": FACTS[c["id"]]} for c in CASES])
        self.arm = self.write("arm.jsonl", [{"id": c["id"], "text": "Rewritten " + c["id"]} for c in CASES])

    def answers(self, request):
        content = request["messages"][0]["content"]
        if "Judge every candidate." in content:
            return {"candidates": [{"label": "A", "facts_missing": [], "facts_changed": [], "invented": [],
                                    "reads": 4, "register": 4}]}
        if "List the facts." in content:
            return {"facts": FACTS[case_in(request)]}
        return {"text": "Rewritten " + case_in(request)}

    def jobs(self):
        return (("ceiling", intent.LADDER, ()), ("facts", intent.FACTS, ()),
                ("judge", intent.RUBRIC, ("--arm", f"only={self.arm}")))

    def job(self, name, *extra, server=None):
        arm = next(a for n, _, a in self.jobs() if n == name)
        return self.call(name, "--cases", self.cases, "--out", str(self.dir / f"{name}.jsonl"), *arm, *extra,
                         server=server)

    def test_every_job_sends_its_brief_as_one_marked_block(self):
        for name, brief, _ in self.jobs():
            with self.subTest(job=name):
                api = self.server(self.answers)
                code, _, err = self.job(name, server=api)
                self.assertEqual(code, 0, err)
                self.assertEqual(len(api.requests), 3)
                for request in api.requests:
                    self.assertEqual(request["system"], [{"type": "text", "text": brief.read_text(encoding="utf-8"),
                                                          "cache_control": MARKER}])
                    self.assertNotIn("tools", request)

    def test_the_switch_sends_every_job_s_brief_plain(self):
        for name, brief, _ in self.jobs():
            with self.subTest(job=name):
                api = self.server(self.answers)
                code, _, err = self.job(name, "--no-prompt-cache", "--state-dir", str(self.dir / f"off-{name}"),
                                        server=api)
                self.assertEqual(code, 0, err)
                for request in api.requests:
                    self.assertEqual(request["system"], brief.read_text(encoding="utf-8"))
                    self.assertNotIn("cache_control", json.dumps(request))

    def test_every_job_s_brief_clears_the_documented_minimum_without_padding(self):
        minimum = client_module.CACHE_MIN_TOKENS[intent.writer.DEFAULT_MODEL]
        self.assertEqual(minimum, 512)
        for name, brief, _ in self.jobs():
            with self.subTest(job=name):
                body = steps.request_body(intent.writer.DEFAULT_MODEL, brief.read_text(encoding="utf-8"), "card",
                                          intent.text_schema(), 100)
                estimate, cautious = client_module.cache_prefix_tokens(body)
                self.assertGreaterEqual(cautious, minimum)
                self.assertGreater(estimate, cautious)
                code, out, err = self.job(name, "--dry-run")
                self.assertEqual(code, 0, err)
                self.assertIn(f"about {estimate} tokens by the cost estimator, {cautious} at a cautious", out)
                self.assertIn("the minimum for claude-opus-5-5 is 512: clears it; over 3 calls", out)

    def test_the_step_prints_the_share_of_input_read_from_cache(self):
        api = FakeApi(cache_aware(lambda request: message(self.answers(request))))
        self.addCleanup(api.close)
        code, out, err = self.job("ceiling", "--workers", "4", server=api)
        self.assertEqual(code, 0, err)
        self.assertIn("retrain-pilot: prompt cache: 1400 of 3000 input tokens read from cache (46.7%), 700 written", err)
        rows = self.paid_calls()
        self.assertEqual(sorted(r["cache_write_tokens"] for r in rows), [0, 0, CACHED_PREFIX])
        self.assertEqual(sorted(r["cache_read_tokens"] for r in rows), [0, CACHED_PREFIX, CACHED_PREFIX])
        self.assertAlmostEqual(sum(r["dollars"] for r in rows),
                               (3 * 300 * 4 + 700 * 5 + 2 * 700 * 0.20 + 3 * 500 * 20) / 1_000_000)

    def test_switched_off_the_workers_start_together_and_nothing_is_cached(self):
        api = FakeApi(cache_aware(lambda request: message(self.answers(request))))
        self.addCleanup(api.close)
        code, _, err = self.job("ceiling", "--workers", "4", "--no-prompt-cache", server=api)
        self.assertEqual(code, 0, err)
        self.assertIn("retrain-pilot: prompt cache: 0 of 3000 input tokens read from cache (0.0%), 0 written", err)

    def test_a_finished_job_is_not_billed_again_once_the_marker_is_on(self):
        api = self.server(self.answers)
        self.job("facts", "--no-prompt-cache", server=api)
        self.assertEqual(len(api.requests), 3)
        code, out, err = self.job("facts", server=api)
        self.assertEqual((code, len(api.requests)), (0, 3), err)
        self.assertIn("$0.0000", out)
        body = steps.request_body("claude-opus-5-5", "Pilot version: p1\nWrite.", steps.user_message({"a": 1}, "Go."),
                                  {"type": "object"}, 200)
        self.assertEqual(api_judge.cache_key("claude-opus-5-5", "p1", body),
                         "ac876d6dcf8b5766ed8a10f0013ff4706e9bc9a8a43993bafc1a64bac4a1abab")

    def test_the_older_flags_still_parse_with_the_cache_on_by_default(self):
        cli = intent.parser()
        for command in ("ceiling", "facts", "muddle"):
            self.assertIs(cli.parse_args([command, "--out", "o", "--state-dir", "s"]).prompt_cache, True)
            self.assertIs(cli.parse_args([command, "--out", "o", "--state-dir", "s", "--no-prompt-cache"]).prompt_cache,
                          False)


def grouped(prefix, groups, each):
    return [{"id": f"{prefix}-{g}-{n}", "meeting": f"{prefix}{g}", "spoken": f"invented words {prefix} {g} {n}"}
            for g in range(groups) for n in range(each)]


class PickFunctionTests(unittest.TestCase):
    def setUp(self):
        self.cases = grouped("m", 8, 5)

    def test_whole_groups_are_chosen_with_at_most_k_cases_each(self):
        chosen, picked = pick.pick_groups(self.cases, "meeting", 3, 2, 4)
        self.assertEqual(len(chosen), 3)
        self.assertEqual(chosen, sorted(set(chosen)))
        self.assertEqual({c["meeting"] for c in picked}, set(chosen))
        self.assertTrue(all(sum(c["meeting"] == g for c in picked) == 2 for g in chosen))

    def test_a_small_group_gives_what_it_has(self):
        cases = [c for c in self.cases if c["meeting"] != "m0" or c["id"].endswith("-0")]
        chosen, picked = pick.pick_groups(cases, "meeting", 8, 3, 1)
        self.assertEqual(sum(c["meeting"] == "m0" for c in picked), 1)
        self.assertEqual(len(picked), 7 * 3 + 1)

    def test_the_choice_is_repeatable_and_seeded(self):
        self.assertEqual(pick.pick_groups(self.cases, "meeting", 3, 2, 4), pick.pick_groups(self.cases, "meeting", 3, 2, 4))
        self.assertEqual(pick.pick_groups(self.cases[::-1], "meeting", 3, 2, 4)[0], pick.pick_groups(self.cases, "meeting", 3, 2, 4)[0])
        self.assertGreater(len({tuple(pick.pick_groups(self.cases, "meeting", 3, 2, seed)[0]) for seed in range(6)}), 1)

    def test_the_input_is_not_changed(self):
        before = json.dumps(self.cases)
        pick.pick_groups(self.cases, "meeting", 3, 2, 4)
        pick.exclude_groups(self.cases, "meeting", ["m1"])
        self.assertEqual(json.dumps(self.cases), before)

    def test_bad_requests_are_refused(self):
        for groups, per_group in ((9, 2), (0, 2), (3, 0)):
            with self.assertRaises(pick.PickError):
                pick.pick_groups(self.cases, "meeting", groups, per_group, 4)
        with self.assertRaises(pick.PickError):
            pick.pick_groups(self.cases + [{"id": "loose", "spoken": "no group"}], "meeting", 3, 2, 4)

    def test_excluding_drops_every_case_of_the_named_groups(self):
        kept = pick.exclude_groups(self.cases, "meeting", ["m1", "m6"])
        self.assertEqual(len(kept), 30)
        self.assertFalse({c["meeting"] for c in kept} & {"m1", "m6"})
        self.assertEqual(kept, [c for c in self.cases if c["meeting"] not in ("m1", "m6")])

    def test_excluding_matches_a_number_against_its_text_and_fails_closed(self):
        cases = [{"id": "a", "meeting": 12}, {"id": "b", "meeting": "13"}]
        self.assertEqual(pick.exclude_groups(cases, "meeting", ["12"]), [cases[1]])
        self.assertEqual(pick.exclude_groups(cases, "meeting", [13]), [cases[0]])
        with self.assertRaises(pick.PickError):
            pick.exclude_groups(cases + [{"id": "c"}], "meeting", ["12"])


class PickRunTests(CliTestCase):
    def setUp(self):
        super().setUp()
        self.a, self.b = self.write("a.jsonl", grouped("a", 4, 4)), self.write("b.jsonl", grouped("b", 4, 4))
        self.everything = grouped("a", 4, 4) + grouped("b", 4, 4)

    def pick(self, *extra):
        return self.run_cli("pick-groups", "--cases", self.a, "--cases", self.b, "--group-key", "meeting", *extra)

    def test_picking_writes_the_cases_and_only_the_group_ids(self):
        code, out, err = self.pick("--groups", "3", "--per-group", "2", "--seed", "5", "--out", str(self.dir / "picked.jsonl"),
                                   "--ids-out", str(self.dir / "groups.json"))
        self.assertEqual(code, 0, err)
        picked = self.lines("picked.jsonl")
        groups = json.loads((self.dir / "groups.json").read_text())
        self.assertEqual(len(groups), 3)
        self.assertTrue(all(type(g) is str for g in groups))
        self.assertEqual({c["meeting"] for c in picked}, set(groups))
        self.assertEqual(len(picked), 6)
        self.assertTrue(all(c in self.everything for c in picked))
        self.assertNotIn("invented words", (self.dir / "groups.json").read_text() + out)
        self.assertEqual(json.loads(out), {"groups_available": 8, "groups_picked": 3, "cases": 6})

    def test_excluding_is_the_inverse_of_picking(self):
        self.pick("--groups", "3", "--per-group", "2", "--seed", "5", "--out", str(self.dir / "picked.jsonl"),
                  "--ids-out", str(self.dir / "groups.json"))
        code, out, err = self.pick("--exclude-groups", str(self.dir / "groups.json"), "--out", str(self.dir / "rest.jsonl"))
        self.assertEqual(code, 0, err)
        groups = set(json.loads((self.dir / "groups.json").read_text()))
        rest = self.lines("rest.jsonl")
        self.assertEqual(rest, [c for c in self.everything if c["meeting"] not in groups])
        self.assertEqual(len(rest), 20)  # all four cases of each chosen group are gone, not only the two picked
        self.assertFalse({c["id"] for c in rest} & {c["id"] for c in self.lines("picked.jsonl")})
        self.assertEqual(json.loads(out), {"cases": 32, "dropped": 12, "kept": 20, "groups_excluded": 3,
                                           "groups_excluded_seen": 3})

    def test_the_two_directions_are_not_mixed_and_picking_needs_its_numbers(self):
        ids = self.dir / "groups.json"
        ids.write_text(json.dumps(["a1"]))
        for extra in (["--exclude-groups", str(ids), "--groups", "2"], ["--groups", "2"], ["--groups", "2", "--per-group", "2"],
                      ["--per-group", "2", "--ids-out", str(self.dir / "g2.json")]):
            code, _, err = self.pick(*extra, "--out", str(self.dir / "x.jsonl"))
            self.assertEqual(code, 1, extra)
            self.assertIn("retrain-intent:", err)
        self.assertFalse((self.dir / "x.jsonl").exists())

    def test_a_group_file_that_is_not_a_list_of_ids_is_refused(self):
        ids = self.dir / "groups.json"
        for bad in ({"groups": ["a1"]}, ["a1", {"text": "words"}], "a1"):
            ids.write_text(json.dumps(bad))
            code, _, err = self.pick("--exclude-groups", str(ids), "--out", str(self.dir / "x.jsonl"))
            self.assertEqual(code, 1, bad)
        self.assertFalse((self.dir / "x.jsonl").exists())

    def test_too_many_groups_is_an_error_not_a_short_pick(self):
        code, _, err = self.pick("--groups", "9", "--per-group", "2", "--out", str(self.dir / "x.jsonl"),
                                 "--ids-out", str(self.dir / "g.json"))
        self.assertEqual(code, 1)
        self.assertIn("only 8", err)



class FocusPlanTests(unittest.TestCase):
    def test_focus_cards_follow_the_ordinary_ones_and_leave_them_unchanged(self):
        plain = intent.muddle_plan(2, 2, 11)
        both = intent.muddle_plan(2, 2, 11, 8)
        self.assertEqual(both[:4], plain)
        focused = both[4:]
        self.assertEqual([slot["focus"] for slot in focused], list(intent.FOCUSES) * 2)
        self.assertTrue(all(slot["length"] == "long" and slot["id"].startswith("f") for slot in focused))
        self.assertEqual([slot["slips"] for slot in focused], [slot["focus"] == "soundalike" for slot in focused])
        self.assertFalse(any("focus" in slot for slot in plain))

if __name__ == "__main__":
    unittest.main()
