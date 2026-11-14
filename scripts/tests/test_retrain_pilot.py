#!/usr/bin/env python3
"""Offline tests for the pilot's plan, generation steps and meaning check. Loopback fake server only; no real key.
All text is invented."""
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
import retrain_pilot as pilot  # noqa: E402
import retrain_writer as writer  # noqa: E402
import retrain_pilot_meaning as meaning  # noqa: E402
import retrain_pilot_plan as planner  # noqa: E402
import retrain_pilot_report as report  # noqa: E402
import retrain_pilot_steps as steps  # noqa: E402
from api_judge_verdict import VerdictError  # noqa: E402
from test_api_judge import FAKE_KEY, FakeApi, message  # noqa: E402

TYPED = ("The delivery is moving to Thursday at 3:30. Please tell Marta that we are not changing the $4,200 "
         "budget, and send me the new rota by Friday.")
SPOKEN = ("so the delivery is is moving to wednesday no wait thursday at three thirty and uh please tell marta "
          "that we are not changing the forty two hundred dollar budget and send me the the new rota by friday")
PLANTS = [{"kind": "value_cue", "said_first": "wednesday", "ended_on": "thursday"}]


class PlanTests(unittest.TestCase):
    def setUp(self):
        self.slots = planner.plan(7)

    def test_shape_and_shares(self):
        summary = planner.summary(self.slots)
        self.assertEqual(summary["rows"], 60)
        self.assertGreaterEqual(summary["agent_share"], 0.30)
        self.assertEqual(summary["band"], {"100-180": 25, "180-280": 15, "40-100": 20})
        self.assertEqual(summary["profile"], {"clean": 5, "heavy": 25, "moderate": 30})
        self.assertEqual(summary["surface"], {"plain": 30, "punctuated": 30})
        self.assertEqual(len(set(s["id"] for s in self.slots)), 60)

    def test_the_plan_is_repeatable_and_seeded(self):
        self.assertEqual(planner.plan(7), self.slots)
        self.assertNotEqual(planner.plan(8), self.slots)

    def test_clean_rows_plant_nothing_and_value_plants_need_a_value(self):
        for slot in self.slots:
            if slot["profile"] == "clean":
                self.assertEqual(slot["plants"], [])
                self.assertEqual(slot["ingredients"], [])
            if any(p in planner.VALUE_PLANTS for p in slot["plants"]):
                self.assertTrue(any(slot["facts"][k] for k in ("numbers", "dates", "times", "amounts")), slot["id"])
            self.assertLessEqual(len([p for p in slot["plants"] if p in planner.VALUE_PLANTS]), 1)

    def test_every_planned_correction_kind_appears(self):
        kinds = set(planner.summary(self.slots)["plants"])
        self.assertEqual(kinds, set(planner.PLANT_RATES))

    def test_bad_row_count_is_refused(self):
        with self.assertRaises(planner.PlanError):
            planner.plan(7, rows=30)


