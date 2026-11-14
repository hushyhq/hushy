import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "training"))
import chat_rows


def line(meeting, spoken="um so we ship friday", typed="We ship Friday."):
    return json.dumps({"id": meeting, "spoken": spoken, "typed": typed, "meta": {"meeting": meeting}}) + "\n"


class ChatRowsTests(unittest.TestCase):
    def test_row_has_the_app_prompt_and_a_json_answer(self):
        row = chat_rows.chat_row(chat_rows.app_prompt(), "a b", 'say "hi"')
        roles = [m["role"] for m in row["messages"]]
        self.assertEqual(roles, ["system", "user", "assistant"])
        self.assertEqual(row["messages"][1]["content"], "Transcript: a b\nOutput:")
        self.assertEqual(json.loads(row["messages"][2]["content"]), {"text": 'say "hi"'})

    def test_whole_meetings_stay_on_one_side(self):
        lines = [line(f"m{i % 5}", spoken=f"row {i}") for i in range(20)]
        rows = chat_rows.convert(lines, "S")
        train, valid = chat_rows.split(rows, 0.2, seed=1)
        self.assertEqual(len(train) + len(valid), 20)
        held = {g for g, r in rows if r in valid}
        kept = {g for g, r in rows if r in train}
        self.assertTrue(held and kept and not held & kept)

    def test_one_group_cannot_be_split(self):
        with self.assertRaises(ValueError):
            chat_rows.split(chat_rows.convert([line("m1"), line("m1")], "S"), 0.1, seed=1)

    def test_row_missing_text_names_its_line(self):
        with self.assertRaisesRegex(ValueError, "line 2"):
            chat_rows.convert([line("m1"), json.dumps({"spoken": "x"}) + "\n"], "S")

    def test_prompt_file_has_the_marker_and_the_app_prompt(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "prompt.txt"
            chat_rows.main(["--write-prompt-file", str(target)])
            text = target.read_text()
        self.assertTrue(text.startswith("--- system turn ---\n"))
        self.assertIn(chat_rows.app_prompt(), text)

    def test_command_line_writes_both_files(self):
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / "in.jsonl"
            source.write_text("".join(line(f"m{i % 4}") for i in range(8)))
            subprocess.run([sys.executable, "-I", str(ROOT / "training/chat_rows.py"), str(source), tmp + "/out"], check=True,
                           capture_output=True)
            for name in ("train.jsonl", "valid.jsonl"):
                self.assertTrue((Path(tmp) / "out" / name).read_text().strip())


if __name__ == "__main__":
    unittest.main()
