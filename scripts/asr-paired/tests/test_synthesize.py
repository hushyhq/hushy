import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import importlib.util
import sys

SCRIPT = Path(__file__).resolve().parents[1] / "synthesize.py"
spec = importlib.util.spec_from_file_location("asr_paired_synthesize", SCRIPT)
synthesize = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(synthesize)
sys.path.insert(0, str(SCRIPT.parents[1]))
from sealed_guard import SealedEvalRefusal


class SynthesizeKitTests(unittest.TestCase):
    def test_dry_run_is_side_effect_free_and_does_not_call_say(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = root / "cases.json"
            source.write_text(json.dumps({"schema_version": 1, "clips": [
                {"id": "one", "spoken_text": "Open Chrome", "reference": "Open Chrome"},
                {"id": "quiet", "reference": "", "category": "silence"},
            ]}))
            with patch.object(synthesize.subprocess, "run") as run:
                result = synthesize.render(source, root / "out", dry_run=True)
            run.assert_not_called()
            self.assertEqual(result, (root / "out" / "cases-with-audio.json").resolve())
            self.assertFalse((root / "out").exists())

    def test_silence_writer_creates_pcm16_mono_at_16khz(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "silence.wav"
            synthesize.silence(path, seconds=0.25)
            import wave
            with wave.open(str(path), "rb") as wav:
                self.assertEqual((wav.getnchannels(), wav.getsampwidth(), wav.getframerate()), (1, 2, 16000))
                self.assertEqual(wav.getnframes(), 4000)
                self.assertEqual(set(wav.readframes(wav.getnframes())), {0})

    def test_rejects_wrong_schema(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = root / "cases.json"
            source.write_text('{"schema_version":2,"clips":[]}')
            with self.assertRaisesRegex(ValueError, "schema_version 1"):
                synthesize.render(source, root / "out", dry_run=True)

    def test_refuses_sealed_input_before_parsing(self):
        with tempfile.TemporaryDirectory() as temp:
            source = Path(temp) / "actions-heldout.json"
            source.write_text("not even json")
            with self.assertRaises(SealedEvalRefusal):
                synthesize.render(source, Path(temp) / "out", dry_run=True)


if __name__ == "__main__":
    unittest.main()
