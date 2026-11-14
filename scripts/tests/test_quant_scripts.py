"""Offline checks for quant metadata, training data guard and app-path report."""
import json
from pathlib import Path
import sys
import tempfile
import unittest

QUANT = Path(__file__).resolve().parents[1] / "quant"
sys.path.insert(0, str(QUANT))
import prepare  # noqa: E402
import score_table  # noqa: E402


class QuantScripts(unittest.TestCase):
    def test_training_guard_accepts_train_and_rejects_public(self):
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / "round7"
            source.mkdir()
            (source / "train.jsonl").write_text('{"messages": [{"role":"user","content":"invented"}]}\n')
            prepare.check_training(source)
            public = Path(tmp) / "public-inputs"
            public.mkdir()
            (public / "train.jsonl").write_text((source / "train.jsonl").read_text())
            with self.assertRaises(ValueError):
                prepare.check_training(public)

    def test_finish_writes_hash_and_metadata(self):
        with tempfile.TemporaryDirectory() as tmp:
            src, dst = Path(tmp) / "src", Path(tmp) / "q4"
            src.mkdir(); dst.mkdir()
            (src / "chat_template.jinja").write_text("template")
            (dst / "model.safetensors").write_bytes(b"invented weights")
            prepare.finish(src, dst, "q4", 4, ["mlx_lm", "convert", "a b"])
            record = json.loads((dst / "variant.json").read_text())
            self.assertEqual(record["bits_per_weight"], 4)
            self.assertEqual(record["command"], "mlx_lm convert 'a b'")
            self.assertIn("model.safetensors", (dst / "SHA256SUMS").read_text())

    def test_table_uses_public_normalized_exact_and_paired_text(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); (root / "scores").mkdir()
            cases = root / "pub.jsonl"
            cases.write_text(json.dumps({"id": "x", "spoken": "twenty", "reference": "20"}) + "\n")
            for name, answer in (("q4", "twenty"), ("q6", "wrong")):
                out = root / "scores" / f"{name}-pub.jsonl"
                out.write_text(json.dumps({"id": "x", "text": answer, "usedModel": True,
                                           "firstTokenMs": 10, "totalMs": 20}) + "\n")
                out.with_suffix(".log").write_text(" 104857600 maximum resident set size\n")
            table = score_table.table(root, cases)
            self.assertIn("| q4 | pub | 1/1 | 1 | 0 | 10/10 | 20/20 | 100 |", table)
            self.assertIn("| q6 | pub | 0/1 | 1 | 1 | 10/10 | 20/20 | 100 |", table)


if __name__ == "__main__":
    unittest.main()
