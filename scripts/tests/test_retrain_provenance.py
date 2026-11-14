import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import retrain_provenance as provenance


class ProvenanceTests(unittest.TestCase):
    def test_neighbour_words_and_short_clause(self):
        row = {"groups": [{"text": "The parcel arrived before noon.", "draft": "The parcel arrived before noon."},
                          {"text": "Please call Mira.", "draft": "Please call Mira."}]}
        target = {"typed": "The parcel arrived before noon. Please call Mira.",
                  "pieces": [{"piece": "The", "new_paragraph": False},
                             {"piece": "parcel arrived before noon. Please call Mira.", "new_paragraph": False}]}
        findings = provenance.check(row, target)
        self.assertTrue(any(f["kind"] == "short_clause" and f["index"] == 0 for f in findings))
        self.assertTrue(any(f["kind"] == "neighbour_word" and f["index"] == 1 for f in findings))

    def test_typed_value_and_punctuation_are_allowed(self):
        row = {"groups": [{"text": "Meet at eight forty five.", "draft": "Meet at eight forty five."}]}
        target = {"typed": "Meet at 8:45.", "pieces": [{"piece": "Meet at 8:45."}]}
        self.assertEqual([], provenance.check(row, target))

    def test_join_mismatch_and_unlicensed_content(self):
        row = {"groups": [{"text": "The parcel arrived.", "draft": "The parcel arrived."}]}
        target = {"typed": "The parcel arrived.", "pieces": [{"piece": "The parcel departed."}]}
        kinds = {f["kind"] for f in provenance.check(row, target)}
        self.assertIn("joined_mismatch", kinds)
        self.assertIn("ungrounded_word", kinds)


if __name__ == "__main__":
    unittest.main()
