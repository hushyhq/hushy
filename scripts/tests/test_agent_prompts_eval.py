import json
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
import agent_prompts_eval as scoring  # noqa: E402


class AgentPromptsEvalTests(unittest.TestCase):
    def test_verdict_identifier_and_requirements(self):
        reference = {
            "id": "x1",
            "intended": "Update package.json.",
            "identifiers": ["package.json"],
            "requirements": ["lockfile changes"],
            "list_items": 0,
        }
        row = scoring.verdict(reference, "Update package.json and tell me about lockfile changes.")
        self.assertEqual(row["identifier_exact_rate"], 1.0)
        self.assertEqual(row["requirements_kept_rate"], 1.0)
        self.assertFalse(row["answered_instead_of_cleaned"])

    def test_score_round_trip(self):
        cases = {
            "a": {
                "id": "a",
                "intended": "Run --quick.",
                "identifiers": ["--quick"],
                "requirements": ["failing test names"],
                "list_items": 0,
            }
        }
        with tempfile.TemporaryDirectory() as tmp:
            cases_path = Path(tmp) / "cases.jsonl"
            outputs_path = Path(tmp) / "out.jsonl"
            verdicts_path = Path(tmp) / "verdicts.jsonl"
            cases_path.write_text(json.dumps(cases["a"]) + "\n", encoding="utf-8")
            outputs_path.write_text(
                json.dumps({"id": "a", "text": "Run --quick and paste failing test names only."}) + "\n",
                encoding="utf-8",
            )
            summary = scoring.score(cases_path, outputs_path, verdicts_path)
            self.assertEqual(summary["rows"], 1)
            self.assertEqual(summary["identifier_exact_all"], 1)


if __name__ == "__main__":
    unittest.main()
