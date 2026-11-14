#!/usr/bin/env python3
"""Invented fixtures for public retrain assembly."""

import contextlib
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
from retrain_public_fixtures import benchmark_files, lantern_source, make_base, read_jsonl, tower_ids  # noqa: E402
import retrain_public_rows as rows  # noqa: E402
import retrain_public_screen as screening  # noqa: E402
import retrain_holdout as groups  # noqa: E402
import pathguard  # noqa: E402  (on the path once retrain_public_rows is imported)


class PublicRowsTests(unittest.TestCase):
    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.root = Path(folder.name)

    def test_mixed_filters_and_keeps_meetings_apart(self):
        root, base = self.root, make_base(self.root)
        source = lantern_source(root)
        extra = [{"id": name, "spoken": "a small copper tower", "meeting": "meeting0"}
                 for name in ("empty", "same", "long", "unlabelled")]
        labels = [{"id": "empty", "text": ""}, {"id": "same", "text": "a small copper tower"},
                  {"id": "long", "text": "a small copper tower rises near a second very tall copper tower"},
                  {"id": "stray", "text": "A label that belongs to no case."}]
        rows.write_rows(root / "cases", read_jsonl(root / "cases") + extra)
        rows.write_rows(root / "labels", read_jsonl(root / "labels") + labels)
        manifest = rows.assemble(base, [source], root / "out", valid_mode="mixed")
        counts = manifest["counts"]["lanterns"]
        self.assertEqual(counts["rejected"], {"empty": 1, "identical": 1, "missing_label": 1, "word_ratio": 1})
        # Stray labels are counted beside the cases, so the per-case numbers add up to the input.
        self.assertEqual(counts["unmatched_labels"], 1)
        self.assertEqual(counts["input"], counts["train"] + counts["valid"] + sum(counts["rejected"].values()))
        self.assertEqual(manifest["train"] + manifest["valid"], 8)
        self.assertEqual(manifest["sources"][1]["licence"], ["CC BY 4.0"])
        self.assertEqual(manifest["validation"]["mode"], "mixed")
        self.assertFalse((root / "out/valid-public.jsonl").exists())
        train_ids, valid_ids = tower_ids(root / "out/train.jsonl"), tower_ids(root / "out/valid.jsonl")
        self.assertEqual(train_ids | valid_ids, set(range(6)))
        self.assertFalse({i // 2 for i in train_ids} & {i // 2 for i in valid_ids})
        self.assertEqual({f"meeting{i // 2}" for i in valid_ids}, set(manifest["held_groups"]["lanterns"]))
        self.assertEqual(len(read_jsonl(root / "out/valid.jsonl")), 1 + len(valid_ids))

    def test_rejects_duplicate_ids(self):
        root, base = self.root, make_base(self.root)
        rows.write_rows(root / "cases", [{"id": "a", "spoken": "birch oak", "meeting": "m"}] * 2)
        rows.write_rows(root / "labels", [{"id": "a", "text": "Birch oak."}])
        with self.assertRaisesRegex(ValueError, "duplicate case id"):
            rows.assemble(base, [("x", root / "cases", root / "labels")], root / "out")

    def test_manifest_carries_and_counts_the_held_out_proof(self):
        root, base = self.root, make_base(self.root)
        rows.assemble(base, [lantern_source(root)], root / "out")
        manifest = json.loads((root / "out/manifest.json").read_text())
        proof = manifest["heldoutProof"]
        self.assertEqual(proof["forbiddenPathsTouched"], 0)
        # Read: base manifest, train, valid, cases, labels. Written: train, valid, valid-public.
        self.assertEqual((len(manifest["reads"]), len(manifest["writes"])), (5, 3))
        self.assertEqual((proof["thisRun"], proof["base"]["pathsChecked"], proof["pathsChecked"]), (8, 7, 15))
        self.assertEqual(manifest["sources"][0]["licence"], "own invented rows")
        # An assembled folder carries its proof beside the rows, so it can be the next base.
        again = rows.assemble(root / "out", [], root / "again")
        self.assertEqual(again["heldoutProof"]["pathsChecked"], 15 + again["heldoutProof"]["thisRun"])

    def test_base_without_a_clean_proof_fails(self):
        for label, proof in (("absent", None), ("touched", {"pathsChecked": 7, "forbiddenPathsTouched": 1}),
                             ("uncounted", {"forbiddenPathsTouched": 0}), ("empty", {})):
            with self.subTest(label), tempfile.TemporaryDirectory() as name:
                root = Path(name)
                base = make_base(root, proof)
                with self.assertRaisesRegex(ValueError, "held-out proof"):
                    rows.assemble(base, [lantern_source(root)], root / "out")
                self.assertFalse((root / "out/manifest.json").exists())

    def test_valid_defaults_to_the_base_rows_only(self):
        root, base = self.root, make_base(self.root)
        manifest = rows.assemble(base, [lantern_source(root)], root / "out")
        self.assertEqual((root / "out/valid.jsonl").read_bytes(), (base / "valid.jsonl").read_bytes())
        self.assertEqual(manifest["writes"]["valid.jsonl"], pathguard.sha256_file(base / "valid.jsonl"))
        public_ids, train_ids = tower_ids(root / "out/valid-public.jsonl"), tower_ids(root / "out/train.jsonl")
        held = manifest["held_groups"]["lanterns"]
        self.assertEqual((len(public_ids), len(train_ids)), (2 * len(held), 6 - 2 * len(held)))
        self.assertFalse({i // 2 for i in train_ids} & {i // 2 for i in public_ids})
        self.assertEqual((manifest["train"], manifest["valid"]), (1 + len(train_ids), 1))
        self.assertEqual(manifest["validation"], {"mode": "base", "base_rows": 1, "public_rows": len(public_ids),
                                                  "note": rows.VALID_NOTES["base"]})
        self.assertEqual((manifest["whole_only"], manifest["whole_only_dropped"]), (False, {"train": 0, "valid": 0}))
        self.assertIn("valid-public.jsonl", manifest["writes"])

    def grouped_base(self):
        """A base that mixes one whole-transcript row with grouped rows, in train and in valid."""
        grouped = {"messages": [{"role": "system", "content": "Invented grouping rule"},
                                {"role": "user", "content": "Groups: the blue lantern"},
                                {"role": "assistant", "content": "{}"}]}
        return make_base(self.root, extra_train=[grouped, grouped], extra_valid=[grouped])

    def test_whole_only_filters_the_valid_file_too(self):
        root, base = self.root, self.grouped_base()
        manifest = rows.assemble(base, [lantern_source(root)], root / "out", whole_only=True)
        valid = read_jsonl(root / "out/valid.jsonl")
        self.assertEqual(len(valid), 1)
        self.assertTrue(all(row["messages"][1]["content"].startswith("Transcript:") for row in valid))
        self.assertTrue(all(row["messages"][1]["content"].startswith("Transcript:")
                            for row in read_jsonl(root / "out/train.jsonl")))
        self.assertEqual((manifest["whole_only"], manifest["whole_only_dropped"]), (True, {"train": 2, "valid": 1}))
        base_counts = manifest["counts"]["p1"]
        self.assertEqual((base_counts["input"], base_counts["train"], base_counts["valid"]), (5, 1, 1))
        self.assertEqual(base_counts["rejected"], {"not_whole_transcript": 3})
        self.assertEqual(manifest["validation"]["note"], rows.VALID_NOTES["base_whole_only"])
        self.assertEqual((manifest["validation"]["base_rows"], manifest["valid"]), (1, 1))

    def test_without_whole_only_a_mixed_base_is_copied_whole(self):
        root, base = self.root, self.grouped_base()
        manifest = rows.assemble(base, [lantern_source(root)], root / "out")
        self.assertEqual((root / "out/valid.jsonl").read_bytes(), (base / "valid.jsonl").read_bytes())
        self.assertEqual((manifest["counts"]["p1"]["input"], manifest["valid"]), (5, 2))

    def test_base_without_whole_transcript_rows_is_a_clear_error(self):
        base = self.root / "set" / "mlx"
        base.mkdir(parents=True)
        grouped = {"messages": [{"role": "system", "content": "Invented grouping rule"},
                                {"role": "user", "content": "Groups: the blue lantern"},
                                {"role": "assistant", "content": "{}"}]}
        for name in ("train.jsonl", "valid.jsonl"):
            rows.write_rows(base / name, [grouped])
        (self.root / "set" / "manifest.json").write_text(json.dumps({"heldoutProof": {"pathsChecked": 7,
                                                                                    "forbiddenPathsTouched": 0}}))
        for whole_only in (False, True):
            with self.subTest(whole_only), self.assertRaisesRegex(ValueError, "no whole-transcript rows"):
                rows.assemble(base, [], self.root / "out", whole_only=whole_only)

    def test_whole_only_that_empties_the_valid_file_is_refused(self):
        grouped = {"messages": [{"role": "system", "content": "Invented grouping rule"},
                                {"role": "user", "content": "Groups: the blue lantern"},
                                {"role": "assistant", "content": "{}"}]}
        base = make_base(self.root)
        rows.write_rows(base / "valid.jsonl", [grouped])
        with self.assertRaisesRegex(ValueError, "no validation rows"):
            rows.assemble(base, [], self.root / "out", whole_only=True)

    def test_held_groups_do_not_move_when_rows_are_filtered(self):
        root, base = self.root, make_base(self.root)
        source = lantern_source(root, meetings=12)
        first = rows.assemble(base, [source], root / "first")
        held = first["held_groups"]["lanterns"]
        self.assertTrue(0 < len(held) < 12)
        self.assertEqual(held, sorted(held))
        # Drop the labels of four rows and spoil two more: the held set must stay where it was.
        labels = [label for label in read_jsonl(root / "labels") if label["id"] not in {"id0", "id5", "id9", "id14"}]
        labels[0]["text"], labels[3]["text"] = "", ""
        rows.write_rows(root / "labels", labels)
        second = rows.assemble(base, [source], root / "second")
        self.assertEqual(second["held_groups"]["lanterns"], held)
        self.assertEqual({f"meeting{i // 2}" for i in tower_ids(root / "second/valid-public.jsonl")} - set(held), set())
        self.assertFalse({f"meeting{i // 2}" for i in tower_ids(root / "second/train.jsonl")} & set(held))
        self.assertEqual(json.loads((root / "second/manifest.json").read_text())["held_groups"]["lanterns"], held)

    def test_held_group_choice_is_a_stable_hash(self):
        names = [f"room{i}" for i in range(40)]
        held = groups.held_groups(names, 11, "lanterns", .2)
        self.assertEqual(held, groups.held_groups(list(reversed(names)), 11, "lanterns", .2))
        # A group's fate depends only on (seed, source, group): removing other groups never moves it.
        self.assertEqual(groups.held_groups(names[:20], 11, "lanterns", .2), held & set(names[:20]))
        self.assertNotEqual(held, groups.held_groups(names, 12, "lanterns", .2))
        self.assertNotEqual(held, groups.held_groups(names, 11, "other", .2))
        for seed in range(25):
            self.assertEqual(len(groups.held_groups(["a", "b"], seed, "x", .2)), 1)
            self.assertEqual(len(groups.held_groups(["a", "b"], seed, "x", .99)), 1)
            self.assertEqual(groups.held_groups(["a"], seed, "x", .5), set())

    def test_group_key_is_required_and_can_be_named(self):
        root, base = self.root, make_base(self.root)
        source = lantern_source(root)
        by_series = rows.assemble(base, [source], root / "series", group_key="series")
        self.assertEqual((by_series["group_key"], len(by_series["held_groups"]["lanterns"])), ("series", 1))
        self.assertTrue(set(by_series["held_groups"]["lanterns"]) <= {"series0", "series1"})
        by_row = rows.assemble(base, [source], root / "rows", group_key="id")
        self.assertTrue(set(by_row["held_groups"]["lanterns"]) <= {f"id{i}" for i in range(6)})
        for label, change in (("absent", lambda case: case.pop("meeting")),
                              ("empty", lambda case: case.update(meeting="")),
                              ("blank", lambda case: case.update(meeting="  "))):
            cases = read_jsonl(root / "cases")
            change(cases[2])
            rows.write_rows(root / "cases", cases)
            with self.subTest(label), self.assertRaisesRegex(ValueError, "id2.*--group-key"):
                rows.assemble(base, [source], root / f"out-{label}")
        rows.write_rows(root / "cases", [{"id": "only", "spoken": "birch oak elm"}])
        rows.write_rows(root / "labels", [{"id": "only", "text": "Birch, oak, elm."}])
        single = rows.assemble(base, [source], root / "single")  # one row needs no group
        self.assertEqual((single["held_groups"]["lanterns"], single["counts"]["lanterns"]["train"]), ([], 1))

    def test_word_count_keeps_numbers_and_hyphenated_words_whole(self):
        self.assertEqual(screening.word_count("It grew 2.5 percent to 10,000 well-known units, didn't it?"), 10)
        self.assertEqual(screening.word_count("a,b. c"), 3)
        self.assertEqual(screening.word_count("1,250,000.75"), 1)

    def test_word_ratio_is_wider_for_long_inputs(self):
        spoken = lambda count: " ".join(["lantern"] * count)
        label = lambda count: " ".join(["tower"] * count)
        for words, labelled, expected in ((10, 5, None), (10, 4, "word_ratio"), (10, 16, None), (10, 17, "word_ratio"),
                                          (99, 49, "word_ratio"), (100, 30, None), (100, 29, "word_ratio"),
                                          (100, 200, None), (100, 201, "word_ratio"), (240, 80, None)):
            with self.subTest(words=words, labelled=labelled):
                self.assertEqual(screening.label_reason(spoken(words), label(labelled)), expected)
        self.assertEqual(screening.label_reason("", "Tower."), "word_ratio")

    def test_malformed_rows_stop_with_a_clear_message(self):
        root, base = self.root, make_base(self.root)
        name, cases, labels = lantern_source(root)
        good_cases, good_labels = read_jsonl(cases), read_jsonl(labels)
        broken = (("spoken", [{"id": "a", "meeting": "m"}], good_labels),
                  ("spoken", [{"id": "a", "meeting": "m", "spoken": 7}], good_labels),
                  ("id", [{"spoken": "birch oak", "meeting": "m"}], good_labels),
                  ("JSON object", ["birch oak"], good_labels),
                  ("text", good_cases, [{"id": "id0"}]),
                  ("id", good_cases, [{"text": "Birch oak."}]))
        for index, (wanted, case_rows, label_rows) in enumerate(broken):
            rows.write_rows(cases, case_rows)
            rows.write_rows(labels, label_rows)
            with self.subTest(index), self.assertRaises(SystemExit) as stopped:
                rows.main(["assemble", "--base", str(base), "--add", f"{name}={cases},{labels}",
                           "--out", str(root / f"out{index}")])
            message = str(stopped.exception)
            self.assertTrue(message.startswith("error: lanterns"), message)
            self.assertIn(wanted, message)
        rows.write_rows(base / "train.jsonl", [{"messages": [{"role": "system", "content": "rule"}]}])
        with self.assertRaises(SystemExit) as stopped:
            rows.main(["assemble", "--base", str(base), "--out", str(root / "bad-base")])
        self.assertRegex(str(stopped.exception), "^error: .*train.jsonl.*row 1.*chat row")

    def test_out_must_be_a_folder(self):
        root, base = self.root, make_base(self.root)
        (root / "taken").write_text("an invented note")
        with self.assertRaises(SystemExit) as stopped:
            rows.main(["assemble", "--base", str(base), "--out", str(root / "taken")])
        self.assertRegex(str(stopped.exception), "^error: .*taken.*not a folder")
        self.assertEqual((root / "taken").read_text(), "an invented note")
        with self.assertRaises(SystemExit) as stopped:
            rows.main(["assemble", "--base", str(base), "--add", f"x={root / 'nowhere'},{root / 'nowhere'}",
                       "--out", str(root / "fresh")])
        self.assertRegex(str(stopped.exception), "^error: .*nowhere")

    def test_command_line_runs_both_commands(self):
        root, base = self.root, make_base(self.root)
        qa, speech = benchmark_files(root)
        name, cases, labels = lantern_source(root)
        with contextlib.redirect_stdout(io.StringIO()) as printed:
            rows.main(["benchmark-index", "--out", str(root / "index.json"),
                       "--source", str(qa), "--source", str(speech)])
            rows.main(["assemble", "--base", str(base), "--add", f"{name}={cases},{labels}", "--out", str(root / "out"),
                       "--exclude-index", str(root / "index.json"), "--valid", "mixed", "--group-key", "series"])
        index_report, manifest = (json.loads(line) for line in printed.getvalue().splitlines())
        self.assertEqual(index_report["hashes"], 6)
        self.assertEqual((manifest["validation"]["mode"], manifest["group_key"]), ("mixed", "series"))
        self.assertEqual(manifest["valid"], 1 + manifest["counts"]["lanterns"]["valid"])
        with self.assertRaises(SystemExit) as stopped:
            rows.main(["assemble", "--base", str(root / "nowhere"), "--out", str(root / "none")])
        self.assertIn("held-out proof", str(stopped.exception))


if __name__ == "__main__":
    unittest.main()
