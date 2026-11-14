"""Unit tests for the voice-actions data builder (scripts/finetune/tools). Stdlib only:

    python3 -m unittest discover -s scripts/finetune/tests
"""

from __future__ import annotations

import json
import random
import re
import sys
import tempfile
import unittest
from pathlib import Path

TOOLS = Path(__file__).resolve().parents[1] / "tools"
sys.path.insert(0, str(TOOLS))
sys.path.insert(0, str(TOOLS.parent))
sys.path.insert(0, str(TOOLS.parents[1]))

import asr  # noqa: E402
import gaps_v2  # noqa: E402
import build_tools_data as builder  # noqa: E402
import positives  # noqa: E402
import refusals  # noqa: E402
import tool_llm  # noqa: E402
from pathguard import ForbiddenPathError, Manifest  # noqa: E402
from positives import Content, Slot  # noqa: E402
from sealed_guard import SealedEvalRefusal  # noqa: E402

ROOT = TOOLS.parents[2]


def words(text: str) -> set[str]:
    return set(re.findall(r"[a-z0-9']+", text.lower()))


class LabelsAreTheSpeakersWords(unittest.TestCase):
    def test_every_positive_label_word_is_in_the_utterance(self) -> None:
        rng = random.Random(3)
        content = Content({}, rng)
        for tool, generate in positives.GENERATORS.items():
            for _ in range(150):
                ctx = builder.context(rng)
                draft = generate(rng, content, ctx)
                shaped, _ = asr.shape(draft.segments, rng)
                row = builder.row(positives.Draft(shaped, draft.tool, draft.args, draft.tags), ctx, "pos", "template", "x", [])
                spoken = words(row["utterance"])
                for key, value in row["call"]["args"].items():
                    if key in ("channel", "tracker", "duration_minutes"):
                        continue
                    for item in value if isinstance(value, list) else [value]:
                        self.assertTrue(words(item) <= spoken, f"{tool}.{key}={item!r} not in {row['utterance']!r}")
                self.assertEqual(row["utterance"], row["utterance"].lower())
                self.assertIsNone(re.search(r"[.,?!;:\"]", row["utterance"]), row["utterance"])

    def test_v2_gap_labels_are_the_speakers_words_and_follow_the_list_convention(self) -> None:
        rng = random.Random(8)
        content = Content({}, rng)
        for name, (generate, _) in gaps_v2.GENERATORS_V2.items():
            for _ in range(150):
                ctx = builder.context(rng)
                draft = generate(rng, content, ctx)
                shaped, _ = asr.shape(draft.segments, rng)
                row = builder.row(positives.Draft(shaped, draft.tool, draft.args, draft.tags), ctx, "v2", "template", "x", [])
                spoken = words(row["utterance"])
                self.assertTrue(builder.list_convention_ok(row["call"]), row["call"])
                for key, value in row["call"]["args"].items():
                    if key in ("channel", "tracker", "reason", "duration_minutes"):
                        continue
                    for item in value if isinstance(value, list) else [value]:
                        self.assertTrue(words(item) <= spoken, f"{name}.{key}={item!r} not in {row['utterance']!r}")

    def test_list_convention(self) -> None:
        ok = lambda items: builder.list_convention_ok({"tool": "add_to_list", "args": {"items": items, "list": "x"}})  # noqa: E731
        self.assertTrue(ok(["chicken", "rice", "yogurt"]))
        self.assertTrue(ok(["paper towels", "salt and pepper"]))
        self.assertFalse(ok(["chicken rice and yogurt"]))

    def test_self_corrections_label_the_corrected_value(self) -> None:
        rng = random.Random(5)
        for _ in range(50):
            spoken, label = positives.banks.corrected_time(rng)
            first, second = spoken.split()[1], label.split()[1]
            self.assertNotEqual(first, second)
            self.assertTrue(spoken.startswith("at ") and label.startswith("at "))
            self.assertNotIn(first, label.split())

    def test_shaping_never_touches_a_slot(self) -> None:
        rng = random.Random(9)
        for _ in range(300):
            segments, _ = asr.shape(["remind me to", Slot("call the bank"), Slot("at 3 no 4 pm")], rng)
            slots = [s.spoken for s in segments if isinstance(s, Slot)]
            self.assertEqual(slots, ["call the bank", "at 3 no 4 pm"])

    def test_refusals_carry_their_reason(self) -> None:
        rng = random.Random(1)
        content = Content({}, rng)
        for reason, generate in refusals.REFUSALS.items():
            draft = generate(rng, content, builder.context(rng))
            self.assertEqual((draft.tool, draft.args), ("no_action", {"reason": reason}))