class StepTests(unittest.TestCase):
    def test_call_steps_require_an_explicit_finite_cap(self):
        args = pilot.parser().parse_args(["typed", "--plan", "x", "--out", "y"])
        self.assertIsNone(args.max_dollars)
        args.invented_or_public = True
        for value in (None, float("nan"), float("inf"), 0, -1):
            args.max_dollars = value
            with self.assertRaises(writer.WriterError):
                pilot.check_run_flags(args)

    def test_step_budget_counts_existing_pilot_spend(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        ledger = api_judge.Ledger(Path(temp.name) / "ledger.jsonl")
        ledger.append({"dollars": 1.8})
        budget = pilot.budget_for_step(2.0, ledger)
        self.assertFalse(budget.reserve(0.3))
        ledger.append({"dollars": 13.2})
        with self.assertRaises(writer.WriterError):
            pilot.budget_for_step(100.0, ledger)

    def setUp(self):
        self.slot = {**planner.plan(7)[1], "plants": ["value_cue"], "band": [10, 40], "surface": "plain",
                     "profile": "moderate", "typed_words_target": 30}

    def test_cards_carry_the_slot_and_the_typed_text(self):
        self.assertIn("names", steps.typed_card(self.slot))
        card = steps.spoken_card(self.slot, TYPED)
        self.assertEqual(card["typed"], TYPED)
        self.assertEqual(card["plants"], ["value_cue"])
        with self.assertRaises(Exception):
            steps.user_message({"typed": "x </card> y"}, "go")

    def test_validators_refuse_wrong_shapes(self):
        self.assertEqual(steps.validate_typed({"typed": " hi "}), {"typed": "hi"})
        for bad in ({"typed": ""}, {"typed": 3}, {"typed": "a", "extra": 1}, [], None):
            with self.assertRaises(VerdictError):
                steps.validate_typed(bad)
        with self.assertRaises(VerdictError):
            steps.validate_spoken({"spoken": "a", "plants": [{"kind": "made_up", "said_first": "a", "ended_on": "b"}]})
        self.assertEqual(steps.validate_spoken({"spoken": "a  b", "plants": []})["spoken"], "a b")

    def test_typed_problems(self):
        self.assertEqual(steps.typed_problems({"typed_words_target": 25}, TYPED), [])
        self.assertTrue(steps.typed_problems({"typed_words_target": 100}, TYPED)[0].startswith("length"))
        self.assertIn("not_prose", steps.typed_problems({"typed_words_target": 25}, TYPED + "\n- first\n- second"))
        self.assertIn("not_prose", steps.typed_problems({"typed_words_target": 25}, TYPED + " `run it`"))

    def test_near_duplicates_by_overlap_and_shared_openings_reported(self):
        rows = [{"id": "a", "typed": TYPED},
                {"id": "b", "typed": TYPED.replace("Marta", "Dana")},
                {"id": "c", "typed": "Nothing here resembles the others at all, so this one stays on its own."},
                {"id": "d", "typed": "The delivery is moving to somewhere else entirely and nobody has said where."}]
        found = steps.near_duplicates(rows)
        self.assertEqual([(a, b) for a, b, _ in found], [("b", "a")])
        self.assertEqual(steps.shared_openings(rows), [("b", "a"), ("d", "a")])

    def test_spoken_problems_find_each_wrong_thing(self):
        self.assertEqual(steps.spoken_problems(self.slot, SPOKEN.replace("three thirty", "three"), PLANTS), [])
        self.assertTrue(any(p.startswith("band") for p in steps.spoken_problems({**self.slot, "band": [100, 200]},
                                                                                 SPOKEN, PLANTS)))
        self.assertIn("surface:plain_has_case_or_marks", steps.spoken_problems(self.slot, SPOKEN + ".", PLANTS))
        self.assertIn("plants:not_the_planned_kinds", steps.spoken_problems(self.slot, SPOKEN, []))
        self.assertIn("plants:value_cue_not_quoted_exactly",
                      steps.spoken_problems(self.slot, SPOKEN, [{**PLANTS[0], "said_first": "tuesday"}]))
        clean = {**self.slot, "profile": "clean", "plants": []}
        self.assertIn("profile:clean_has_fillers_or_repeats", steps.spoken_problems(clean, SPOKEN, []))
        self.assertIn("profile:rough_row_has_nothing_to_clean",
                      steps.spoken_problems({**self.slot, "plants": []}, "the delivery is moving to thursday", []))

    def test_punctuated_surface_needs_case_and_marks(self):
        slot = {**self.slot, "surface": "punctuated"}
        self.assertIn("surface:punctuated_lacks_case_or_marks", steps.spoken_problems(slot, SPOKEN, PLANTS))
        self.assertNotIn("surface:punctuated_lacks_case_or_marks",
                         steps.spoken_problems(slot, "So the delivery, um, is is moving to Wednesday, no wait, "
                                               "Thursday.", PLANTS))

    def test_spoken_relation_checks_use_the_plants(self):
        failed, _ = steps.spoken_vs_typed(self.slot, SPOKEN, TYPED, PLANTS)
        self.assertEqual(failed, [])
        failed, _ = steps.spoken_vs_typed(self.slot, SPOKEN.replace("not changing", "changing"), TYPED, PLANTS)
        self.assertIn("negation", failed)


class NegationFaithfulTests(unittest.TestCase):
    def check(self, spoken, typed, plants=()):
        return steps.negation_faithful(spoken, typed, list(plants))["problems"]

    def test_a_restart_that_repeats_a_negation_is_explained(self):
        spoken = "the old tank wouldn't like it was the old tank wouldn't fit through the door"
        self.assertEqual(self.check(spoken, "The old tank wouldn't fit through the door."), [])

    def test_a_negation_the_speech_lost_is_caught(self):
        self.assertEqual(self.check("we should ship friday", "We should not ship Friday."), ["negation_lost"])

    def test_an_unexplained_extra_negation_is_caught(self):
        self.assertEqual(self.check("we should not ship on friday because the build is flaky at the moment and the docs are late "
                                    "and we did not test it", "We should not ship on Friday."),
                         ["negation_unexplained"])

    def test_a_planted_negation_correction_explains_the_extra(self):
        plant = {"kind": "negation_corrected", "said_first": "we should", "ended_on": "we should not"}
        self.assertEqual(self.check("we should we should not ship friday", "We should not ship Friday.", [plant]), [])
        plant["kind"] = "opening_adds"
        # an opening that adds something is not a correction, and a restart is explained only by repetition
        self.assertEqual(self.check("we should ship friday", "We should not ship Friday.", [plant]), ["negation_lost"])


class MeaningTests(unittest.TestCase):
    def test_agreeing_texts(self):
        self.assertEqual(meaning.compare_typed(TYPED, TYPED.replace("Please tell", "Tell"))["problems"], [])

    def test_each_kind_of_disagreement(self):
        self.assertIn("numbers", meaning.compare_typed(TYPED, TYPED.replace("$4,200", "$4,500"))["problems"])
        self.assertIn("dates", meaning.compare_typed(TYPED, TYPED.replace("Friday", "Monday"))["problems"])
        self.assertIn("names", meaning.compare_typed(TYPED, TYPED.replace("Marta", "Mario"))["problems"])
        self.assertIn("negation", meaning.compare_typed(TYPED, TYPED.replace("are not", "are"))["problems"])
        self.assertIn("negation", meaning.compare_typed(TYPED.replace("are not", "are"), TYPED)["problems"])

    def test_a_value_added_by_the_second_text(self):
        result = meaning.compare_typed(TYPED, TYPED + " Call at 9.")
        self.assertIn("numbers", result["problems"])


class ReportTests(unittest.TestCase):
    def row(self, id, plan=(), failed=(), status="agree"):
        slot = {"kind": "an email", "profile": "moderate", "surface": "plain", "plants": []}
        return {"id": id, "slot": slot, "typed": TYPED, "spoken": SPOKEN, "plants": [], "spoken_words": 30,
                "plan_problems": list(plan), "failed_checks": list(failed), "meaning": {"status": status, "problems": []}}

    def test_funnel_counts_where_each_passage_fell_out(self):
        rows = [self.row("a"), self.row("b", plan=["band:1"]), self.row("c", failed=["numbers"]),
                self.row("d", status="disagree"), self.row("e", status="no_second_typed")]
        typed = [{"id": r["id"], "problems": []} for r in rows] + [{"id": "f", "problems": ["not_prose"]}]
        counts = report.funnel(typed, rows, rows)
        self.assertEqual((counts["planned"], counts["typed_kept"], counts["kept_after_step_3"]), (6, 5, 1))
        self.assertEqual((counts["fell_out_spoken_plan"], counts["fell_out_spoken_checks"], counts["fell_out_meaning"],
                          counts["no_second_typed"]), (1, 1, 1, 1))

    def test_rendering_states_what_is_not_done(self):
        text = report.render([], [], [self.row("a")], "$1")
        self.assertIn("Not done: groups", text)
        self.assertIn(TYPED.split(".")[0], text)


class RunTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="retrain-pilot-test-")
        self.addCleanup(self.temp.cleanup)
        self.dir = Path(self.temp.name).resolve()
        secret = tempfile.TemporaryDirectory(prefix="retrain-pilot-key-")
        self.addCleanup(secret.cleanup)
        self.key_file = Path(secret.name) / "key"
        self.key_file.write_text(FAKE_KEY + "\n")
        self.key_file.chmod(0o600)
        patcher = patch.object(api_judge, "SLEEP", lambda s: None)
        patcher.start()
        self.addCleanup(patcher.stop)
        slots = planner.plan(7)[:3]
        for slot in slots:
            slot["profile"], slot["plants"], slot["surface"] = "moderate", ["value_cue"], "plain"
            slot["band"], slot["typed_words_target"], slot["spoken_words_target"] = [10, 60], 30, 33
        pilot.write_lines(self.dir / "plan.jsonl", slots)

    def server(self, answer):
        api = FakeApi(lambda index, request, headers: (200, {}, message(answer(request))))
        self.addCleanup(api.close)
        return api

    def run_cli(self, command, *extra, server=None):
        argv = [command, "--scratch-dir", str(self.dir), "--invented-or-public"] + list(extra)
        if command in ("typed", "spoken"):
            argv += ["--state-dir", str(self.dir / "state"), "--key-file", str(self.key_file), "--max-dollars", "5"]
            if server:
                argv += ["--base-url", server.url]
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = pilot.main(argv)
        return code, out.getvalue(), err.getvalue()

    def lines(self, name):
        return [json.loads(x) for x in (self.dir / name).read_text().splitlines() if x.strip()]

    def test_typed_then_spoken_end_to_end(self):
        def typed_answer(request):
            card = request["messages"][0]["content"]
            self.assertIn("<card>", card)
            return {"typed": TYPED + " " + str(len(request["messages"][0]["content"]))}
        api = self.server(typed_answer)
        code, out, err = self.run_cli("typed", "--plan", str(self.dir / "plan.jsonl"), "--out", str(self.dir / "t"),
                                      server=api)
        self.assertEqual(code, 0, err)
        rows = self.lines("t.typed.jsonl")
        self.assertEqual(len(rows), 3)
        self.assertIn("near-duplicates", out)
        self.assertNotIn(FAKE_KEY, out + err + "".join(p.read_text(errors="replace") for p in self.dir.rglob("*")
                                                       if p.is_file() and p.name != "key"))
        spoken_api = self.server(lambda request: {"spoken": SPOKEN, "plants": PLANTS})
        code, out, err = self.run_cli("spoken", "--typed", str(self.dir / "t.typed.jsonl"), "--out", str(self.dir / "s"),
                                      server=spoken_api)
        self.assertEqual(code, 0, err)
        spoken = self.lines("s.spoken.jsonl")
        self.assertEqual(len(spoken), len([r for r in rows if not r["problems"]]))
        self.assertTrue(all(r["spoken"] == SPOKEN for r in spoken))
        self.assertIn("spoken:", out)

    def test_dry_run_sends_nothing_and_does_not_open_the_key(self):
        self.key_file.unlink()
        code, out, err = self.run_cli("typed", "--plan", str(self.dir / "plan.jsonl"), "--out", str(self.dir / "t"),
                                      "--dry-run")
        self.assertEqual(code, 0, err)
        self.assertIn("key file was not opened", out)

    def test_resumed_dry_run_reports_remaining_cap(self):
        ledger = api_judge.Ledger(self.dir / "state" / "ledger.jsonl")
        ledger.append({"dollars": 0.25})
        code, out, err = self.run_cli("typed", "--plan", str(self.dir / "plan.jsonl"),
                                      "--out", str(self.dir / "t"), "--dry-run")
        self.assertEqual(code, 0, err)
        self.assertIn("ledger so far $0.25", out)
        self.assertIn("of the $5.00 cap, remaining $4.75", out)

    def test_the_pilot_cap_stops_a_step(self):
        state = self.dir / "state"
        state.mkdir()
        (state / "ledger.jsonl").write_text(json.dumps({"dollars": pilot.PILOT_CAP_DOLLARS}) + "\n")
        api = self.server(lambda request: {"typed": TYPED})
        code, out, err = self.run_cli("typed", "--plan", str(self.dir / "plan.jsonl"), "--out", str(self.dir / "t"),
                                      "--max-dollars", "20", server=api)
        self.assertEqual(code, 1)
        self.assertIn("cumulative cap of $5.00 is spent (ledger $15.00)", err)
        self.assertEqual(api.requests, [])

    def test_meaning_step_compares_against_the_writers_texts(self):
        base = {"id": "p01", "slot": {}, "typed": TYPED, "spoken": SPOKEN, "plants": PLANTS}
        pilot.write_lines(self.dir / "s.spoken.jsonl", [base, {**base, "id": "p02"}, {**base, "id": "p03"}])
        second = {"typed": TYPED, "unsure": [], "usable": True}
        pilot.write_lines(self.dir / "w.accepted.jsonl", [{"id": "p01", **second}])
        pilot.write_lines(self.dir / "w.quarantine.jsonl", [{"id": "p02", **second, "typed": TYPED.replace("not ", "")}])
        code, out, err = self.run_cli("meaning", "--spoken", str(self.dir / "s.spoken.jsonl"),
                                      "--writer", str(self.dir / "w"), "--out", str(self.dir / "m"))
        self.assertEqual(code, 0, err)
        statuses = {r["id"]: r["meaning"]["status"] for r in self.lines("m.meaning.jsonl")}
        self.assertEqual(statuses, {"p01": "agree", "p02": "disagree", "p03": "no_second_typed"})


if __name__ == "__main__":
    unittest.main()
