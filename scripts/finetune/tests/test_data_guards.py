"""Tests for the fine-tune data guards, manifest, contamination filter and templates.

    cd scripts/finetune && python3 -m unittest discover -s tests
"""

from __future__ import annotations

import json
import re
import os
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import build_data  # noqa: E402
import llm_prompts  # noqa: E402
import pathguard  # noqa: E402
import shapes  # noqa: E402
import templates  # noqa: E402


class PathGuardTests(unittest.TestCase):
    def test_refuses_heldout_voicelab_and_app_data(self) -> None:
        for path in [
            "Evals/heldout-v2.json",
            "Evals/heldout-v2-asr.json",
            "/x/Evals/actions-heldout-v1.json",
            "Evals/HELDOUT-v3.json",
            "data/voicelab/session-1/clip.wav",
            "Voice-Lab/export.json",
            "Evals/data/external/disflqa-test.json",
            "/x/DisfluencySpeech/test.parquet",
            os.path.expanduser("~/Library/Application Support/Hushy/history.sqlite"),
            "Evals/ab-session.jsonl",
            "Evals/eval-long64-b1.jsonl",
            "Evals/longb-notes.jsonl",
            "Evals/runs/sealed/private.jsonl",
        ]:
            with self.subTest(path=path):
                self.assertIsNotNone(pathguard.violation(path))
                with self.assertRaises(pathguard.ForbiddenPathError):
                    pathguard.check(path)

    def test_allows_dev_sets(self) -> None:
        for name in pathguard.DEV_SET_ALLOWLIST:
            self.assertIsNone(pathguard.violation(f"Evals/{name}"))

    def test_symlink_to_heldout_is_refused(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "heldout-v2.json"
            target.write_text("[]")
            link = Path(tmp) / "innocent.json"
            link.symlink_to(target)
            with self.assertRaises(pathguard.ForbiddenPathError):
                pathguard.check(link)

    def test_dev_set_allow_list(self) -> None:
        pathguard.check_dev_set("Evals/reformat-golden.json")
        with self.assertRaises(pathguard.ForbiddenPathError):
            pathguard.check_dev_set("Evals/modes-golden.json")
        with self.assertRaises(pathguard.ForbiddenPathError):
            pathguard.check_dev_set("Evals/heldout-v2.json")


class ComponentPrefixTests(unittest.TestCase):
    def test_sealed_name_prefixes_match_only_at_a_component_start(self):
        from pathguard import violation
        self.assertIsNone(violation("/tmp/review-packet-test-9B91E6AB-AD3C-443D/synthetic.jsonl"))
        self.assertEqual(violation("/tmp/x/ab-01.json"), "ab-")
        self.assertEqual(violation("/tmp/runs/longb-3.jsonl"), "longb")
        self.assertEqual(violation("/tmp/Evals/eval-long64-b2.jsonl"), "eval-long64-b")


class ManifestTests(unittest.TestCase):
    def test_records_hashes_and_proves_no_heldout(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "Evals").mkdir()
            dev = root / "Evals" / "dictation-golden.json"
            dev.write_text(json.dumps([{"id": "a", "spoken": "x", "expected": "y"}]))
            manifest = pathguard.Manifest(root)
            manifest.read_json(dev, dev_set=True)
            manifest.write_jsonl(root / "out" / "pairs.jsonl", [{"raw": "a", "target": "b"}])
            payload = manifest.to_dict()
            self.assertIn("Evals/dictation-golden.json", payload["reads"])
            self.assertEqual(payload["reads"]["Evals/dictation-golden.json"], pathguard.sha256_file(dev))
            self.assertIn("out/pairs.jsonl", payload["writes"])
            self.assertEqual(payload["heldoutProof"]["forbiddenPathsTouched"], 0)
            self.assertEqual(payload["heldoutProof"]["pathsChecked"], 2)

    def test_manifest_refuses_forbidden_reads_and_writes(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            bad = root / "Evals" / "heldout-v2.json"
            bad.parent.mkdir()
            bad.write_text("[]")
            manifest = pathguard.Manifest(root)
            with self.assertRaises(pathguard.ForbiddenPathError):
                manifest.read_json(bad)
            with self.assertRaises(pathguard.ForbiddenPathError):
                manifest.write_jsonl(root / "voicelab" / "x.jsonl", [])
            self.assertEqual(manifest.reads, {})

    def test_assert_clean_catches_a_smuggled_path(self) -> None:
        manifest = pathguard.Manifest(Path("/tmp"))
        manifest.reads["Evals/heldout-v2.json"] = "0" * 64
        with self.assertRaises(pathguard.ForbiddenPathError):
            manifest.to_dict()


class ContaminationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.index = shapes.ContaminationIndex({
            "dictation-golden.json": [
                {"id": "a", "spoken": "Let's meet at 10, no, 9 tomorrow in the main conference room.",
                 "expected": "Let's meet at 9 tomorrow in the main conference room."},
                {"id": "b", "spoken": "Is it ready yet?", "expected": "Is it ready yet?"},
            ],
            "reformat-golden.json": [
                {"id": "c", "input": "the pill looks great the waveform is too big though",
                 "levels": {"clean": {"reference": "The pill looks great. The waveform is too big, though."}}},
            ],
        })

    def test_eight_gram_overlap_is_caught(self) -> None:
        self.assertTrue(self.index.hits("okay so let's meet at 9 tomorrow in the main conference room please"))
        self.assertTrue(self.index.hits("honestly the pill looks great the waveform is too big though"))

    def test_short_dev_texts_match_whole(self) -> None:
        self.assertTrue(self.index.hits("is it ready yet"))
        self.assertFalse(self.index.hits("Is it ready yet for the demo on Friday?"))

    def test_new_text_passes(self) -> None:
        self.assertFalse(self.index.hits("Book a table for six people at the noodle bar on Thursday."))

    def test_shape_profile_has_counts_not_text(self) -> None:
        profile = shapes.shape_profile({"dictation-golden.json": [{"id": "a", "tag": "semantic", "spoken": "Order the red chairs, I mean the black chairs."}]})
        dumped = json.dumps(profile)
        self.assertNotIn("chairs", dumped)
        self.assertEqual(profile["cueUsage"]["i mean"], 1)


class TemplateTests(unittest.TestCase):
    SEED = {"id": "s1", "s": "The new dashboard loads 40 charts every Monday at 9.", "subj": "The new dashboard",
            "span": "Monday", "alt": "Friday", "kind": "day"}

    def test_deterministic(self) -> None:
        a = [templates.Generator(3).correction(self.SEED) for _ in range(1)]
        b = [templates.Generator(3).correction(self.SEED) for _ in range(1)]
        self.assertEqual(a, b)

    def test_correction_target_has_only_the_final_value(self) -> None:
        gen = templates.Generator(11)
        for _ in range(30):
            pair = gen.correction(self.SEED)
            self.assertIsNotNone(pair)
            self.assertIn("Friday", pair.target)
            self.assertNotIn("Monday", pair.target)
            self.assertIn("monday", pair.raw.lower())

    def test_negatives_are_flagged_and_unchanged(self) -> None:
        pair = templates.Generator(1).negative("I had had enough.", "legit-repeat")
        self.assertTrue(pair.negative)
        self.assertEqual(pair.raw, pair.target)

    def test_grammar_slips_are_polished_only(self) -> None:
        seed = dict(self.SEED, s="The new dashboard loads the charts every Monday.")
        pair = templates.Generator(5).grammar_slip(seed)
        self.assertEqual(pair.levels, ("polished",))
        self.assertNotEqual(pair.raw, pair.target)

    def test_llm_labels_need_jev(self) -> None:
        pairs = templates.Generator(1).llm_pair({"type": "agreement", "spoken": "The files is ready.", "fixed": "The files are ready."}, "grammar")
        self.assertTrue(pairs[0].needs_jev)
        # Clean keeps the grammar slip: a leave-unchanged pair, not an LLM label.
        self.assertEqual(pairs[1].levels, ("clean",))
        self.assertTrue(pairs[1].negative)

    def test_asr_style(self) -> None:
        text = templates.asr_style("Send 45 invoices to Priya by 3:30, okay?", templates.random.Random(0))
        self.assertNotIn(",", text.replace("3:30", ""))
        self.assertTrue(text.startswith("send"))
        self.assertIn("3:30", text)


class PipelineHelperTests(unittest.TestCase):
    def test_extract_json_array_tolerates_prose_and_fences(self) -> None:
        text = 'Here you go:\n```json\n[{"s": "a [b] c", "kind": "x"}]\n```\nDone.'
        self.assertEqual(llm_prompts.extract_json_array(text), [{"s": "a [b] c", "kind": "x"}])
        self.assertEqual(llm_prompts.extract_json_array("no json"), [])

    def test_prompts_never_contain_dev_text(self) -> None:
        rows = llm_prompts.build_prompts({"sentences": 2, "corrections": 2, "grammar": 2, "lists": 1, "negatives": 1,
                                          "long": 1, "frames": 1, "polishedneg": 1})
        index = shapes.ContaminationIndex(shapes.load_dev_sets(build_data.ROOT / "Evals", pathguard.Manifest(build_data.ROOT)))
        for row in rows:
            for line in row["prompt"].splitlines():
                self.assertFalse(index.hits(line), line)

    def test_split_is_stable_and_by_seed(self) -> None:
        self.assertEqual(build_data.stable_fraction("seed-1"), build_data.stable_fraction("seed-1"))
        values = [build_data.stable_fraction(f"s{i}") for i in range(2000)]
        self.assertAlmostEqual(sum(v < 0.08 for v in values) / len(values), 0.08, delta=0.02)

    def test_balance_meets_negative_share(self) -> None:
        rows = [{"id": str(i), "unchanged": i % 5 == 0, "kind": "x", "level": "clean", "modelAsked": True} for i in range(1000)]
        chosen = build_data.balance(rows, 300, 0.33)
        share = sum(r["unchanged"] for r in chosen) / len(chosen)
        self.assertGreaterEqual(share, 0.30)


class GroundingTests(unittest.TestCase):
    def test_target_words_must_come_from_the_draft(self) -> None:
        bad = {"draft": "Just text him the meeting location.", "target": "Text Raj the meeting location."}
        self.assertEqual(build_data.ungrounded_words(bad), ["raj"])
        ok = {"draft": "The reports is due and it need to go to both manager.", "target": "The report is due and it needs to go to both managers."}
        self.assertEqual(build_data.ungrounded_words(ok), [])
        self.assertFalse(build_data.keep({"rejection": None, "needsJev": False, **bad}))


class V55Tests(unittest.TestCase):
    def test_corrected_value_never_survives(self) -> None:
        check = build_data.corrected_value_survives
        raw = "Assign it to Mia, no, Jordan, they also I think prefers the morning shift."
        self.assertEqual(check({"negative": False, "raw": raw, "target": "Assign Jordan to Mia, no, Jordan. I think Jordan prefers it."}), "mia")
        self.assertIsNone(check({"negative": False, "raw": raw, "target": "Assign it to Jordan. I think they also prefer the morning shift."}))
        self.assertEqual(check({"negative": False, "raw": "move it to tuesday no wait wednesday",
                                "target": "Move it to Tuesday, no wait, Wednesday."}), "tuesday")
        self.assertIsNone(check({"negative": False, "raw": "I called Maya, no answer, so text her", "target": "I called Maya, no answer, so text her."}))

    def test_filler_discourse_negatives_dropped(self) -> None:
        kept = build_data.filler_discourse_kept
        self.assertTrue(kept({"negative": True, "kind": "negative:tempting-x", "draft": "So actually we ship on Friday."}))
        self.assertTrue(kept({"negative": True, "kind": "negative:register-x", "draft": "It sort of works and it sort of doesn't."}))
        self.assertFalse(kept({"negative": True, "kind": "negative:meaning-discourse", "draft": "The demo is actually on Wednesday."}))
        self.assertFalse(kept({"negative": True, "kind": "negative:frame-actually", "draft": "Actually, the new layout is faster."}))

    def test_v55_templates(self) -> None:
        gen, rng = templates.Generator(1), templates.random.Random(4)
        for _ in range(20):
            pair = gen.correction_in_frame({"kind": "name", "span": "Mia", "alt": "Jordan", "id": "n"}, rng)
            self.assertNotIn("Mia", pair.target)
            self.assertIn("Jordan.", pair.target)
            self.assertIsNone(build_data.corrected_value_survives({"negative": False, "raw": pair.raw, "target": pair.target}))
            filler = gen.discourse_filler({"s": "We should probably ship the update on Friday.", "id": "s"}, rng)
            self.assertEqual(filler.target, "We should probably ship the update on Friday.")
            self.assertGreaterEqual(len(re.findall(r"\b(actually|basically|literally)\b", filler.raw.lower())), 2)


class V54Tests(unittest.TestCase):
    def test_robust_negatives_and_punct_only_twins(self) -> None:
        gen = templates.Generator(1)
        seeds = {"registerneg": [{"id": f"r#{i}", "shape": "formal-email",
                                  "s": "Thanks for the update, Priya. Could we move the review to Thursday at 3?"} for i in range(40)]
                 + [{"id": "c#0", "shape": "casual-text", "s": "lol ok see u there"}],
                 "temptingneg": [{"id": "t#0", "kind": "starts-with-and", "s": "And that is why we ship on Fridays."}]}
        pairs = build_data.robust_negative_pairs(gen, seeds)
        negatives = [p for p in pairs if p.negative]
        self.assertEqual(len(negatives), 42)
        self.assertTrue(all(p.raw == p.target for p in negatives))
        twins = [p for p in pairs if p.kind.startswith("punct-only:")]
        self.assertTrue(twins, "some formal-email rows get a punctuation-only twin")
        for twin in twins:
            self.assertEqual(twin.target, "Thanks for the update, Priya. Could we move the review to Thursday at 3?")
            self.assertEqual(twin.raw, "thanks for the update priya could we move the review to thursday at 3")
        self.assertFalse(any(p.kind == "punct-only:casual-text" for p in pairs))
        self.assertTrue(any(p.kind.startswith("negative:tempting-") for p in pairs))

    def test_index_only_sets_refused_as_pipeline_input(self) -> None:
        with self.assertRaises(pathguard.ForbiddenPathError):
            pathguard.check("Evals/negatives-fresh-dev.json")
        with self.assertRaises(pathguard.ForbiddenPathError):
            pathguard.check_dev_set("Evals/negatives-fresh-dev.json")  # not on the shapes allow-list
        with self.assertRaises(pathguard.ForbiddenPathError):
            pathguard.Manifest(Path(".")).read_jsonl("/tmp/x/negatives-fresh-dev.jsonl")
        self.assertEqual(pathguard.check_dev_set("Evals/negatives-fresh-dev.json", pathguard.INDEX_ONLY_DEV_SETS).name,
                         "negatives-fresh-dev.json")

    def test_index_only_sets_are_never_shapes(self) -> None:
        self.assertIn("negatives-fresh-dev.json", pathguard.INDEX_ONLY_DEV_SETS)
        self.assertNotIn("negatives-fresh-dev.json", pathguard.DEV_SET_ALLOWLIST)


class V53Tests(unittest.TestCase):
    def test_lost_span_before_hedge_catches_the_v52_drops(self) -> None:
        check = build_data.lost_span_before_hedge
        spoken = "the import it fails on files over two gigs i think we should stream it in chunks"
        self.assertIsNotNone(check(spoken, "I think we should stream it in chunks."))
        self.assertIsNone(check(spoken, "The import fails on files over two gigs. I think we should stream it in chunks."))
        question = "can you remind me what we decided about the free tier i think it was voice actions stay pro"
        self.assertIsNotNone(check(question, "I think the free tier was voice actions stay pro."))
        # A resolved correction may drop the corrected value and its cue, not the instruction.
        corrected = "send it to john no sarah she also i think needs the file by monday"
        self.assertIsNotNone(check(corrected, "I think Sarah also needs the file by Monday."))
        self.assertIsNone(check(corrected, "Send it to Sarah. She also needs the file by Monday, I think."))
        # Fillers before the hedge may go; hedge moved past a restated subject is fine.
        self.assertIsNone(check("um so like basically i think we ship friday", "I think we ship Friday."))
        self.assertIsNone(check("The banner also I think shouldn't, the banner should use blue.", "I think the banner should also use blue."))

    def test_hedge_lead_keeps_the_lead(self) -> None:
        gen, rng = templates.Generator(1), templates.random.Random(5)
        for _ in range(20):
            pair = gen.hedge_lead("Can you check the invoice?", "Can you check the invoice?", "We should pay it today.", rng, "question")
            self.assertTrue(pair.target.startswith("Can you check the invoice?"), pair.target)
            self.assertRegex(pair.target, r"I (think|feel|guess|believe) we should pay it today\.$")
            self.assertIsNone(build_data.lost_span_before_hedge(pair.raw, pair.target))
        self.assertIsNone(gen.hedge_lead("We ship Friday.", "We ship Friday.", "I think it is fine.", rng, "statement"))
        self.assertIsNone(gen.hedge_lead("We ship Friday.", "We ship Friday.", "Please send the forms today.", rng, "statement"))
        self.assertIsNone(gen.hedge_lead("We ship Friday.", "We ship Friday.", "The refund arrives within fourteen days.", rng, "statement"))
        for _ in range(30):
            pair = gen.hedge_lead("The import fails on big files.", "The import fails on big files.", "We should stream it in chunks.", rng, "statement")
            spoken = pair.raw.lower()
            for conjunction in ("and", "so"):
                if f"files {conjunction} i" in spoken:
                    self.assertIn(f"files, {conjunction} I", pair.target)
            self.assertTrue(pair.target.startswith("The import fails on big files"))

    def test_garbled_hedge_restart_restates_the_exact_subject(self) -> None:
        gen = templates.Generator(1)
        for seed in range(10):
            pair = gen.garbled_hedge_restart({"s": "The pricing deck should include a competitor slide."}, templates.random.Random(seed))
            spoken, restart = pair.raw.lower().split("n't", 1)
            self.assertTrue(spoken.startswith("the pricing deck") and restart.strip(" ,").startswith("the pricing deck should"))

    def test_hedge_move_skips_imperatives(self) -> None:
        gen = templates.Generator(1)
        self.assertIsNone(gen.hedge_move({"s": "Remind Marcus to check the inventory.", "subj": "Remind Marcus"}))
        self.assertIsNotNone(gen.hedge_move({"s": "The library closes at six.", "subj": "The library"}))


class V52Tests(unittest.TestCase):
    def test_modal_restart_templates(self) -> None:
        gen, rng = templates.Generator(1), templates.random.Random(3)
        pair = gen.modal_restart({"s": "We would need a second printer for the office."}, rng)
        self.assertEqual(pair.target, "We would need a second printer for the office.")
        self.assertRegex(pair.raw.lower(), r"^we wouldn't,? .*we would need")
        hedge = gen.garbled_hedge_restart({"s": "The new banner should use a darker blue."}, rng)
        self.assertEqual(hedge.levels, ("polished",))
        self.assertTrue(hedge.target.startswith(("I think the new banner should", "I feel the new banner should", "I guess the new banner should")))
        self.assertIsNone(gen.garbled_hedge_restart({"s": "We should go."}, rng))


class V51Tests(unittest.TestCase):
    def test_article_never_dropped_inside_a_series(self) -> None:
        gen, rng = templates.Generator(1), templates.random.Random(1)
        self.assertIsNone(gen.article({"s": "I need to get a banana, an orange and a grape."}, rng))
        self.assertIsNone(gen.article({"s": "Bring a tent and a stove."}, rng))
        pair = gen.article({"s": "Please send an invoice to the client today."}, rng)
        self.assertEqual(pair.target, "Please send an invoice to the client today.")

    def test_bare_series_stay_prose_and_bare(self) -> None:
        gen, rng = templates.Generator(1), templates.random.Random(4)
        pair = gen.bare_series({"id": "l", "items": ["the tent", "sleeping bags", "a lantern"]}, rng)
        self.assertTrue(pair.negative)
        self.assertNotRegex(pair.raw, r"\b(the|a) (tent|lantern)\b")

    def test_regression_check_catches_added_articles(self) -> None:
        bad = {"draft": "I need to get banana, orange and grape.", "target": "I need to get a banana, an orange and a grape."}
        self.assertEqual(build_data.adds_article_to_series(bad), ["banana", "orange", "grape"])
        ok = {"draft": "I need to get banana, orange and grape.", "target": "I need to get banana, orange and grape."}
        self.assertEqual(build_data.adds_article_to_series(ok), [])
        fine = {"draft": "Please send invoice to the client.", "target": "Please send an invoice to the client."}
        self.assertEqual(build_data.adds_article_to_series(fine), [])


class V5Tests(unittest.TestCase):
    def test_v5_templates(self) -> None:
        gen, rng = templates.Generator(1), templates.random.Random(2)
        ack = gen.ack_negative({"id": "a", "s": "The movers arrive at nine."}, rng)
        self.assertTrue(ack.negative and ack.raw.split(",")[0] in templates.Generator.ACKS)
        art = gen.article({"s": "Please send an invoice to the client."}, rng)
        self.assertEqual(art.target, "Please send an invoice to the client.")
        self.assertNotIn(" an ", art.raw)
        ex = gen.existential({"s": "There are two new bugs in the tracker."}, rng)
        self.assertEqual(ex.raw.split(" ")[:2], ["There", "is"])
        dn = gen.double_negative({"s": "We don't have any spare chargers."}, rng)
        self.assertIn("no spare", dn.raw)
        self.assertIsNone(gen.double_negative({"s": "We can't say we don't have any."}, rng))

    def test_double_negative_repair_is_grounded(self) -> None:
        row = {"draft": "We don't have no spare chargers.", "target": "We don't have any spare chargers."}
        self.assertEqual(build_data.ungrounded_words(row), [])
        row = {"draft": "There has been two outages.", "target": "There have been two outages."}
        self.assertEqual(build_data.ungrounded_words(row), [])


class V4Tests(unittest.TestCase):
    def test_agreement_keeps_the_majority_number(self) -> None:
        gen = templates.Generator(1)
        sing = gen.agreement({"s": "The contract is ready and it needs one more signature.", "subject": "The contract",
                              "number": "singular", "other": "The contracts"})
        self.assertEqual(sing.target, "The contract is ready and it needs one more signature.")
        self.assertIn("contracts", sing.raw.lower())
        self.assertEqual(sing.levels, ("polished",))
        plural = gen.agreement({"s": "Our printers are jammed and they need new rollers.", "subject": "Our printers",
                                "number": "plural", "other": "Our printer"})
        self.assertTrue(plural.raw.startswith("Our printers is") or plural.raw.startswith("our printers is"))
        self.assertIsNone(gen.agreement({"s": "These boards are worn and they need sanding.", "subject": "These boards",
                                         "number": "singular", "other": "This board"}))

    def test_tense_only_safe_stems(self) -> None:
        gen = templates.Generator(1)
        pair = gen.tense({"s": "Yesterday the courier delivered the boxes and we asked for a receipt."})
        self.assertEqual(pair.target, "Yesterday the courier delivered the boxes and we asked for a receipt.")
        self.assertNotIn("updat ", (gen.tense({"s": "Last week we updated the router and checked the logs."}) or pair).raw)
        self.assertIsNone(gen.tense({"s": "We updated the router."}))

    def test_rules_mangled_negatives_are_dropped(self) -> None:
        row = {"raw": "Elena, sorry I'm late, just start without me.", "draft": "I'm late, just start without me.",
               "target": "I'm late, just start without me.", "negative": True, "rejection": None, "needsJev": False}
        self.assertEqual(build_data.rules_dropped_words(row), ["elena", "sorry"])
        self.assertFalse(build_data.keep(row))
        itn = {"raw": "We saved fifty dollars.", "draft": "We saved $50.", "target": "We saved $50.", "negative": True,
               "rejection": None, "needsJev": False}
        self.assertTrue(build_data.keep(itn))
        time = {"raw": "Meet at ten AM.", "draft": "Meet at 10:00am.", "target": "Meet at 10:00am.", "negative": True,
                "rejection": None, "needsJev": False}
        self.assertEqual(build_data.rules_dropped_words(time), [])


class V3TemplateTests(unittest.TestCase):
    def test_frame_retarget_keeps_the_person_and_the_final_verb(self) -> None:
        item = {"type": "retarget", "lead": "Can you", "verb_a": "call", "verb_b": "text", "person": "Dana", "pronoun": "her", "rest": "the code"}
        for seed in range(10):
            pair = templates.Generator(seed).frame(item)
            self.assertEqual(pair.target, "Can you text Dana the code?")
            self.assertIn("call", pair.raw.lower())

    def test_frame_keep_and_headnoun(self) -> None:
        gen = templates.Generator(2)
        keep = gen.frame({"type": "keep", "verb_a": "Move", "thing": "the sync", "prep_a": "to", "value_a": "noon",
                          "prep_b": "at", "value_b": "ten", "tail": "but make it shorter"})
        self.assertRegex(keep.target, r"^(Keep|Leave) the sync at ten, but make it shorter\.$")
        self.assertNotIn("noon", keep.target)
        head = gen.frame({"type": "headnoun", "s": "Order the black chairs today.", "adj_a": "red", "adj_b": "black", "noun": "chairs"})
        self.assertEqual(head.target, "Order the black chairs today.")
        self.assertIn("red", head.raw.lower())

    def test_frame_rejects_bad_slots(self) -> None:
        gen = templates.Generator(1)
        self.assertIsNone(gen.frame({"type": "headnoun", "s": "Order chairs.", "adj_a": "red", "adj_b": "black", "noun": "chairs"}))
        self.assertIsNone(gen.frame({"type": "retarget", "verb_a": "call", "verb_b": "call", "person": "A", "pronoun": "her"}))
        self.assertIsNone(gen.frame({"type": "unknown"}))

    def test_long_ops_keep_the_passage_as_target(self) -> None:
        seed = {"id": "l", "s": "The movers arrive Thursday at eight, so we need the boxes packed by Wednesday night. "
                                 "Keep the kitchen stuff separate, because Asha wants it first.", "span": "Thursday", "alt": "Friday", "kind": "day"}
        gen = templates.Generator(4)
        self.assertEqual(gen.long_disfluent(seed).target, seed["s"])
        self.assertEqual(gen.long_runon(seed).target, seed["s"])
        self.assertIn("Friday", gen.long_correction(seed).target)

    def test_polished_only_negatives(self) -> None:
        pair = templates.Generator(1).negative("None of the invoices were late.", "polished-x", levels=("polished",))
        self.assertEqual(pair.levels, ("polished",))


class V4ListTests(unittest.TestCase):
    """Data v4: item count never decides; only a signalled list becomes a list."""

    SEED = {"id": "l1", "lead": "For the camping trip we need", "items": ["the tent", "sleeping bags", "a lantern", "bug spray"]}

    def test_inline_series_stays_prose(self) -> None:
        gen = templates.Generator(2)
        for pair in gen.inline_series_bank():
            with self.subTest(raw=pair.raw):
                self.assertEqual(pair.kind, "list:inline")
                self.assertNotIn("\n", pair.target)
                self.assertTrue(pair.target.endswith("."))
        counts = {len(p.target.split(",")) for p in gen.inline_series_bank()}
        self.assertTrue(counts & {5, 6, 7, 8} or counts & {4, 5, 6, 7}, counts)

    def test_list_targets_only_with_a_signal(self) -> None:
        gen = templates.Generator(9)
        kinds = set()
        for _ in range(200):
            pair = gen.list_format(self.SEED)
            kinds.add(pair.kind)
            if "\n" in pair.target:
                raw = re.sub(r"\b(?:um|uh|you know|like|basically|actually|so)\b\s*", "", pair.raw.lower())
                signalled = "first," in raw or "bullet " in raw or templates.LIST_INTRO.search(raw) is not None
                self.assertTrue(signalled, pair.raw)
            else:
                self.assertEqual(pair.kind, "list:inline")
        self.assertEqual(kinds, {"list:inline", "list:introduced", "list:ordinals", "list:bullet"})

    def test_intro_mirrors_list_formatter(self) -> None:
        for lead in ["Shopping list", "My to-do list", "The list is", "Three things", "Agenda for today", "Topics for the sync"]:
            self.assertIsNotNone(templates.LIST_INTRO.search(lead), lead)
        for lead in ["For the trip we need", "I need to get", "We invited", "A few things"]:
            self.assertIsNone(templates.LIST_INTRO.search(lead), lead)


if __name__ == "__main__":
    unittest.main()
