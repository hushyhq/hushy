#!/usr/bin/env python3
"""Offline tests for the round-7 row tools (retrain_r7_rows.py, retrain_r7_index.py). Every text here is invented."""
import contextlib
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
sys.path.insert(0, str(SCRIPTS / "finetune"))
import retrain_r7_index as r7_index  # noqa: E402
import retrain_r7_rows as r7  # noqa: E402
import retrain_public_index as index  # noqa: E402


def write(path, text):
    path.write_text(text, encoding="utf-8")
    return path


def quiet(function, *args, **kwargs):
    with contextlib.redirect_stdout(io.StringIO()) as captured:
        function(*args, **kwargs)
    return captured.getvalue()


class ParseFile(unittest.TestCase):
    def test_blocks_comments_and_multiline_targets(self):
        with tempfile.TemporaryDirectory() as folder:
            path = write(Path(folder) / "c01.txt", "# a comment\nS: first spoken text\nT: First line.\n\nSecond paragraph.\n\n"
                         "S: second one\nT: One\\nTwo\n")
            rows = r7.parse_file(path)
        self.assertEqual(rows[0], {"spoken": "first spoken text", "target": "First line.\n\nSecond paragraph."})
        self.assertEqual(rows[1], {"spoken": "second one", "target": "One\nTwo"})

    def test_block_without_target_is_an_error(self):
        with tempfile.TemporaryDirectory() as folder:
            path = write(Path(folder) / "a01.txt", "S: spoken only\n")
            with self.assertRaises(ValueError):
                r7.parse_file(path)


class Parse(unittest.TestCase):
    def test_screens_duplicates_ratio_and_probe_words(self):
        with tempfile.TemporaryDirectory() as folder:
            folder = Path(folder)
            src = folder / "src"
            src.mkdir()
            write(src / "a01.txt",
                  "S: put the screen shot in the shared folder before lunch\nT: Put the screenshot in the shared folder before lunch.\n\n"
                  "S: put the screen shot in the shared folder before lunch\nT: Put the screenshot in the shared folder before lunch.\n\n"
                  "S: we need a lap top for the new starter by friday\nT: We need a laptop for the new starter by Friday.\n\n"
                  "S: one two three four five six seven eight\nT: Eight.\n")
            probe = write(folder / "probe.jsonl", json.dumps({"id": "p", "heard": "lap top", "intended": ["laptop"]}) + "\n")
            out = folder / "out"
            summary = json.loads(quiet(r7.parse, src, out, [probe]))
            kept = r7.read_jsonl(out / "rows.jsonl")
            self.assertEqual(len(kept), 1)
            self.assertEqual(kept[0]["id"], "r7a001")
            self.assertEqual(summary["dropped_before_guard"], {"duplicate_spoken": 1, "probe_word": 1, "word_ratio": 1})
            self.assertEqual(r7.probe_words([probe]), ["lap top"])  # the right word alone is not a reason to drop

    def test_probe_word_matches_whole_words_only(self):
        self.assertEqual(r7.mentions("the flower shop", ["flower"]), ["flower"])
        self.assertEqual(r7.mentions("the flowers shop", ["flower"]), [])


class Filter(unittest.TestCase):
    def test_refused_targets_never_reach_the_training_files(self):
        with tempfile.TemporaryDirectory() as folder:
            out = Path(folder)
            rows = [{"id": "r7b001", "kind": "number-correction", "spoken": "meet at three no four", "target": "Meet at 4."},
                    {"id": "r7b002", "kind": "number-correction", "spoken": "meet at four", "target": "Meet at 5."}]
            r7.write_jsonl(out / "rows.jsonl", rows)
            verdicts = out / "verdicts.jsonl"
            r7.write_jsonl(verdicts, [{"id": "r7b001", "verdict": "accepted", "reason": ""},
                                      {"id": "r7b002", "verdict": "rejected", "reason": "changed digits"}])
            system = write(out / "system.txt", "Write what the speaker meant.")
            summary = json.loads(quiet(r7.filter_rows, out, verdicts, system))
            self.assertEqual((summary["kept"], summary["refused"]), (1, 1))
            self.assertEqual(summary["refused_by_reason"], {"changed digits": 1})
            labels = r7.read_jsonl(out / "labels.jsonl")
            self.assertEqual(labels, [{"id": "r7b001", "text": "Meet at 4."}])
            message = r7.read_jsonl(out / "round7-rows.jsonl")[0]["messages"]
            self.assertEqual(message[1]["content"], "Transcript: meet at three no four\nOutput:")
            self.assertEqual(json.loads(message[2]["content"]), {"text": "Meet at 4."})

    def test_missing_verdict_is_an_error(self):
        with tempfile.TemporaryDirectory() as folder:
            out = Path(folder)
            r7.write_jsonl(out / "rows.jsonl", [{"id": "r7a001", "kind": "sound-alike", "spoken": "a b", "target": "A b."}])
            verdicts = out / "verdicts.jsonl"
            r7.write_jsonl(verdicts, [])
            with self.assertRaises(ValueError):
                r7.filter_rows(out, verdicts, None)


class Index(unittest.TestCase):
    def test_index_holds_hashes_only_and_catches_an_eight_word_run(self):
        with tempfile.TemporaryDirectory() as folder:
            folder = Path(folder)
            public = write(folder / "public.jsonl", json.dumps(
                {"id": "h0", "spoken": "the quick brown fox jumps over the lazy dog", "reference": "A fox."}) + "\n")
            probe = write(folder / "probe.jsonl", json.dumps({"id": "n1", "spoken": "dial nine one one in an emergency"}) + "\n")
            disfl = write(folder / "disfl-qa-sample.jsonl", json.dumps(
                {"id": "q1", "original": "when was the bridge built", "disfluent": "when was the uh no the bridge built"}) + "\n")
            out = folder / "index.json"
            counts = r7_index.build([public], [probe], [disfl], out)
            text = out.read_text(encoding="utf-8")
            self.assertNotIn("quick", text)
            self.assertEqual(counts["strings"]["disfl-qa-sample.jsonl"], 2)
            loaded = index.Index(frozenset(json.loads(text)["whole"]), frozenset(json.loads(text)["shingles"]))
            self.assertEqual(index.overlap(loaded, "the quick brown fox jumps over the lazy dog"), "benchmark_overlap")
            self.assertEqual(index.overlap(loaded, "he said the quick brown fox jumps over the lazy dog again"),
                             "benchmark_shingle_overlap")
            self.assertIsNone(index.overlap(loaded, "a slow grey cat sits under the old table"))


if __name__ == "__main__":
    unittest.main()
