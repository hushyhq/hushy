#!/usr/bin/env python3
"""Offline tests for the speech-first pilot: plan, notes and spoken checks, the independent check against the notes,
and the group-level helpers. All text is invented; no network."""
import json
import hashlib
from collections import Counter
from pathlib import Path
import sys
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))

import retrain_assemble as assemble  # noqa: E402
import retrain_groups as groups  # noqa: E402
import retrain_groups_cli as cli  # noqa: E402
import retrain_speech as speech  # noqa: E402
import retrain_speech_plan as plan  # noqa: E402
import retrain_scale_pools as pools  # noqa: E402
import retrain_speech_steps as steps  # noqa: E402
from api_judge_verdict import VerdictError  # noqa: E402

NOTES = {
    "speaker": "dev", "addressee": "an AI agent", "situation": "mid task",
    "points": [{"text": "fix date in reply", "anchors": ["date", "reply"]},
               {"text": "bug in filter", "anchors": ["bug", "filter"]}],
    "facts": [{"kind": "name", "value": "Kiran", "about": "customer"}, {"kind": "date", "value": "the 14th", "about": "x"},
              {"kind": "time", "value": "6:00", "about": "x"}, {"kind": "amount", "value": "$150", "about": "x"},
              {"kind": "file", "value": "ReleaseFilter.swift", "about": "suspect"}],
    "negations": [{"text": "do not rewrite the whole reply", "anchor": "rewrite"}]}
TYPED = ("The reply to Kiran has the wrong date, so fix it to the 14th. There is a bug in ReleaseFilter.swift where "
         "the 6:00 drop shows early, and the float is $150. Do not rewrite the whole reply.")
PLANTS = [{"kind": "value_cue", "said_first": "the 12th", "ended_on": "the 14th"}]


