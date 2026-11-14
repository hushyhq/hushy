#!/usr/bin/env python3
"""Invented fixtures for the benchmark contamination index and its narrow guard door."""

import contextlib
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
from retrain_public_fixtures import HEX, benchmark_files, lantern_source, make_base, tower_ids  # noqa: E402
import retrain_public_rows as rows  # noqa: E402
import retrain_public_index as index  # noqa: E402
import pathguard  # noqa: E402  (on the path once retrain_public_rows is imported)


class BenchmarkIndexTests(unittest.TestCase):
    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.root = Path(folder.name)

    def test_benchmark_index_holds_only_hashes(self):
        qa, speech = benchmark_files(self.root)
        out = self.root / "made" / "later" / "index.json"  # build creates the parent folder
        report = index.build([qa, speech], out)
        hashes = json.loads(out.read_text())
        # Seven non-empty strings; "a velvet anvil" and "A velvet anvil." normalise to one.
        self.assertEqual((len(hashes), report["hashes"], report["shingles"]), (6, 6, 0))
        self.assertTrue(all(isinstance(item, str) and len(item) == 64 and set(item) <= HEX for item in hashes))
        self.assertFalse(set(out.read_text()) - HEX - set('[]",\n '))
        self.assertIn(index.text_hash("where does the quartz heron nest"), hashes)
        self.assertEqual(index.normalise("  The AMBER, lantern's   tower-9! "), "the amber lanterns tower9")

    def test_benchmark_door_is_narrow(self):
        qa, _ = benchmark_files(self.root)
        with self.assertRaises(pathguard.ForbiddenPathError):
            pathguard.check(qa)
        with self.assertRaises(pathguard.ForbiddenPathError):
            rows.write_rows(qa, [])
        with self.assertRaises(pathguard.ForbiddenPathError):
            pathguard.Manifest(self.root).read_json(qa)
        with self.assertRaises(pathguard.ForbiddenPathError):
            index.build([qa], qa.parent / "index.json")
        for path in ("x/disfl-qa/meeting-eval/dev.json", "x/disfl-qa/negatives-fresh-dev.json", "x/gate/disflqa.json"):
            with self.subTest(path), self.assertRaises(pathguard.ForbiddenPathError):
                pathguard.check_benchmark_source(path)
        (qa.parent / "blank.jsonl").write_text(json.dumps({"id": "a", "words": 3}) + "\n")
        with self.assertRaisesRegex(ValueError, "no indexable text"):
            index.build([qa.parent / "blank.jsonl"], self.root / "index.json")
        (qa.parent / "packed.bin").write_bytes(b"\xbc\x00packed")
        with self.assertRaisesRegex(ValueError, "neither JSON nor JSON lines"):
            index.build([qa.parent / "packed.bin"], self.root / "index.json")

    def test_benchmark_door_opens_only_for_benchmark_paths(self):
        qa, _ = benchmark_files(self.root)
        self.assertEqual(pathguard.check_benchmark_source(qa), Path(os.path.realpath(qa)))
        plain = self.root / "notes.json"
        plain.write_text(json.dumps({"text": "a plain invented note"}))
        for path in ("/etc/hosts", plain, self.root / "missing.json"):
            with self.subTest(str(path)), self.assertRaisesRegex(pathguard.ForbiddenPathError, "not a benchmark"):
                pathguard.check_benchmark_source(path)
        with self.assertRaisesRegex(pathguard.ForbiddenPathError, "not a benchmark"):
            index.build([plain], self.root / "index.json")
        self.assertFalse((self.root / "index.json").exists())

    def test_benchmark_door_resolves_links_before_deciding(self):
        qa, _ = benchmark_files(self.root)
        sealed = self.root / "meeting-eval" / "sealed.json"
        sealed.parent.mkdir()
        sealed.write_text(json.dumps({"text": "an invented sealed line"}))
        plain = self.root / "notes.json"
        plain.write_text(json.dumps({"text": "a plain invented note"}))
        to_sealed, to_plain = qa.parent / "linked-sealed.json", qa.parent / "linked-plain.json"
        to_sealed.symlink_to(sealed)
        to_plain.symlink_to(plain)
        with self.assertRaisesRegex(pathguard.ForbiddenPathError, "meeting-eval"):
            pathguard.check_benchmark_source(to_sealed)
        # A benchmark-looking name is not enough: the file it resolves to must be a benchmark file.
        with self.assertRaisesRegex(pathguard.ForbiddenPathError, "not a benchmark"):
            pathguard.check_benchmark_source(to_plain)
        # The other direction: an innocent name that resolves into a benchmark folder is still not `check`-able.
        outside = self.root / "innocent.json"
        outside.symlink_to(qa)
        with self.assertRaises(pathguard.ForbiddenPathError):
            pathguard.check(outside)

    def test_benchmark_overlap_is_rejected_and_counted(self):
        root, base = self.root, make_base(self.root)
        index.build(list(benchmark_files(root)), root / "index.json")
        manifest = rows.assemble(base, [lantern_source(root)], root / "out", exclude_indexes=[root / "index.json"])
        # Row 0 matches on its spoken text, row 3 on its label; both differ in case and punctuation.
        counts = manifest["counts"]["lanterns"]
        self.assertEqual(counts["rejected"]["benchmark_overlap"], 2)
        self.assertEqual(counts["train"] + counts["valid"], 4)
        kept = tower_ids(root / "out/train.jsonl") | tower_ids(root / "out/valid-public.jsonl")
        self.assertEqual(kept, {1, 2, 4, 5})
        self.assertEqual(manifest["exclude_indexes"][0]["hashes"], 6)
        with self.assertRaisesRegex(ValueError, "not a contamination index"):
            rows.assemble(base, [], root / "other", exclude_indexes=[root / "cases"])

    def shingle_fixture(self):
        """A benchmark line of twelve invented words, and cases that quote eight of them or fewer."""
        benchmark = self.root / "disfl-qa" / "long.json"
        benchmark.parent.mkdir()
        benchmark.write_text(json.dumps({"q": {"original": "one quiet heron crossed the copper river before the slow winter dawn"}}))
        spoken = ["so anyway a quiet heron crossed the copper river before the storm came",   # eight shared words
                  "so anyway a quiet heron crossed the copper river and then left",          # seven shared words
                  "the brass kettle sings on the low stove every single evening now"]
        cases = [{"id": f"c{i}", "spoken": text, "meeting": f"m{i}"} for i, text in enumerate(spoken)]
        labels = [{"id": f"c{i}", "text": text.capitalize() + "."} for i, text in enumerate(spoken)]
        labels[2]["text"] = "Later the quiet heron crossed the copper river before the slow tide."  # label shares nine
        rows.write_rows(self.root / "cases", cases)
        rows.write_rows(self.root / "labels", labels)
        return benchmark, ("herons", self.root / "cases", self.root / "labels")

    def test_whole_string_index_ignores_shared_shingles_by_default(self):
        benchmark, source = self.shingle_fixture()
        report = index.build([benchmark], self.root / "index.json")
        self.assertEqual((report["hashes"], report["shingles"]), (1, 0))
        manifest = rows.assemble(make_base(self.root), [source], self.root / "out",
                                 exclude_indexes=[self.root / "index.json"])
        self.assertEqual(manifest["counts"]["herons"]["rejected"], {"benchmark_overlap": 0})

    def test_shingle_index_rejects_rows_sharing_eight_words(self):
        benchmark, source = self.shingle_fixture()
        report = index.build([benchmark], self.root / "index.json", shingles=True)
        self.assertEqual((report["hashes"], report["shingles"]), (1, 5))  # twelve words hold five 8-word shingles
        written = json.loads((self.root / "index.json").read_text())
        self.assertEqual((len(written["whole"]), len(written["shingles"]), written["shingle_words"]), (1, 5, 8))
        self.assertFalse(set("".join(written["whole"] + written["shingles"])) - HEX)
        self.assertNotIn("heron", (self.root / "index.json").read_text())
        manifest = rows.assemble(make_base(self.root), [source], self.root / "out",
                                 exclude_indexes=[self.root / "index.json"])
        counts = manifest["counts"]["herons"]
        self.assertEqual(counts["rejected"], {"benchmark_overlap": 0, "benchmark_shingle_overlap": 2})
        self.assertEqual(counts["train"] + counts["valid"], 1)
        self.assertEqual(manifest["exclude_indexes"][0], {"path": str(self.root / "index.json"), "hashes": 1,
                                                          "shingles": 5})

    def test_command_line_builds_a_shingle_index(self):
        benchmark, _ = self.shingle_fixture()
        with contextlib.redirect_stdout(io.StringIO()) as printed:
            rows.main(["benchmark-index", "--out", str(self.root / "index.json"), "--source", str(benchmark),
                       "--shingles"])
        self.assertEqual(json.loads(printed.getvalue())["shingles"], 5)


if __name__ == "__main__":
    unittest.main()
