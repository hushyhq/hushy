"""Prompt-version propagation tests; no data generation or inference is performed."""

from __future__ import annotations

import argparse
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import build_data  # noqa: E402


class PromptVersionTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.out = Path(self.tmp.name)
        self.args = argparse.Namespace(out=self.out, eval_bin=Path("murmur-eval"),
                                       prompt_version="compact-v3")
        self.manifest = Mock()

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def _assert_version_passed(self, call: unittest.mock._Call) -> None:
        argv = call.args[1:]
        self.assertIn("--prompt-version", argv)
        self.assertEqual(argv[argv.index("--prompt-version") + 1], "compact-v3")

    @patch.object(build_data, "run_eval")
    def test_canonicalization_and_guard_prepare_receive_version(self, run_eval: Mock) -> None:
        row = {"id": "x", "level": "clean", "seedTarget": "example", "canon": True,
               "negative": False, "raw": "example", "target": "example"}
        self.manifest.read_jsonl.return_value = [{"id": "x", "draft": "example"}]

        build_data.canonicalise([row], self.args, self.manifest)
        build_data.guard([row], self.args, self.manifest, "prepare")

        self.assertEqual(run_eval.call_count, 2)
        for call in run_eval.call_args_list:
            self.assertEqual(call.args[1], "prepare")
            self._assert_version_passed(call)

    @patch.object(build_data, "run_eval")
    def test_export_receives_version(self, run_eval: Mock) -> None:
        build_data.export_training_data(self.args, self.manifest)
        self._assert_version_passed(run_eval.call_args)
        self.assertEqual(self.manifest.record_write.call_count, 3)

    @patch.object(build_data, "generate_content")
    def test_invalid_version_is_rejected_before_data_generation(self, generate_content: Mock) -> None:
        with self.assertRaises(SystemExit):
            build_data.main(["--out", str(self.out / "out"), "--prompt-version", "compact-v9"])
        generate_content.assert_not_called()
        self.assertFalse((self.out / "out").exists())


if __name__ == "__main__":
    unittest.main()
