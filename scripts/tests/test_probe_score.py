#!/usr/bin/env python3
"""Offline tests for scripts/probe_score.py. Every case and answer here is invented."""
from pathlib import Path
import sys
import unittest

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
import probe_score as ps  # noqa: E402

REPO = SCRIPTS.parent


class NumberScoring(unittest.TestCase):
    CASE = {"expect": [["10"], ["12"]], "forbid": ["9", "11"]}

    def test_corrected_values_pass(self):
        self.assertEqual(ps.score_number(self.CASE, "Deliveries are between 10 and 12 on Friday."), [])

    def test_retracted_value_kept_fails(self):
        self.assertIn("kept 9", ps.score_number(self.CASE, "Between 9 and 12."))

    def test_digit_inside_longer_number_is_not_a_match(self):
        self.assertEqual(ps.find_value("room 119", "11"), -1)
        self.assertEqual(ps.find_value("it weighs 2.5 kilos", "2"), -1)
        self.assertGreaterEqual(ps.find_value(ps.norm("it costs $1,250 today"), "1250"), 0)

    def test_phone_digits_ignore_punctuation(self):
        case = {"expect": [["digits:4155550198"]]}
        self.assertEqual(ps.score_number(case, "Call (415) 555-0198 after lunch."), [])
        self.assertTrue(ps.score_number(case, "Call 415 555 0189."))

    def test_digit_run_is_not_a_substring_or_two_numbers(self):
        case = {"expect": [["digits:4471"]]}
        self.assertEqual(ps.score_number(case, "The invoice number is 4471."), [])
        self.assertEqual(ps.score_number(case, "It is 44 71."), [])
        self.assertTrue(ps.score_number(case, "144719"))
        self.assertTrue(ps.score_number(case, "The codes are 44 and 71."))
        self.assertTrue(ps.score_number(case, "room 44, locker 71"))

    def test_counts_and_no_digits(self):
        self.assertTrue(ps.score_number({"counts": {"45": 2}}, "I counted 45 in the morning."))
        self.assertEqual(ps.score_number({"counts": {"45": 2}}, "45 in the morning and 45 after."), [])
        self.assertTrue(ps.score_number({"no_digits": True}, "Pick the 1 you want."))


class PromptScoring(unittest.TestCase):
    CASE = {"spoken": "one tighten it two cut it three keep it kind", "must": [["tighten"], ["cut"], ["kind"]],
            "ordered": True, "min_list": 3, "max_ratio": 2.0}

    def test_numbered_list_passes(self):
        self.assertEqual(ps.score_prompt(self.CASE, "Please:\n1. Tighten it\n2. Cut it\n3. Keep it kind"), [])

    def test_prose_answer_has_too_few_list_lines(self):
        self.assertTrue(any("list lines" in p for p in ps.score_prompt(self.CASE, "Tighten it, cut it, keep it kind.")))

    def test_order_and_fence(self):
        problems = ps.score_prompt(self.CASE, "1. Cut it\n2. Tighten it\n3. Kind\n```")
        self.assertIn("items out of order", problems)
        self.assertIn("code fence", problems)

    def test_paragraph_count(self):
        case = {"spoken": "a b c", "must": [], "min_paragraphs": 2}
        self.assertTrue(ps.score_prompt(case, "One block only."))
        self.assertEqual(ps.score_prompt(case, "First.\n\nSecond."), [])


class ShippedProbes(unittest.TestCase):
    @unittest.skipUnless((REPO / "Evals" / "number-probe.jsonl").exists() and (REPO / "Evals" / "prompt-probe.jsonl").exists(),
                         "needs the private probe sets Evals/number-probe.jsonl and Evals/prompt-probe.jsonl")
    def test_probe_files_are_well_formed(self):
        for name, key in (("number-probe.jsonl", "expect"), ("prompt-probe.jsonl", "must")):
            cases = ps.rows(str(REPO / "Evals" / name))
            self.assertTrue(40 <= len(cases) <= 60, name)
            self.assertEqual(len({c["id"] for c in cases}), len(cases))
            for case in cases:
                self.assertTrue(case["spoken"].strip() and key in case and case["kind"], case["id"])
                self.assertEqual(case["spoken"], case["spoken"].lower().strip())


if __name__ == "__main__":
    unittest.main()
