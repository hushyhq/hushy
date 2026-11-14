#!/usr/bin/env python3
import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from gate_cleanup_made_worse import score_row, transition  # noqa: E402


class MadeWorseTests(unittest.TestCase):
    def test_filler_removal_not_worse(self):
        counts = transition("Meet Priya at noon.", "Meet Priya um at noon.", "Meet Priya at noon.")
        self.assertEqual(counts["worse"], 0)

    def test_sound_alike_counts_worse(self):
        counts = transition(
            "Ship the Priya build tonight.",
            "Ship the Priya build tonight.",
            "Ship the piranha build tonight.",
        )
        self.assertGreaterEqual(counts["worse"], 1)

    def test_per_step_model(self):
        steps = {
            "recognizer": "Call Priya before five.",
            "boosted": "Call Priya before five.",
            "fixers": "Call Priya before five.",
            "model": "Call piranha before five.",
            "checks": "Call piranha before five.",
        }
        per = score_row("Call Priya before five.", steps)
        self.assertGreaterEqual(per["model"]["worse"], 1)
        self.assertEqual(per["checks"]["worse"], 0)


if __name__ == "__main__":
    unittest.main()
