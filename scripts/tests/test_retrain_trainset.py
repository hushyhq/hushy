import hashlib
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
import retrain_groups
import retrain_trainset


class TrainsetTests(unittest.TestCase):
    def setUp(self):
        (ROOT / "Evals/runs/retrain").mkdir(parents=True, exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=ROOT / "Evals/runs/retrain")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.system = retrain_groups.prompt_sections(ROOT / "Evals/finetune-prompts/group-call-system.txt")

    def batch(self, name, count=15, system=None):
        folder = self.root / name
        folder.mkdir()
        sources, rows = [], []
        for i in range(count):
            ident = f"{name}-{i}"
            sources.append({"id": ident, "family": "email" if i % 2 else "agent", "band": [40, 120]})
            for g in range(2):
                rows.append({"id": f"{ident}-g{g}", "passage": ident, "arm": "group",
                             "messages": [{"role": "system", "content": system or self.system},
                                          {"role": "user", "content": f"Left context: none\nTranscript: draft {ident} {g}\nOutput:"},
                                          {"role": "assistant", "content": json.dumps({"text": ident, "new_paragraph": bool(g)})}]})
        (folder / "sources.jsonl").write_text("".join(json.dumps(s) + "\n" for s in sources))
        (folder / "batch.group_rows.jsonl").write_text("".join(json.dumps(r) + "\n" for r in rows))
        return folder

    def test_runs_isolated_as_the_runbook_does(self):
        # The runbook calls the script with -I, which leaves the script's folder off the path.
        done = subprocess.run([sys.executable, "-I", str(ROOT / "scripts/retrain_trainset.py"), "--help"],
                              capture_output=True, text=True)
        self.assertEqual(done.returncode, 0, done.stderr)

    def test_split_manifest_and_hashes(self):
        batch = self.batch("one", 25)
        # Exact repeated conversation from another passage must be removed.
        rows_path = batch / "batch.group_rows.jsonl"
        rows = rows_path.read_text().splitlines()
        rows.append(rows[0])
        rows_path.write_text("\n".join(rows) + "\n")
        out = self.root / "output"
        retrain_trainset.build([batch], out, seed=9)
        train = [json.loads(x) for x in (out / "mlx/train.jsonl").read_text().splitlines()]
        valid = [json.loads(x) for x in (out / "mlx/valid.jsonl").read_text().splitlines()]
        self.assertFalse({r["passage"] for r in train} & {r["passage"] for r in valid})
        self.assertEqual(len(train) + len(valid), 50)
        self.assertTrue(valid)
        manifest = json.loads((out / "manifest.json").read_text())
        self.assertEqual(manifest["rows"]["total"], 50)
        self.assertEqual(sum(manifest["valid"]["passages"]["family"].values()), manifest["valid"]["passages"]["total"])
        self.assertEqual(manifest["rows"]["new_paragraph"], {"false": 25, "true": 25})
        self.assertEqual(manifest["empty_left_context_share"], 1)
        self.assertEqual(manifest["heldoutProof"]["forbiddenPathsTouched"], 0)
        self.assertEqual(manifest["files"]["mlx/train.jsonl"], hashlib.sha256((out / "mlx/train.jsonl").read_bytes()).hexdigest())
        export = json.loads((out / "export.json").read_text())
        self.assertEqual(export["promptVersion"], "group-call-v4.1-draft")
        self.assertEqual(export["answerSchema"]["required"], ["text", "new_paragraph"])

    def test_wrong_system_and_outside_output_refused(self):
        batch = self.batch("bad", system="different")
        with self.assertRaises(ValueError):
            retrain_trainset.build([batch], self.root / "bad-output")
        batch = self.batch("good")
        with self.assertRaises(ValueError):
            retrain_trainset.build([batch], ROOT / ".build/trainset-test")

    def test_replay_retemplate_and_skip_multiline(self):
        batch = self.batch("one", 20)
        replay = self.root / "replay.jsonl"
        # Row 0 has a line break in its answer, row 1 in its transcript, rows 2-4 are the Clean level.
        old = [{"id": f"old-{i}", "messages": [
                {"role": "system", "content": f"old. Level: {'Clean' if 2 <= i <= 4 else 'Polished'}."},
                {"role": "user", "content": f"Transcript: old draft {i}{chr(10) + '- item' if i == 1 else ''}\nOutput:"},
                {"role": "assistant", "content": json.dumps({"text": "line\nbreak" if i == 0 else f"clean {i}"})}]}
               for i in range(30)]
        replay.write_text("".join(json.dumps(r) + "\n" for r in old))
        out = self.root / "output"
        retrain_trainset.build([batch], out, seed=4, replay=replay, replay_share=0.3)
        rows = [json.loads(x) for part in ("train", "valid") for x in (out / f"mlx/{part}.jsonl").read_text().splitlines()]
        replay_rows = [r for r in rows if r.get("source") == "legacy_replay"]
        self.assertTrue(replay_rows)
        self.assertEqual(len(replay_rows), json.loads((out / "manifest.json").read_text())["replay"]["included"])
        self.assertTrue(json.loads((out / "manifest.json").read_text())["replay"]["label_policy"].startswith("older"))
        manifest = json.loads((out / "manifest.json").read_text())["replay"]
        self.assertEqual(manifest["skipped"], {"multiline": 2, "other_level": 3})
        self.assertEqual(manifest["level"], "Polished")
        self.assertFalse({r["id"] for r in replay_rows} & {f"old-{i}" for i in range(5)})
        for row in replay_rows:
            self.assertEqual(row["messages"][0]["content"], self.system)
            self.assertTrue(row["messages"][1]["content"].startswith("Left context: none\nTranscript: "))
            self.assertFalse(json.loads(row["messages"][2]["content"])["new_paragraph"])


if __name__ == "__main__":
    unittest.main()