class ParaphraseCheck(unittest.TestCase):
    def test_slots_must_survive_verbatim_and_nothing_datelike_added(self) -> None:
        original = "remind me to [[call the bank]] [[tomorrow at 9]]"
        self.assertTrue(tool_llm.paraphrase_ok(original, "hey can you remind me [[tomorrow at 9]] to [[call the bank]]"))
        self.assertFalse(tool_llm.paraphrase_ok(original, "remind me to [[call the bank]] [[tomorrow at 10]]"))
        self.assertFalse(tool_llm.paraphrase_ok(original, "remind me to [[call the bank]] [[tomorrow at 9]] and [[call the bank]]"))
        self.assertFalse(tool_llm.paraphrase_ok(original, "on friday remind me to [[call the bank]] [[tomorrow at 9]]"))
        self.assertFalse(tool_llm.paraphrase_ok(original, "remind me to call the bank [[tomorrow at 9]]"))

    def test_paraphrase_keeps_the_tools_trigger(self) -> None:
        self.assertTrue(tool_llm.keeps_trigger("save_note", "can you jot down [[the gate code changed]]"))
        self.assertFalse(tool_llm.keeps_trigger("save_note", "i need you to save [[remind sarah about the swap]]"))
        self.assertFalse(tool_llm.keeps_trigger("set_timer", "give me [[ten minutes]] for [[the tea]]"))

    def test_resegment_makes_slots_again(self) -> None:
        segments = builder.resegment("hey [[call the bank]] tomorrow")
        self.assertEqual([s.spoken if isinstance(s, Slot) else s for s in segments], ["hey", "call the bank", "tomorrow"])


class Contamination(unittest.TestCase):
    def test_eight_grams_and_whole_short_texts(self) -> None:
        index = builder.Contamination(["please remind me to water the plants tonight at nine", "open the calendar app"])
        self.assertTrue(index.hits("uh please remind me to water the plants tonight at nine thanks"))
        self.assertTrue(index.hits("open the calendar app"))
        self.assertFalse(index.hits("open the calendar app now please"))
        self.assertFalse(index.hits("remind me to water the plants tomorrow"))

    def test_short_dev_utterances_are_indexed_whole(self) -> None:
        dev = {"cases": [{"utterance": "open it", "expect": {"args": {"target": "it"}}}]}
        index = builder.Contamination(builder.dev_texts(dev, [], []))
        self.assertTrue(index.hits("open it"))
        self.assertFalse(index.hits("open it now"))

    def test_short_dev_label_values_are_caught(self) -> None:
        index = builder.Contamination([], ["check the bank statement", "slack"])
        self.assertTrue(index.label_hits({"tool": "create_reminder", "args": {"title": "Check the bank statement"}}))
        self.assertFalse(index.label_hits({"tool": "open_app", "args": {"target": "slack"}}))  # one word: vocabulary
        self.assertFalse(index.label_hits({"tool": "no_action", "args": {"reason": "not_a_command"}}))

    def test_conflicting_labels_are_dropped(self) -> None:
        rows = [{"utterance": "open slack", "call": {"tool": "open_app", "args": {"target": "slack"}}},
                {"utterance": "open slack", "call": {"tool": "no_action", "args": {"reason": "not_a_command"}}},
                {"utterance": "open figma", "call": {"tool": "open_app", "args": {"target": "figma"}}},
                {"utterance": "open  figma", "call": {"tool": "open_app", "args": {"target": "figma"}}}]
        kept, conflicts = builder.dedupe(rows)
        self.assertEqual(([r["utterance"] for r in kept], conflicts), (["open figma"], 2))


class SchemaAndGuards(unittest.TestCase):
    def test_python_schema_check(self) -> None:
        schema = json.loads((ROOT / "Evals/tools-v1.schema.json").read_text())
        self.assertIsNone(builder.check_schema(schema, {"tool": "set_timer", "args": {"duration": "20 minutes"}}))
        self.assertIsNotNone(builder.check_schema(schema, {"tool": "set_timer", "args": {}}))
        self.assertIsNotNone(builder.check_schema(schema, {"tool": "propose_message", "args": {"channel": "telegram", "recipient": "a", "text": "b"}}))
        self.assertIsNotNone(builder.check_schema(schema, {"tool": "open_app", "args": {"target": "slack", "when": "now"}}))

    def test_sealed_and_heldout_inputs_are_refused(self) -> None:
        manifest = Manifest(ROOT)
        with tempfile.TemporaryDirectory() as directory:
            for name in ("actions-heldout.json", "heldout-v2.json"):
                path = Path(directory) / name
                path.write_text("{}")
                with self.assertRaises((SealedEvalRefusal, ForbiddenPathError)):
                    builder.guarded_json(manifest, path)
            other = Path(directory) / "dictation-golden.json"
            other.write_text("[]")
            with self.assertRaises(ForbiddenPathError):  # not on the actions allow-list
                builder.guarded_json(manifest, other, dev_set=True)


if __name__ == "__main__":
    unittest.main()
