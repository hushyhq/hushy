#!/usr/bin/env python3
"""Offline tests for the synthetic dictation judge wrapper."""

import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parent.parent
EVALS = ROOT / "Evals"
PILOT = EVALS / "judge" / "pilot-2026-10-04"
REPORT = EVALS / "developer-messages-dev-baseline-local-2026-10-04.json"
SPEC = importlib.util.spec_from_file_location("llm_judge", ROOT / "scripts" / "llm-judge.py")
JUDGE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(JUDGE)


def call(*args):
    return subprocess.run([sys.executable, str(ROOT / "scripts" / "llm-judge.py"), *map(str, args)],
                          capture_output=True, text=True, check=False)


class JudgeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=EVALS, prefix="judge-test-")
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)

    def test_build_matches_pilot_and_blinds(self):
        output = self.directory / "input.json"
        result = call("build", "--report", REPORT, "--out", output)
        self.assertEqual(result.returncode, 0, result.stderr)
        actual = json.loads(output.read_text())
        self.assertEqual(actual, json.loads((PILOT / "baseline-input.json").read_text()))
        self.assertEqual(list(actual[0]), list(JUDGE.INPUT_FIELDS))
        forbidden = {"passed", "checks", "ideal", "rulesOutput", "category", "classified"}
        self.assertTrue(all(forbidden.isdisjoint(item) for item in actual))

    def test_sealed_families_are_refused_by_name(self):
        for name in ("Evals/voicelab-take.json", "Evals/ab-session.jsonl",
                     "Evals/eval-long64-b1.jsonl", "Evals/longb-notes.jsonl",
                     "Evals/runs/sealed/private.jsonl"):
            with self.subTest(name=name), self.assertRaises(JUDGE.JudgeError):
                JUDGE.refuse_sealed_name(name)

    def test_guards(self):
        output = self.directory / "output.json"
        for word in ("heldout", "sealed"):
            with self.subTest(word=word):
                path = self.directory / f"{word}.json"
                self.assertNotEqual(call("build", "--report", path, "--out", output).returncode, 0)
                self.assertNotEqual(call("run", "--input", path, "--out", output).returncode, 0)
        outside = ROOT / "CLAUDE.md"
        self.assertTrue(outside.is_file())
        for command, source_flag in (("build", "--report"), ("run", "--input")):
            refusal = call(command, source_flag, outside, "--out", output)
            self.assertNotEqual(refusal.returncode, 0)
            self.assertIn("outside repository Evals/", refusal.stderr)
        for command, source_flag, source in (("build", "--report", REPORT),
                                             ("run", "--input", PILOT / "baseline-input.json")):
            self.assertNotEqual(call(command, source_flag, source, "--out",
                                     self.directory / "sealed-output.json").returncode, 0)
        sealed_verdicts = self.directory / "sealed-verdicts.json"
        sealed_verdicts.write_text((PILOT / "baseline-codex.json").read_text())
        refusal = call("summarise", "--input", PILOT / "baseline-input.json", "--verdicts", sealed_verdicts)
        self.assertNotEqual(refusal.returncode, 0)
        self.assertIn("refused path", refusal.stderr)
        report = json.loads(REPORT.read_text())
        report["caseFile"] = "unapproved-dev.json"
        changed = self.directory / "report.json"
        changed.write_text(json.dumps(report))
        refusal = call("build", "--report", changed, "--out", output)
        self.assertNotEqual(refusal.returncode, 0)
        self.assertIn("caseFile", refusal.stderr)
        with patch.object(JUDGE, "assert_tuning_safe", side_effect=JUDGE.JudgeError("hash refused")):
            with self.assertRaisesRegex(JUDGE.JudgeError, "hash refused"):
                JUDGE.safe_source(REPORT)
            with self.assertRaisesRegex(JUDGE.JudgeError, "hash refused"):
                JUDGE.safe_source(PILOT / "baseline-input.json")
        self.assertFalse(output.exists())

    def fake_command(self, mode):
        script = self.directory / "fake.py"
        script.write_text("""import json, pathlib, sys
directory = pathlib.Path(sys.argv[-1])
items = json.loads((directory / 'judge_input.json').read_text())
assert '{{ITEM_COUNT}}' not in (directory / 'RUBRIC.md').read_text()
assert f'Judge all {len(items)} items' in (directory / 'RUBRIC.md').read_text()
verdicts = [dict(n=x['n'], id=x['id'], level=x['level'], faithful=True,
                 mechanics=True, sendable=True, problems=[], note='') for x in items]
mode = sys.argv[1]
if mode == 'count': verdicts.pop()
if mode == 'order': verdicts[0], verdicts[1] = verdicts[1], verdicts[0]
if mode == 'boolean': verdicts[0]['faithful'] = 1
if mode == 'tag': verdicts[0]['problems'] = ['invented_tag']
(directory / 'verdicts.json').write_text(json.dumps(verdicts))
""")
        return f"{sys.executable} {script} {mode}"

    def test_run_fake_judge_and_validation(self):
        source = PILOT / "baseline-input.json"
        for mode in ("good", "count", "order", "boolean", "tag"):
            with self.subTest(mode=mode):
                output = self.directory / f"{mode}.json"
                result = call("run", "--input", source, "--out", output,
                              "--judge-cmd", self.fake_command(mode))
                if mode == "good":
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(len(json.loads(output.read_text())), 120)
                else:
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("llm-judge:", result.stderr)
                    self.assertFalse(output.exists())

    def test_pilot_summary_numbers(self):
        baseline = PILOT / "baseline-input.json"
        after = PILOT / "after-fixes-1-input.json"
        codex = PILOT / "baseline-codex.json"
        for name, source, expected in (
            ("baseline-codex.json", baseline, (29, 29)),
            ("baseline-sonnet.json", baseline, (32, 31)),
            ("after-fixes-1-codex.json", after, (34, 35)),
        ):
            with self.subTest(name=name):
                result = call("summarise", "--input", source, "--verdicts", PILOT / name, "--json")
                self.assertEqual(result.returncode, 0, result.stderr)
                levels = json.loads(result.stdout)["levels"]
                self.assertEqual((levels["clean"]["good"], levels["polished"]["good"]), expected)
        result = call("summarise", "--input", after, "--verdicts", PILOT / "after-fixes-1-codex.json",
                      "--before-input", baseline, "--before-verdicts", codex,
                      "--report", REPORT, "--json")
        self.assertEqual(result.returncode, 0, result.stderr)
        data = json.loads(result.stdout)
        repeated = data["repeatability"]
        self.assertEqual(sum(row["unchanged_outputs"] for row in repeated.values()), 100)
        changed = [(level, identifier) for level, row in repeated.items()
                   for identifier in row["changed_good_on_unchanged_outputs"]]
        self.assertEqual(changed, [("polished", "slack-teammate-04")])
        self.assertEqual((data["rules"]["clean"]["rule_pass"],
                          data["rules"]["polished"]["rule_pass"]), (39, 36))


if __name__ == "__main__":
    unittest.main()
