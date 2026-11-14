#!/usr/bin/env python3
"""Invented fixtures for the public dictation scorer."""

import contextlib
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import retrain_public_eval as evaluation  # noqa: E402


def read_jsonl(path):
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]

EQUAL = (("twenty twenty four", "2024"), ("nineteen ninety nine", "1999"), ("a hundred", "100"),
         ("a thousand", "1000"), ("one million", "1000000"), ("two point five million", "2.5 million"),
         ("one hundred dollars", "$100"), ("seventy five percent", "75%"), ("three oh five", "3:05"),
         ("first", "1st"), ("the second of March", "the 2nd of March"), ("three p m", "3 p.m."),
         ("three p m", "3 pm"), ("3 p.m.", "3 pm"), ("e-mail", "email"),
         # Carried over from the first version of the scorer, and neighbours of the pairs above.
         ("At three thirty, twenty-first, five per cent.", "At 3:30, 21st, 5 percent."),
         ("one thousand two hundred", "1,200"), ("one hundred and five", "105"), ("two thousand and twenty four", "2024"),
         ("twelve hundred", "1200"), ("five million", "5 million"), ("two point five million dollars", "$2.5 million"),
         ("the thirtieth", "the 30th"), ("ten thousand", "10,000"), ("nine a m", "9 a.m."), ("OK then", "okay then"),
         ("five five five one two", "55512"), ("it’s here", "it's here"), ("café", "CAFÉ"))
UNEQUAL = (("ten", "10:00"), ("fifty fifty", "100"), ("thirteen twenty", "33"), ("between twenty and thirty", "between 50"),
           ("wait one second", "wait 3rd"), ("wait one second", "wait 12"), ("one hundred and five hundred", "105 hundred"),
           ("one hundred and five thousand", "105,000"), ("one thousand two thousand", "3000"),
           ("two point five million", "2 5000000"), ("I am here", "I a m here"), ("oh five", "05"))


class NormaliseTests(unittest.TestCase):
    def test_number_words_and_digit_forms_meet(self):
        for spoken, written in EQUAL:
            with self.subTest(spoken=spoken, written=written):
                self.assertEqual(evaluation.normalize(spoken), evaluation.normalize(written))

    def test_forms_that_must_stay_apart(self):
        for left, right in UNEQUAL:
            with self.subTest(left=left, right=right):
                self.assertNotEqual(evaluation.normalize(left), evaluation.normalize(right))

    def test_separate_numbers_are_never_added_together(self):
        self.assertEqual(evaluation.normalize("fifty fifty"), ["5", "0", "5", "0"])
        self.assertEqual(evaluation.normalize("thirteen twenty"), ["1", "3", "2", "0"])
        self.assertEqual(evaluation.normalize("between twenty and thirty"), ["between", "2", "0", "and", "3", "0"])
        self.assertEqual(evaluation.normalize("wait one second"), ["wait", "1", "second"])
        self.assertEqual(evaluation.normalize("wait 1 second"), ["wait", "1", "second"])
        self.assertEqual(evaluation.normalize("the 2nd of March"), ["the", "second", "of", "march"])
        self.assertEqual(evaluation.normalize("2.5 million"), ["2", "point", "5", "million"])

    def test_a_number_is_one_word_for_similarity(self):
        self.assertEqual(evaluation.word_similarity(["blue", "lantern"], ["blue", "copper"]), .5)
        self.assertEqual(evaluation.similarity_words("call 5551234 at 3:05 now"), ["call", "5551234", "at", "305", "now"])
        self.assertEqual(evaluation.similarity_words("fifty fifty"), ["5050"])


