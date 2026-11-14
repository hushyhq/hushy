import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


def module(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / "scripts" / f"{name}.py")
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


cases = module("person_memory_cases")
scorer = module("person_memory_score")


class PersonMemoryTest(unittest.TestCase):
    def test_cases_are_complete_and_invented(self):
        rows = cases.make_rows()
        self.assertEqual(len(rows), 60)
        self.assertEqual(len({row["id"] for row in rows}), 60)
        self.assertEqual(sum(row["control"] for row in rows), 15)
        for row in rows:
            history = row["history"]
            self.assertTrue(10 <= len(history["terms"]) <= 30)
            self.assertTrue(2 <= len(history["earlier"]) <= 4)
            self.assertTrue(1 <= len(history["edits"]) <= 3)
            self.assertTrue(row["spoken"] and row["expected"] and row["keyItems"])
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "cases.jsonl"
            cases.write(path)
            self.assertEqual(len(path.read_text().splitlines()), 61)
            self.assertEqual(json.loads(path.read_text().splitlines()[0])["kinds"]["control-near"], 12)

    def test_copy_requires_unspoken_four_word_run(self):
        row = cases.make_rows()[0]
        self.assertTrue(scorer.copied("The amber lantern stays beside the west gate.", row))
        self.assertFalse(scorer.copied(row["spoken"], row))
        self.assertFalse(scorer.copied("The amber lantern stays", {**row, "spoken": "The amber lantern stays"}))


if __name__ == "__main__":
    unittest.main()
