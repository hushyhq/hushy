import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import retrain_scale
import retrain_pilot


class ScaleTests(unittest.TestCase):
    def test_scale_budget_uses_one_explicit_cap(self):
        class Ledger:
            def total_dollars(self):
                return 15.5

        budget = retrain_pilot.budget_for_step(80, Ledger(), scale_run=True)
        self.assertEqual(budget.cap, 80)
        with self.assertRaises(Exception):
            retrain_pilot.budget_for_step(80, Ledger())

    def test_every_speech_step_declares_invented_text(self):
        # retrain_speech.py refuses any step, local ones included, without this flag.
        import contextlib, io
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            retrain_scale.main(["--count", "4", "--max-dollars", "1", "--out", "Evals/runs/retrain/scale-test", "--dry-run"])
        steps = json.loads(out.getvalue())["steps"]
        speech = [s for s in steps if "scripts/retrain_speech.py" in s["command"]]
        self.assertEqual({s["step"] for s in speech}, {"notes", "speech", "facts"})
        for step in speech:
            self.assertIn("--invented-or-public", step["command"], step["step"])

    def test_screen_repeated_passages(self):
        rows = [{"id": "a", "spoken": "Please send the blue report after the meeting to Mira today."},
                {"id": "b", "spoken": "Please send the blue report after the meeting to Mira today."}]
        kept, refused = retrain_scale.screen(rows, {})
        self.assertEqual([r["id"] for r in kept], ["a"])
        self.assertEqual(refused[0]["reason"], "batch_duplicate")

    def test_manifest_counts(self):
        plan = [{"id": "a", "family": "agent", "band": [180, 280], "plants": ["value_cue"],
                 "facts": {"times": True, "files": True}},
                {"id": "b", "family": "email", "band": [40, 120], "plants": [], "facts": {}}]
        result = retrain_scale.manifest(plan, {}, {})
        self.assertEqual(result["planned"]["family"], {"agent": 1, "email": 1})
        self.assertEqual(result["planned"]["features"]["times"], 1)

    def test_select_requires_requested_count_and_mix(self):
        sources = {str(i): {"family": "agent" if i < 40 else "email",
                             "spoken": "word " * (150 if i % 2 else 60)} for i in range(100)}
        chosen = retrain_scale.select_targets([{"id": str(i)} for i in range(100)], sources, 60)
        self.assertEqual(len(chosen), 60)
        self.assertGreaterEqual(sum(sources[t["id"]]["family"] == "agent" for t in chosen), 18)
        self.assertGreaterEqual(sum(len(sources[t["id"]]["spoken"].split()) > 120 for t in chosen), 30)
        self.assertTrue(retrain_scale.selection_status(chosen, sources, 60)["complete"])

    def test_default_attempt_estimate(self):
        self.assertEqual(retrain_scale.cost_estimate(300, 2.2),
                         {"attempted_passages": 660, "expected_surviving_labels": 393.25,
                          "expected_spend_dollars": 63.95})

    def test_select_keeps_short_batch_and_reports_shortfall(self):
        sources = {str(i): {"family": "email", "spoken": "word " * 60} for i in range(4)}
        chosen = retrain_scale.select_targets([{"id": str(i)} for i in range(4)], sources, 10)
        self.assertEqual(len(chosen), 4)
        status = retrain_scale.selection_status(chosen, sources, 10)
        self.assertFalse(status["complete"])
        self.assertEqual(status["shortfall"], 6)
        self.assertEqual(status["quotas"]["agent"]["actual_share"], 0)
        self.assertEqual(status["quotas"]["over_120_words"]["requested_share"], 0.5)

    def test_quota_miss_does_not_discard_available_labels(self):
        sources = {str(i): {"family": "email", "spoken": "word " * 150} for i in range(10)}
        chosen = retrain_scale.select_targets([{"id": str(i)} for i in range(10)], sources, 10)
        self.assertEqual(len(chosen), 10)
        self.assertFalse(retrain_scale.selection_status(chosen, sources, 10)["complete"])

    def test_provenance_refusal_retains_target_and_counts_findings(self):
        target = {"id": "a", "typed": "Hello", "pieces": [{"piece": "Hello"}]}
        groups = {"a": {"groups": [{"text": "Hello", "draft": "Hello"}]}}
        accepted, refused = retrain_scale.screen_provenance([target], groups,
                                                              lambda group, row: [{"kind": "grammar_repair"}])
        self.assertEqual(accepted, [])
        self.assertEqual(refused[0]["target"], target)
        self.assertEqual(retrain_scale.finding_counts(refused), {"grammar_repair": 1})


if __name__ == "__main__":
    unittest.main()
