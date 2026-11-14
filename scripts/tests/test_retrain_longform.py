#!/usr/bin/env python3
"""Offline long-form extraction checks; fixture speech is invented."""

import contextlib
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import retrain_longform as longform  # noqa: E402
from pathguard import ForbiddenPathError  # noqa: E402  (on the path once retrain_longform is imported)

NLP_HEADER = "token|speaker|ts|endTs|punctuation|prepunctuation|case|tags\n"


def write_nlp(path, tokens, speaker="A"):
    path.write_text(NLP_HEADER + "".join(f"{token}|{speaker}||||||[]\n" for token in tokens))


def load(path):
    return [json.loads(line) for line in Path(path).read_text().splitlines()]


class LongformTests(unittest.TestCase):
    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.root = Path(folder.name)

    def test_icsi_uppercase_words_and_class_punctuation(self):
        folder = self.root / "Words"
        folder.mkdir()
        elements = []
        for i in range(120):
            elements.append(f'<w starttime="{i * .2:.1f}" endtime="{i * .2 + .1:.1f}" c="W">birch</w>')
            if i % 20 == 19:
                elements.append(f'<w starttime="{i * .2 + .1:.1f}" endtime="{i * .2 + .1:.1f}" c=".">.</w>')
        (folder / "Bxy003.A.words.xml").write_text("<root>" + "".join(elements) + "</root>")
        rows, report = longform.extract("icsi", self.root)
        self.assertEqual(len(rows), 1)
        self.assertEqual((rows[0]["words"], rows[0]["meeting"], rows[0]["series"]), (120, "Bxy003", "Bxy"))
        self.assertEqual(rows[0]["licence"], "CC BY 4.0")
        self.assertEqual(report["candidates"], 1)

    def test_earnings21_uses_nlp_layout(self):
        with (self.root / "call.nlp").open("w") as handle:
            handle.write("token|speaker|ts|endTs|punctuation|prepunctuation|case|tags\n")
            for _ in range(110):
                handle.write("cedar|A||||||[]\n")
        rows, _ = longform.extract("earnings21", self.root)
        self.assertEqual(len(rows), 1)
        self.assertEqual((rows[0]["source"], rows[0]["series"]), ("earnings21", "call"))

    def test_ami_gaps_entities_punctuation_and_cut(self):
        folder = self.root / "words"
        folder.mkdir()
        tokens = ["wood" + chr(97 + i % 26) + chr(97 + i // 26) for i in range(330)]
        elements = []
        for i, token in enumerate(tokens):
            text = "Birch&amp;amp;Oak" if i == 0 else token
            elements.append(f'<w starttime="{i * 0.2:.1f}" endtime="{i * 0.2 + 0.1:.1f}">{text}</w>')
            if i in (119, 219, 319):
                elements.append(f'<w starttime="{i * 0.2 + 0.1:.1f}" endtime="{i * 0.2 + 0.1:.1f}" punc="true">.</w>')
        elements.append('<w starttime="70" endtime="70.1">stray</w>')
        (folder / "ES9001c.A.words.xml").write_text("<root>" + "".join(elements) + "</root>")
        rows, report = longform.extract("ami", self.root, meeting_cap=8, speaker_cap=8)
        self.assertEqual(sorted(row["words"] for row in rows), [110, 221])
        self.assertTrue(any("birch oak" in row["spoken"] for row in rows))
        self.assertNotIn("stray", " ".join(row["spoken"] for row in rows))
        self.assertEqual(report["candidates"], 2)
        self.assertEqual({row["series"] for row in rows}, {"ES9001"})
        self.assertTrue(all(row["words"] == len(row["spoken"].split()) for row in rows))
        self.assertEqual(set(rows[0]), {"id", "source", "licence", "meeting", "series", "words", "spoken"})

    def test_earnings_speaker_turns_and_fillers(self):
        path = self.root
        with (path / "call.nlp").open("w") as handle:
            handle.write("token|speaker|ts|endTs|punctuation|prepunctuation|case|tags\n")
            for i in range(120):
                handle.write(f"{'Uh' if i == 0 else 'Map' if i == 1 else 'cedar'}|A|||{'.' if i == 119 else ''}|||[]\n")
            handle.write("interrupt|B||||||[]\n")
            for i in range(101):
                handle.write("elm|A||||||[]\n")
        rows, report = longform.extract("earnings22", path, filler_drop=1)
        self.assertEqual(sorted(row["words"] for row in rows), [101, 119])
        self.assertTrue(any(row["spoken"].startswith("map cedar") for row in rows))
        self.assertEqual(report["candidates"], 2)
        capped, _ = longform.extract("earnings22", path, meeting_cap=1)
        self.assertEqual(len(capped), 1)
        self.assertEqual(capped, longform.extract("earnings22", path, meeting_cap=1)[0])

    def test_structural_filters(self):
        make = lambda token: [{"word": token, "sentence": False, "pause": 0} for _ in range(120)]
        short = make("cedar")
        for i in range(6, 120, 7):
            short[i]["sentence"] = True
        self.assertEqual(longform.filter_reason(short, set()), "short_clauses")
        self.assertEqual(longform.filter_reason(make("cedar"), longform.shingles(["cedar"] * 120)),
                         "repeated_across_files")
        self.assertIsNone(longform.filter_reason(make("cedar"), set()))
        marked = make("cedar")
        marked[40]["missing"] = True
        self.assertEqual(longform.filter_reason(marked, set()), "missing_words")

    def test_number_heavy_stretches_are_kept(self):
        self.assertIsNone(longform.filter_reason([{"word": "12", "sentence": False, "pause": 0}] * 120, set()))
        write_nlp(self.root / "call.nlp", ["Revenue", "grew", "2.5%", "to", "$10,000"] * 24)
        rows, report = longform.extract("earnings22", self.root)
        self.assertEqual((len(rows), report["rejected"]), (1, {}))
        self.assertTrue(rows[0]["spoken"].startswith("revenue grew 2.5% to $10,000 revenue"))
        self.assertEqual(rows[0]["words"], 120)

    def test_stretches_with_missing_words_are_rejected_not_cleaned(self):
        clean = ["cedar"] * 60 + ["<laugh>", "bir-"] + ["cedar"] * 60
        for index, marker in enumerate(("<inaudible>", "[inaudible]", "<unk>", "<crosstalk>")):
            write_nlp(self.root / f"call{index}.nlp", ["elm"] * 60 + [marker] + ["elm"] * 60, speaker="B")
        write_nlp(self.root / "kept.nlp", clean)
        rows, report = longform.extract("earnings22", self.root)
        self.assertEqual(report["candidates"], 5)
        self.assertEqual(report["rejected"], {"missing_words": 4})
        self.assertEqual([(row["meeting"], row["words"]) for row in rows], [("kept", 120)])
        self.assertEqual(set(rows[0]["spoken"].split()), {"cedar"})

    def test_split_keeps_meetings_together(self):
        root = self.root
        rows = [{"id": str(i), "source": "ami", "meeting": f"room{i // 2}", "series": f"wing{i // 4}", "words": 120,
                 "spoken": "invented"} for i in range(10)]
        longform.write_lines(root / "all", rows)
        report = longform.split(root / "all", root / "train", root / "held", 7, 0.4)
        train, held = load(root / "train"), load(root / "held")
        self.assertEqual(len(train) + len(held), 10)
        self.assertTrue(train and held)
        self.assertFalse({r["meeting"] for r in train} & {r["meeting"] for r in held})
        self.assertEqual(report["meetings"], 5)
        self.assertEqual(report["held_groups"], {"ami": sorted({r["meeting"] for r in held})})
        self.assertEqual(report, longform.split(root / "all", root / "train2", root / "held2", 7, 0.4))

    def test_split_holds_at_least_one_meeting_and_refuses_a_single_one(self):
        root = self.root
        two = [{"id": str(i), "source": "ami", "meeting": f"room{i % 2}", "words": 120, "spoken": "invented"}
               for i in range(6)]
        longform.write_lines(root / "two", two)
        for seed in range(20):
            report = longform.split(root / "two", root / "train", root / "held", seed, 0.01)
            self.assertEqual((len(load(root / "train")), len(load(root / "held"))), (3, 3))
            self.assertEqual(len(report["held_groups"]["ami"]), 1)
        longform.write_lines(root / "one", [row for row in two if row["meeting"] == "room0"])
        with self.assertRaisesRegex(ValueError, "only one meeting"):
            longform.split(root / "one", root / "train3", root / "held3", 7, 0.2)
        self.assertFalse((root / "train3").exists() or (root / "held3").exists())

    def test_split_can_hold_out_whole_series(self):
        root = self.root
        rows = [{"id": str(i), "source": "ami", "meeting": f"ES90{i // 2:02d}{'ab'[i % 2]}", "series": f"ES90{i // 2:02d}",
                 "words": 120, "spoken": "invented"} for i in range(12)]
        longform.write_lines(root / "all", rows)
        report = longform.split(root / "all", root / "train", root / "held", 3, 0.3, group_key="series")
        train, held = load(root / "train"), load(root / "held")
        self.assertTrue(train and held)
        self.assertFalse({r["series"] for r in train} & {r["series"] for r in held})
        self.assertEqual(report["held_groups"]["ami"], sorted({r["series"] for r in held}))
        longform.write_lines(root / "old", [{k: v for k, v in row.items() if k != "series"} for row in rows])
        with self.assertRaisesRegex(ValueError, "no 'series'"):
            longform.split(root / "old", root / "train4", root / "held4", 3, 0.3, group_key="series")


class LongformGuardTests(unittest.TestCase):
    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.root = Path(folder.name)
        self.calls = self.root / "calls"
        self.calls.mkdir()
        write_nlp(self.calls / "call.nlp", ["cedar"] * 120)

    def run_main(self, *arguments):
        with contextlib.redirect_stderr(io.StringIO()) as printed:
            longform.main([str(argument) for argument in arguments])
        return json.loads(printed.getvalue())

    def test_command_line_extracts_and_splits(self):
        write_nlp(self.calls / "other.nlp", ["elm"] * 120)
        report = self.run_main("stretches", "--source", "earnings22", "--input", self.calls, "--out", self.root / "all")
        self.assertEqual(report["candidates"], 2)
        report = self.run_main("split", "--input", self.root / "all", "--train", self.root / "train",
                               "--held-back", self.root / "held", "--group-key", "series")
        self.assertEqual((report["meetings"], len(load(self.root / "train")), len(load(self.root / "held"))), (2, 1, 1))

    def test_sealed_looking_input_folder_is_refused(self):
        sealed = self.root / "meeting-eval"
        sealed.mkdir()
        write_nlp(sealed / "call.nlp", ["cedar"] * 120)
        with self.assertRaises(ForbiddenPathError):
            longform.extract("earnings22", sealed)
        with self.assertRaises(SystemExit) as stopped:
            self.run_main("stretches", "--source", "earnings22", "--input", sealed, "--out", self.root / "all")
        self.assertRegex(str(stopped.exception), "^error: refusing .*meeting-eval")
        self.assertFalse((self.root / "all").exists())

    def test_file_that_resolves_to_a_sealed_path_is_refused(self):
        sealed = self.root / "data" / "external"
        sealed.mkdir(parents=True)
        write_nlp(sealed / "sealed.nlp", ["elm"] * 120)
        (self.calls / "linked.nlp").symlink_to(sealed / "sealed.nlp")
        with self.assertRaisesRegex(ForbiddenPathError, "data/external"):
            longform.extract("earnings22", self.calls)
        words = self.root / "words"
        words.mkdir()
        (words / "Room1a.A.words.xml").symlink_to(sealed / "sealed.nlp")
        with self.assertRaisesRegex(ForbiddenPathError, "data/external"):
            longform.extract("ami", self.root)

    def test_sealed_looking_outputs_are_refused_before_anything_is_written(self):
        sealed = self.root / "disfl-qa"
        sealed.mkdir()
        with self.assertRaises(SystemExit) as stopped:
            self.run_main("stretches", "--source", "earnings22", "--input", self.calls, "--out", sealed / "all")
        self.assertRegex(str(stopped.exception), "^error: refusing .*disfl-qa")
        longform.write_lines(self.root / "all", [{"id": str(i), "source": "ami", "meeting": f"room{i}", "words": 120,
                                                  "spoken": "invented"} for i in range(4)])
        for train, held in ((sealed / "train", self.root / "held"), (self.root / "train", sealed / "held")):
            with self.subTest(str(train)), self.assertRaises(SystemExit) as stopped:
                self.run_main("split", "--input", self.root / "all", "--train", train, "--held-back", held)
            self.assertRegex(str(stopped.exception), "^error: refusing .*disfl-qa")
        self.assertEqual(sorted(path.name for path in self.root.iterdir()), ["all", "calls", "disfl-qa"])
        self.assertEqual(list(sealed.iterdir()), [])
        (sealed / "rows").write_text("")
        with self.assertRaises(SystemExit):
            self.run_main("split", "--input", sealed / "rows", "--train", self.root / "train", "--held-back",
                          self.root / "held")

    def test_bad_arguments_are_clear_errors(self):
        longform.write_lines(self.root / "one", [{"id": "0", "source": "ami", "meeting": "room", "words": 120,
                                                  "spoken": "invented"}])
        with self.assertRaises(SystemExit) as stopped:
            self.run_main("split", "--input", self.root / "one", "--train", self.root / "t", "--held-back", self.root / "h")
        self.assertRegex(str(stopped.exception), "^error: .*only one meeting")
        with self.assertRaises(SystemExit) as stopped:
            self.run_main("split", "--input", self.root / "absent", "--train", self.root / "t", "--held-back",
                          self.root / "h")
        self.assertRegex(str(stopped.exception), "^error: .*absent")


if __name__ == "__main__":
    unittest.main()