class DiagnosticTests(unittest.TestCase):
    SPOKEN = "send the report on tuesday no wait wednesday"
    REFERENCE = "Send the report on Wednesday."

    def test_retracted_wording_left_in_is_flagged(self):
        self.assertTrue(evaluation.retracted_wording_present(
            self.SPOKEN, self.REFERENCE, "Send the report on Tuesday, no wait, Wednesday."))
        self.assertTrue(evaluation.retracted_wording_present(
            self.SPOKEN, self.REFERENCE, "Send the report on Tuesday Wednesday."))

    def test_resolved_correction_is_not_flagged(self):
        self.assertFalse(evaluation.retracted_wording_present(self.SPOKEN, self.REFERENCE, self.REFERENCE))
        self.assertFalse(evaluation.retracted_wording_present(
            self.SPOKEN, self.REFERENCE, "Send the report on, wait, Wednesday."))

    def test_longer_output_for_another_reason_is_not_flagged(self):
        longer = "Please send the full quarterly report on Wednesday to the whole planning team today."
        self.assertFalse(evaluation.retracted_wording_present(self.SPOKEN, self.REFERENCE, longer))

    def test_correction_without_a_cue_word_is_flagged(self):
        spoken, reference = "the red one I mean the green one", "The green one."
        self.assertTrue(evaluation.retracted_wording_present(spoken, reference, "The red one, the green one."))
        self.assertFalse(evaluation.retracted_wording_present(spoken, reference, "The green one."))

    def test_retracted_numbers_count_and_fillers_do_not(self):
        spoken, reference = "um book it for five no six people", "Book it for six people."
        self.assertTrue(evaluation.retracted_wording_present(spoken, reference, "Book it for five, no, six people."))
        self.assertFalse(evaluation.retracted_wording_present(spoken, reference, "Um, book it for 6 people."))
        self.assertFalse(evaluation.retracted_wording_present("", reference, "Book it for five six people."))

    def test_a_word_the_reference_keeps_once_is_flagged_when_doubled(self):
        spoken, reference = "meet at the cafe no at the library near the cafe", "Meet at the library near the cafe."
        self.assertTrue(evaluation.retracted_wording_present(spoken, reference,
                                                             "Meet at the cafe, at the library near the cafe."))
        self.assertFalse(evaluation.retracted_wording_present(spoken, reference, reference))

    def test_opener_run_kept_in_any_part(self):
        spoken, reference = "um okay so the plan is ready", "The plan is ready."
        for output in ("So the plan is ready.", "Okay, so the plan is ready.", "OK the plan is ready.",
                       "Um, okay, so the plan is ready."):
            with self.subTest(output):
                self.assertTrue(evaluation.spoken_opener_kept(spoken, reference, output))
        self.assertTrue(evaluation.spoken_opener_kept("ok the plan is ready", reference, "Okay, the plan is ready."))
        self.assertTrue(evaluation.spoken_opener_kept("well so the plan is ready", "So the plan is ready.",
                                                      "Well, so the plan is ready."))

    def test_opener_not_kept_or_belonging_to_the_reference(self):
        spoken, reference = "um okay so the plan is ready", "The plan is ready."
        self.assertFalse(evaluation.spoken_opener_kept(spoken, reference, "The plan is ready."))
        self.assertFalse(evaluation.spoken_opener_kept(spoken, reference, "Well, the plan is ready."))
        self.assertFalse(evaluation.spoken_opener_kept("right turn ahead", "Right turn ahead.", "Right turn ahead."))
        self.assertFalse(evaluation.spoken_opener_kept("so the plan is ready", "So the plan is ready.",
                                                       "So the plan is ready."))
        self.assertFalse(evaluation.spoken_opener_kept("the plan so far is ready", reference, "So the plan is ready."))
        self.assertFalse(evaluation.spoken_opener_kept("", reference, "So the plan is ready."))
        self.assertFalse(evaluation.spoken_opener_kept(spoken, reference, ""))