class PlanTests(unittest.TestCase):
    def test_pilot_plan_is_frozen(self):
        digest = hashlib.sha256(json.dumps(plan.plan(11), sort_keys=True, ensure_ascii=False).encode()).hexdigest()
        self.assertEqual(digest, "55fc436f762d5a7438065bbb140089bfadc6bb77dfc5dc9150d4268b9f369863")

    def test_scale_pools_and_name_usage(self):
        self.assertGreaterEqual(len(pools.DOMAINS), 150)
        self.assertGreaterEqual(len(pools.ROLES), 80)
        for values in (pools.GIVEN_NAMES, pools.FAMILY_NAMES, pools.DOMAINS, pools.ROLES):
            self.assertEqual(len(values), len(set(values)))
        names = Counter(name for slot in plan.scale_plan(1200, 11) for name in slot["names"])
        self.assertLessEqual(max(names.values()), 3)

    def test_scale_has_fresh_attributes_and_quotas(self):
        for count in (600, 1200):
            slots = plan.scale_plan(count, 11)
            self.assertEqual(slots, plan.scale_plan(count, 11))
            self.assertNotEqual(slots, plan.scale_plan(count, 12))
            combos = {(s["domain"], s["role"], tuple(s["names"])) for s in slots}
            self.assertGreaterEqual(len(combos), count - 10)
            self.assertEqual(len({tuple(s["names"]) for s in slots}), count)
            self.assertEqual(Counter(s["family"] for s in slots),
                             Counter({"agent": count * 35 // 100, "chat": count * 20 // 100,
                                      "email": count * 20 // 100, "note": count * 15 // 100,
                                      "status": count * 10 // 100}))
            self.assertEqual(sum(s["band"][0] > 120 for s in slots), (count * 3 + 4) // 5)
            for slot in slots:
                if slot["band"][1] <= 40:
                    self.assertNotEqual(slot["profile"], "heavy")
                    self.assertLessEqual(len(slot["plants"]), 1)
                    self.assertNotIn("opening_adds", slot["plants"])
                if slot["profile"] == "clean":
                    self.assertFalse(slot["plants"])
                if slot["family"] != "agent":
                    self.assertNotIn("plan_reversal", slot["plants"])
                if not any(slot["facts"][k] for k in ("numbers", "dates", "times", "amounts")):
                    self.assertFalse(set(slot["plants"]) & set(plan.VALUE_PLANTS))

    def test_scale_plan_mix_and_reproducibility(self):
        first = plan.scale_plan(300, seed=7)
        self.assertEqual(first, plan.scale_plan(300, seed=7))
        self.assertEqual(len(first), 300)
        self.assertGreaterEqual(sum(s["family"] == "agent" for s in first), 90)
        self.assertGreaterEqual(sum(s["band"][0] > 120 for s in first), 150)

    def setUp(self):
        self.slots = plan.plan(11)
        self.summary = plan.summary(self.slots)

    def test_shape(self):
        self.assertEqual(self.summary["rows"], 45)
        self.assertGreaterEqual(self.summary["agent_share"], 0.30)
        self.assertEqual(set(self.summary["band"]), {"12-40", "40-100", "100-180", "180-280"})
        self.assertEqual(plan.plan(11), self.slots)

    def test_every_family_has_every_band_where_it_has_four_rows(self):
        for family, count in plan.FAMILY_ROWS:
            if count >= 4:
                bands = {tuple(s["band"]) for s in self.slots if s["family"] == family}
                self.assertEqual(len(bands), 4, family)

    def test_plan_reversals_belong_to_the_agent_family_and_short_rows_plant_at_most_one(self):
        for slot in self.slots:
            if "plan_reversal" in slot["plants"]:
                self.assertEqual(slot["family"], "agent")
            if slot["band"][1] <= 40:
                self.assertLessEqual(len(slot["plants"]), 1)
                self.assertNotEqual(slot["profile"], "heavy")
            if slot["profile"] == "clean":
                self.assertEqual(slot["plants"], [])


class CardAndValidatorTests(unittest.TestCase):
    def test_exemplars_differ_by_seed_and_are_windows_of_the_pool(self):
        pool = [{"id": str(i), "spoken": " ".join(f"w{i}x{j}" for j in range(150))} for i in range(20)]
        first, second = steps.pick_exemplars(pool, 1), steps.pick_exemplars(pool, 2)
        self.assertEqual(len(first), 2)
        self.assertNotEqual(first, second)
        self.assertEqual(steps.pick_exemplars(pool, 1), first)
        self.assertTrue(all(len(e.split()) <= steps.EXEMPLAR_WORDS for e in first))

    def test_notes_validation(self):
        self.assertEqual(steps.validate_notes(NOTES)["facts"][0]["value"], "Kiran")
        for bad in ({**NOTES, "points": []}, {**NOTES, "points": [{"text": "x", "anchors": ["Has Caps"]}]},
                    {**NOTES, "facts": [{"kind": "colour", "value": "red", "about": "x"}]}, {"speaker": "x"}):
            with self.assertRaises(VerdictError):
                steps.validate_notes(bad)

    def test_notes_problems_ask_for_the_planned_fact_kinds(self):
        slot = {"facts": {"names": False, "numbers": False, "dates": True, "times": False, "amounts": True,
                          "files": False}, "points": 2}
        self.assertEqual(speech.notes_problems(slot, NOTES), ["notes:unwanted_fact_kind:time"])
        self.assertEqual(speech.notes_problems({**slot, "facts": {**slot["facts"], "times": True}}, NOTES), [])


class SurfaceTests(unittest.TestCase):
    def test_spoken_forms_of_files_and_flags(self):
        self.assertEqual(steps.spoken_form("src/utils/parse.py"), "src slash utils slash parse dot py")
        self.assertEqual(steps.spoken_form("--parallel"), "dash dash parallel")
        self.assertEqual(steps.spoken_form("parse_input.py"), "parse underscore input dot py")
        self.assertEqual(steps.spoken_form(".env.local"), "dot env dot local")

    def test_a_file_must_be_said_aloud_and_the_text_must_look_like_a_recogniser_wrote_it(self):
        notes = {"facts": [{"kind": "file", "value": "--dry-run"}, {"kind": "file", "value": "quotes_q3.xlsx"}]}
        slot = {"surface": "plain"}
        ok = "run it with dash dash dry run and open quotes underscore q three dot x l s x first"
        self.assertEqual(steps.recogniser_problems(slot, ok, notes), [])
        found = steps.recogniser_problems(slot, "open quotes_q3.xlsx with --dry-run", notes)
        self.assertIn("surface:characters_a_recogniser_would_not_write", found)
        self.assertTrue(any("file_not_said_aloud" in f for f in found))
        self.assertIn("surface:characters_a_recogniser_would_not_write",
                      steps.recogniser_problems({"surface": "punctuated"}, "Open (the file).", {"facts": []}))


class AgainstNotesTests(unittest.TestCase):
    def check(self, typed=TYPED, plants=PLANTS, notes=NOTES):
        return steps.check_against_notes(notes, plants, typed)

    def test_a_faithful_typed_text_passes(self):
        self.assertTrue(self.check()["ok"], self.check())

    def test_each_kind_of_miss_is_named(self):
        self.assertIn("facts", self.check(TYPED.replace("the 14th", "the 12th"))["failed"])
        self.assertIn("facts", self.check(TYPED.replace("$150", "$100"))["failed"])
        self.assertIn("facts", self.check(TYPED.replace("Kiran", "Mira"))["failed"])
        self.assertIn("facts", self.check(TYPED.replace("6:00", "7:00"))["failed"])
        self.assertIn("points", self.check(TYPED.replace("bug", "problem"))["failed"])
        self.assertIn("negations", self.check(TYPED.replace("Do not rewrite", "Rewrite"))["failed"])
        self.assertIn("files", self.check(TYPED.replace("ReleaseFilter.swift", "the filter"))["failed"])

    def test_the_taken_back_value_must_not_survive(self):
        self.assertIn("plants", self.check(TYPED + " Or maybe the 12th.")["failed"])

    def test_a_file_left_as_spoken_words_is_reported_apart(self):
        verdict = self.check(TYPED.replace("ReleaseFilter.swift", "ReleaseFilter dot swift"))
        self.assertTrue(verdict["ok"] is False or verdict["files_left_as_words"])
        self.assertEqual(verdict["files_left_as_words"], ["ReleaseFilter.swift"])

    def test_an_anchor_may_sit_inside_a_longer_word(self):
        self.assertNotIn("points", self.check()["failed"])  # "filter" inside "ReleaseFilter"


class OverturnTests(unittest.TestCase):
    def test_a_writer_quarantine_for_negation_alone_is_overturned_when_the_restart_explains_it(self):
        row = {"spoken": "the old tank wouldn't like it was the old tank wouldn't fit", "plants": []}
        other = {"writer_route": "quarantine", "quarantine_reasons": ["check:negation"],
                 "typed": "The old tank wouldn't fit."}
        self.assertTrue(speech.overturned(row, other))
        self.assertFalse(speech.overturned(row, {**other, "quarantine_reasons": ["check:negation", "check:order"]}))
        self.assertFalse(speech.overturned({**row, "spoken": "the tank fits"}, other))

    def test_letters_spelled_aloud_and_a_one_of_three_anchor_slack(self):
        import retrain_wordchecks as wordchecks
        self.assertTrue(wordchecks.check_content_words_added("open quotes x l s x now", "Open quotes xlsx now.")["ok"])
        notes = {**NOTES, "points": [{"text": "p", "anchors": ["alpha", "reply", "date"]}], "facts": [],
                 "negations": []}
        self.assertTrue(steps.check_against_notes(notes, [], "The reply has the wrong date.")["ok"])
        two = {**notes, "points": [{"text": "p", "anchors": ["alpha", "beta"]}]}
        self.assertFalse(steps.check_against_notes(two, [], "The reply has the wrong date.")["ok"])


class GroupHelperTests(unittest.TestCase):
    def test_left_context_is_the_last_sentence_padded_to_fifteen_words(self):
        self.assertEqual(groups.left_context(""), "none")
        short = "We booked the van for Monday morning. It is blue."
        self.assertEqual(groups.left_context(short), short)
        long = "One. " + " ".join(f"w{i}" for i in range(40)) + "."
        self.assertEqual(len(groups.left_context(long).split()), 25)

    def test_join_and_same_text(self):
        pieces = [{"piece": "Hello there,", "new_paragraph": False}, {"piece": "how are you.", "new_paragraph": False},
                  {"piece": "Second paragraph.", "new_paragraph": True}]
        joined = groups.join_pieces(pieces)
        self.assertEqual(joined, "Hello there, how are you.\n\nSecond paragraph.")
        self.assertTrue(groups.same_text(joined, "Hello there,  how are you.\n\nSecond paragraph."))
        self.assertFalse(groups.same_text(joined, "Hello there, how are you. Second paragraph."))

    def test_corrections_that_cross_groups_are_flagged(self):
        texts = ["the meeting is on tuesday", "no wait wednesday at three"]
        plants = [{"kind": "value_cue", "said_first": "tuesday", "ended_on": "wednesday"},
                  {"kind": "opening_adds", "said_first": "the meeting", "ended_on": "the meeting is on tuesday"}]
        self.assertEqual(set(groups.seam_spanning(plants, texts)), {0, 1})
        self.assertEqual(groups.seam_spanning(plants[:1], ["the meeting is on tuesday no wait wednesday"]), {})

    def test_group_checks_are_separate_and_know_corrections_inside_the_group(self):
        plant = [{"kind": "value_cue", "said_first": "tuesday", "ended_on": "wednesday"}]
        outcome, failed = groups.group_checks("The meeting is on Tuesday, no wait, Wednesday at 3.",
                                              "The meeting is on Wednesday at 3.", plant,
                                              "the meeting is on tuesday no wait wednesday at three")
        self.assertEqual(failed, [])
        _, failed = groups.group_checks("The meeting is on Wednesday at 3.", "The meeting is on Wednesday at 4.", [], "x")
        self.assertEqual(failed, ["numbers"])

    def test_target_validation(self):
        good = {"pieces": [{"index": 0, "piece": "a", "new_paragraph": False, "span_representable": True, "reason": ""}]}
        self.assertEqual(groups.validate_targets(good), good)
        with self.assertRaises(VerdictError):
            groups.validate_targets({"pieces": [{"index": 0}]})


class AssembleTests(unittest.TestCase):
    def test_assess_marks_a_clean_group_accepted_and_a_seam_group_not(self):
        source = {"id": "x", "route": "speech_first", "family": "chat", "kind": "k", "profile": "moderate",
                  "surface": "plain", "spoken": "we ship on tuesday no wait wednesday and tell marta",
                  "typed": "We ship on Wednesday and tell Marta.", "plants": [
                      {"kind": "value_cue", "said_first": "tuesday", "ended_on": "wednesday"}]}
        group_row = {"id": "x", "wholeDraft": "We ship on Wednesday and tell Marta.", "groups": [
            {"index": 0, "text": "we ship on tuesday", "draft": "We ship on Tuesday.", "continuesSentence": False},
            {"index": 1, "text": "no wait wednesday and tell marta", "draft": "No wait Wednesday and tell Marta.",
             "continuesSentence": True}]}
        target = {"id": "x", "pieces": [
            {"index": 0, "piece": "We ship on", "new_paragraph": False, "span_representable": True, "reason": ""},
            {"index": 1, "piece": "Wednesday and tell Marta.", "new_paragraph": False, "span_representable": True,
             "reason": ""}]}
        prepared = {"x-whole": {"rejection": None, "draft": "d"}, "x-g0": {"rejection": None}, "x-g1": {"rejection": None}}
        result = assemble.assess(source, group_row, target, prepared)
        self.assertTrue(result["joined_equals_typed"])
        self.assertEqual([g["representable"] for g in result["groups"]], [False, False])
        self.assertTrue(all("seam" in g["not_representable_because"][0] for g in result["groups"]))
        self.assertFalse(any(g["accepted"] for g in result["groups"]))
        target["pieces"][1]["piece"] = "Wednesday and tell Mark."
        self.assertFalse(assemble.assess(source, group_row, target, prepared)["joined_equals_typed"])

    def test_typed_first_selection_prefers_heavy_rows_without_underscores(self):
        def row(i, profile, spoken="hello there"):
            return {"id": f"p{i}", "slot": {"profile": profile, "family": f"f{i % 3}"},
                    "meaning": {"status": "agree"}, "plan_problems": [], "failed_checks": [], "spoken": spoken}
        rows = [row(i, "moderate") for i in range(10)] + [row(20 + i, "heavy") for i in range(8)] \
            + [row(40, "heavy", "uses a_b here")]
        picked = cli.pick_typed_first(rows, 6)
        self.assertEqual(len(picked), 6)
        self.assertTrue(all(r["slot"]["profile"] == "heavy" for r in picked))
        self.assertNotIn("p40", [r["id"] for r in picked])


if __name__ == "__main__":
    unittest.main()