class ScoreTests(unittest.TestCase):
    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.root = Path(folder.name)

    def write(self, name, items):
        (self.root / name).write_text("".join(json.dumps(item) + "\n" for item in items), encoding="utf-8")
        return self.root / name

    def fixture(self):
        outputs = self.write("outputs", [{"id": "a", "text": "Okay, the blue lantern glows at 3:05."},
                                         {"id": "b", "text": "Use the red lantern, sorry, the green lantern now."},
                                         {"id": "c", "text": "Call 5551235 now."}])
        references = self.write("references", [
            {"id": "a", "reference": "The blue lantern glows at three oh five.",
             "spoken": "Okay the blue lantern glows at three oh five"},
            {"id": "b", "reference": "Use the green lantern now.",
             "spoken": "Use the red lantern sorry the green lantern now"},
            {"id": "c", "reference": "Call 5551234 now."}])
        return outputs, references

    def test_score_counts_and_stamps_the_scorer_version(self):
        outputs, references = self.fixture()
        metrics = evaluation.score(outputs, references, self.root / "verdicts")
        self.assertEqual((metrics["rows"], metrics["exact"]), (3, 0))
        self.assertEqual((metrics["spoken_opener_kept"], metrics["retracted_wording_present"]), (1, 1))
        self.assertEqual(metrics["scorer_version"], evaluation.SCORER_VERSION)
        self.assertGreaterEqual(evaluation.SCORER_VERSION, 2)
        verdicts = {row["id"]: row for row in read_jsonl(self.root / "verdicts")}
        self.assertEqual(len(verdicts), 3)
        self.assertTrue(all(row["scorer_version"] == evaluation.SCORER_VERSION for row in verdicts.values()))
        self.assertEqual((verdicts["a"]["spoken_opener_kept"], verdicts["b"]["retracted_wording_present"]), (True, True))
        self.assertEqual(verdicts["c"]["word_similarity"], round(2 / 3, 4))  # a wrong number is one wrong word
        self.assertEqual(metrics["mean_word_similarity"],
                         round(sum(row["word_similarity"] for row in verdicts.values()) / 3, 4))

    def test_exact_uses_the_normalised_forms(self):
        outputs = self.write("outputs", [{"id": "a", "text": "It cost $100 on the 2nd, at 3 p.m."}])
        references = self.write("references", [{"id": "a", "reference": "It cost one hundred dollars on the second at 3 pm"}])
        metrics = evaluation.score(outputs, references, self.root / "verdicts")
        self.assertEqual((metrics["exact"], metrics["mean_word_similarity"]), (1, 1.0))

    def test_sealed_paths_are_refused_by_the_path_guard(self):
        outputs, references = self.fixture()
        verdicts = self.root / "verdicts"
        sealed = self.root / "heldout-v2-private.jsonl"
        for paths in ((sealed, references, verdicts), (outputs, sealed, verdicts),
                      (outputs, references, sealed)):
            with self.subTest(paths=paths), self.assertRaisesRegex(PermissionError, "forbidden pattern"):
                evaluation.score(*paths)
        self.assertFalse(verdicts.exists())

    def test_command_line_prints_the_version_and_explains_bad_rows(self):
        outputs, references = self.fixture()
        with contextlib.redirect_stdout(io.StringIO()) as printed:
            evaluation.main(["score", "--outputs", str(outputs), "--references", str(references),
                             "--verdicts", str(self.root / "verdicts")])
        self.assertRegex(printed.getvalue(), rf"scorer_version\s+{evaluation.SCORER_VERSION}\b")
        self.assertRegex(printed.getvalue(), r"retracted_wording_present\s+1\b")
        for label, broken in (("text", [{"id": "a"}]), ("id", [{"text": "Blue."}]), ("text", [{"id": "a", "text": 4}])):
            with self.subTest(label), self.assertRaises(SystemExit) as stopped:
                evaluation.main(["score", "--outputs", str(self.write("broken", broken)),
                                 "--references", str(references), "--verdicts", str(self.root / "other")])
            self.assertRegex(str(stopped.exception), f"^error: .*broken.*row 1.*{label}")
        with self.assertRaises(SystemExit) as stopped:
            evaluation.main(["score", "--outputs", str(self.write("fewer", [{"id": "a", "text": "Blue."}])),
                             "--references", str(references), "--verdicts", str(self.root / "other")])
        self.assertIn("IDs must match", str(stopped.exception))


if __name__ == "__main__":
    unittest.main()
