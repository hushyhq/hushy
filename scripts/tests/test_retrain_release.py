#!/usr/bin/env python3
"""Offline tests for the release-route recount and the policy relabel helpers. All text is invented."""
import json
from pathlib import Path
import sys
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))

import retrain_assemble as assemble  # noqa: E402
import retrain_groups as groups_lib  # noqa: E402
import retrain_release as release  # noqa: E402
import retrain_release_compare as compare  # noqa: E402
import retrain_release_cli as release_cli  # noqa: E402
import retrain_release_report as report  # noqa: E402

GROUP_ROW = {"id": "x", "wholeDraft": "We ship on Wednesday and tell Marta.", "groups": [
    {"index": 0, "text": "we ship on tuesday no wait wednesday", "draft": "We ship on Wednesday",
     "continuesSentence": False},
    {"index": 1, "text": "and tell marta", "draft": "And tell Marta.", "continuesSentence": True}]}
SOURCE = {"id": "x", "route": "speech_first", "family": "agent", "kind": "k", "band": "b", "profile": "heavy",
          "surface": "plain", "spoken": "we ship on tuesday no wait wednesday and tell marta",
          "typed": "Ship Wednesday and let Marta know.", "plants": [
              {"kind": "value_cue", "said_first": "tuesday", "ended_on": "wednesday"}]}
PIECES = [{"index": 0, "piece": "We ship on Wednesday", "new_paragraph": False, "span_representable": True, "reason": ""},
          {"index": 1, "piece": "and tell Marta.", "new_paragraph": False, "span_representable": True, "reason": ""}]


class BundleTests(unittest.TestCase):
    def test_every_family_has_a_destination_and_agent_is_the_claude_app(self):
        for family in ("agent", "chat", "status", "email", "personal", "note"):
            self.assertTrue(release.bundle_for(family))
        self.assertEqual(release.bundle_for("agent"), "com.anthropic.claudefordesktop")
        rows = release.groups_in_rows([SOURCE])
        self.assertEqual(rows, [{"id": "x", "text": SOURCE["spoken"], "bundle": release.AGENT_BUNDLE}])


class RelabelCardTests(unittest.TestCase):
    def test_relabel_version_selects_distinct_brief_and_runner(self):
        brief, runner = release_cli.relabel_policy("v4")
        self.assertEqual(brief.name, "GROUP-TARGETS-INSTRUCTIONS-V4.md")
        self.assertEqual(runner.tool, "retrain_group_targets_v4")
        new_brief, new_runner = release_cli.relabel_policy("v4.1")
        self.assertEqual(new_brief.name, "GROUP-TARGETS-INSTRUCTIONS.md")
        self.assertEqual(new_runner.tool, "retrain_group_targets_v4")
        old_brief, old_runner = release_cli.relabel_policy("v3")
        self.assertEqual(old_brief.name, "GROUP-TARGETS-INSTRUCTIONS-V3.md")
        self.assertEqual(old_runner.tool, "retrain_group_targets_v3")

    def test_judge_reports_join_pieces_and_flatten_newlines(self):
        sources = [{**SOURCE, "id": "x", "typed": "First line.\n\nSecond line."}]
        targets = [{"id": "x", "pieces": [{**PIECES[0], "piece": "First."},
                                           {**PIECES[1], "piece": "Second.", "new_paragraph": True}]}]
        reports = release_cli.judge_reports(sources, targets, flat=False)
        self.assertEqual(reports["joined"], [{"id": "x", "output": "First.\n\nSecond."}])
        self.assertEqual(reports["whole"], [{"id": "x", "output": "First line.\n\nSecond line."}])
        flat = release_cli.judge_reports(sources, targets, flat=True)
        self.assertEqual(flat["joined"], [{"id": "x", "output": "First. Second."}])
        self.assertEqual(flat["whole"], [{"id": "x", "output": "First line. Second line."}])

    def test_the_card_has_drafts_and_left_context_and_no_typed_text(self):
        card = release.relabel_card(SOURCE, GROUP_ROW)
        self.assertNotIn("typed", card)
        self.assertEqual(card["groups"][0]["left_context"], "none")
        self.assertEqual(card["groups"][1]["left_context"], "We ship on Wednesday")
        self.assertTrue(card["groups"][1]["continues_sentence"])
        self.assertEqual(card["planted"], [{"said_first": "tuesday", "ended_on": "wednesday"}])
        self.assertNotIn("Ship Wednesday", json.dumps(card))


class VerdictRowTests(unittest.TestCase):
    def test_comparison_heading_describes_mixed_verdict_basis(self):
        heading = report.compare_md({}).splitlines()[0]
        self.assertIn("release-route pair check accepted / rejected", heading)
        self.assertIn("mixed draft basis", heading)

    def test_comparison_count_appears_under_release_route_label(self):
        shape = {route: {"pairs": 1, "punct_case_only": 0, "over_limit_sentences": 0,
                         "passages_with_over_limit": 0, "longest_sentence": 5} for route in release.ROUTES}
        guard = {route: {"accepted": 1, "rejected": 0} for route in release.ROUTES}
        lines = report.compare_md({"sample": {"shape": shape, "guard": guard}}).splitlines()
        self.assertEqual(lines[2].split("|")[-2].strip(), "1 / 0")

    def test_rows_cover_both_arms_and_the_earlier_text(self):
        rows = release.verdict_rows(SOURCE, GROUP_ROW, PIECES, "We ship on Wednesday and tell Marta.")
        self.assertEqual([r["id"] for r in rows], ["x-whole", "x-whole-old", "x-g0", "x-g1"])
        self.assertEqual(rows[0]["target"], "We ship on Wednesday and tell Marta.")
        self.assertEqual(rows[1]["target"], SOURCE["typed"])
        self.assertTrue(all(r["bundle"] == release.AGENT_BUNDLE for r in rows))
        self.assertEqual(rows[2]["raw"], GROUP_ROW["groups"][0]["text"])

    def test_empty_piece_makes_no_pair(self):
        pieces = [dict(PIECES[0], piece="  "), PIECES[1]]
        rows = release.verdict_rows(SOURCE, GROUP_ROW, pieces, "And tell Marta.")
        self.assertEqual([r["id"] for r in rows], ["x-whole", "x-whole-old", "x-g1"])

    def test_the_basis_says_how_close_to_the_release_verdict_the_answer_is(self):
        exact = {"pairCheckDraftMatchesReleaseDraft": True, "rejection": None, "ownDraft": "A b.", "releaseDraft": "A b."}
        self.assertEqual(release.release_verdict(exact)["basis"], "exact")
        legacy = {"verdictExact": True, "rejection": None, "releaseDraft": "A b."}
        self.assertEqual(release.release_verdict(legacy)["basis"], "exact")
        case = {"pairCheckDraftMatchesReleaseDraft": False, "rejection": "dropped number: 3", "ownDraft": "So we ship.",
                "releaseDraft": "so we ship"}
        got = release.release_verdict(case)
        self.assertEqual((got["basis"], got["status"], got["reason"]), ("same_words", "rejected", "dropped number: 3"))
        code = {"pairCheckDraftMatchesReleaseDraft": False, "rejection": "changed identifier", "ownDraft": "see a dot py",
                "releaseDraft": "see a.py", "approxDraftReproduced": True, "approxRejection": None}
        got = release.release_verdict(code)
        self.assertEqual((got["basis"], got["status"]), ("approx", "accepted"))
        code["approxDraftReproduced"] = False
        self.assertEqual(release.release_verdict(code)["basis"], "approx_unreproduced")
        self.assertEqual(release.release_verdict(None)["status"], "not_run")
        self.assertEqual(release.release_verdict({"id": "q", "error": "missing raw/target"})["status"], "not_run")


class DifferenceTests(unittest.TestCase):
    def test_classes_of_word_differences_ignore_punctuation_and_case(self):
        self.assertEqual(release.word_differences("Meet at 9:30.", "meet at 9:30"), [])
        self.assertEqual(release.word_differences("Meet at 9:30.", "Meet at nine thirty.")[0][0], "number")
        self.assertEqual(release.word_differences("See auth.swift now.", "See auth dot swift now.")[0][0], "code token")
        self.assertEqual(release.word_differences("We are going to leave.", "We are gonna leave.")[0][0], "contraction")
        self.assertEqual(release.word_differences("Send the report.", "Send report.")[0][0], "function word")
        self.assertEqual(release.word_differences("We met Dana.", "We met Dana basically.")[0][0], "content added")
        self.assertEqual(release.word_differences("We met Dana basically.", "We met Dana.")[0][0], "content dropped")

    def test_summary_counts_a_passage_once_per_class(self):
        sources = [{"id": "a", "route": "speech_first", "typed": "Meet at 9:30 and 10:30."},
                   {"id": "b", "route": "typed_first", "typed": "Same words here."}]
        summary = release.difference_summary(sources, {"a": "Meet at nine thirty and ten thirty.",
                                                       "b": "same words here"})
        self.assertEqual(summary["differ_in_words"], 1)
        self.assertEqual(summary["by_class"]["number"], 1)
        self.assertEqual(summary["events"]["number"], 2)
        self.assertEqual(summary["by_class_and_route"]["speech_first"]["number"], 1)
        self.assertEqual(summary["ids"], ["a"])

    def test_the_earlier_text_kept_beside_the_new_one_is_what_is_compared(self):
        sources = [{"id": "a", "route": "speech_first", "typed": "New text here.", "typed_earlier": "Old text here."}]
        summary = release.difference_summary(sources, {"a": "New text here."})
        self.assertEqual(summary["differ_in_words"], 1)


class ReasonTableTests(unittest.TestCase):
    def test_counts_reasons_and_picks_examples_from_different_passages(self):
        records = [("group", "speech_first", i, False, "dropped number: 3", "exact")
                   for i in ("a-g0", "a-g1", "b-g0", "c-g2", "d-g1")]
        records += [("group", "speech_first", "e-g0", True, "", "exact"), ("whole", "typed_first", "t", False,
                                                                           "list-without-signal", "approx")]
        table = release.reason_table(records)
        group = table["group"]["speech_first"]
        self.assertEqual((group["judged"], group["accepted"], group["rejected"]), (6, 1, 5))
        entry = group["reasons"]["dropped number"]
        self.assertEqual(entry["count"], 5)
        self.assertEqual(entry["examples"], ["a-g0", "b-g0", "c-g2"])
        self.assertEqual(group["basis"]["exact"], 6)
        self.assertEqual(table["whole"]["typed_first"]["reasons"]["list-without-signal"]["examples"], ["t"])


class EndToEndTests(unittest.TestCase):
    def test_assess_and_report_on_the_release_verdicts(self):
        new = release_cli.new_source(SOURCE, PIECES)
        self.assertEqual(new["typed"], "We ship on Wednesday and tell Marta.")
        self.assertEqual(new["typed_earlier"], SOURCE["typed"])
        verdicts = {
            "x-whole": {"id": "x-whole", "pairCheckDraftMatchesReleaseDraft": True, "rejection": None, "ownDraft": "d", "releaseDraft": "d"},
            "x-g0": {"id": "x-g0", "pairCheckDraftMatchesReleaseDraft": True, "rejection": "changed digits", "ownDraft": "d",
                     "releaseDraft": "d", "rejectionAtClean": "changed digits"},
            "x-g1": {"id": "x-g1", "pairCheckDraftMatchesReleaseDraft": True, "rejection": None, "ownDraft": "d", "releaseDraft": "d"}}
        lookup = lambda table, key: release.release_verdict(table.get(key))  # noqa: E731
        result = assemble.assess(new, GROUP_ROW, {"id": "x", "pieces": PIECES}, verdicts, verdict=lookup)
        self.assertTrue(result["joined_equals_typed"])
        self.assertEqual([g["guard"]["status"] for g in result["groups"]], ["rejected", "accepted"])
        self.assertEqual(result["groups"][0]["guard"]["at_clean"], "changed digits")
        table = release.reason_table(release.arm_records([result]))
        self.assertEqual(table["group"]["speech_first"]["reasons"]["changed digits"]["examples"], ["x-g0"])
        summary = {"reasons": table, "rows_kept": report.rows_kept([result]), "differences": release.difference_summary([new], {"x": new["typed"]}),
                   "whole_on_earlier_text": report.earlier_text_table([SOURCE], verdicts)}
        text = report.render_md([SOURCE], [new], [result], {}, summary, "$0", "## Judgment\n\nnone")
        self.assertIn("release-route pair check: rejected: changed digits", text)
        self.assertIn("typed (earlier):", text)
        self.assertIn("## Judgment", text)

    def test_a_paragraph_flag_on_a_group_that_continues_a_sentence_fails_the_group(self):
        pieces = [PIECES[0], dict(PIECES[1], new_paragraph=True)]
        new = release_cli.new_source(SOURCE, pieces)
        lookup = lambda table, key: {"status": "accepted"}  # noqa: E731
        result = assemble.assess(new, GROUP_ROW, {"id": "x", "pieces": pieces}, {}, verdict=lookup)
        self.assertIn("paragraph_inside_sentence", result["groups"][1]["failed_checks"])
        self.assertFalse(result["groups"][1]["accepted"])
        self.assertEqual(result["groups"][0]["failed_checks"], [])

    def test_a_paragraph_flag_where_the_typed_text_starts_a_new_sentence_is_fine(self):
        pieces = [dict(PIECES[0], piece="We ship on Wednesday."), dict(PIECES[1], piece="Tell Marta.", new_paragraph=True)]
        new = release_cli.new_source(SOURCE, pieces)
        lookup = lambda table, key: {"status": "accepted"}  # noqa: E731
        result = assemble.assess(new, GROUP_ROW, {"id": "x", "pieces": pieces}, {}, verdict=lookup)
        self.assertNotIn("paragraph_inside_sentence", result["groups"][1]["failed_checks"])

    def test_the_run_on_measure_and_the_punctuation_only_test(self):
        self.assertEqual(compare.run_on("Short one. " + "word " * 45 + "end.")["over_limit"], 1)
        self.assertEqual(compare.run_on("One. Two three.")["longest"], 2)
        self.assertTrue(compare.only_punctuation_and_case("So we go, to Paris.", "so we go to paris"))
        self.assertFalse(compare.only_punctuation_and_case("So we go to Paris.", "We go to Paris."))

    def test_the_judge_reasons_are_clustered_by_theme(self):
        run = {"pair_summary": {"a vs b": {"pairs": 1, "wins": {"a": 1}, "ties": 0, "inconsistent": 0}}, "meta": {},
               "calls": [{"verdict": {"reason": "Version 1 has paragraph breaks and no run-on chain."}},
                         {"verdict": {"reason": "It spells out the time."}}, {"verdict": None}]}
        got = compare.judge_summary(run)
        self.assertEqual(got["reasons"], 2)
        self.assertEqual(got["clusters"]["paragraph breaks"], 1)
        self.assertEqual(got["clusters"]["run-on and sentence breaks"], 1)
        self.assertEqual(got["clusters"]["numbers, times, dates"], 1)

    def test_lost_content_words_ignore_fillers_units_and_cued_take_backs(self):
        self.assertEqual(release.lost_content_words("the data's fixed i mean none at all", "the data's none at all"), ["fixed"])
        self.assertEqual(release.lost_content_words("it was eighteen hundred dollars", "it was $1,800"), [])
        self.assertEqual(release.lost_content_words("arrived tuesday no wait thursday", "arrived Thursday"), [])
        self.assertEqual(release.lost_content_words("um the the plan", "the plan"), [])
        group_rows = {"x": {"id": "x", "text": "the data's fixed i mean none", "wholeDraft": "the data's none",
                            "groups": [{"index": 0, "text": "the data's fixed i mean none", "draft": "the data's none"}]}}
        self.assertEqual(release.damaged_drafts(group_rows), {"x-g0": ["fixed"], "x-whole": ["fixed"]})
        assessment = {"id": "x", "whole": {"failed_checks": []},
                      "groups": [{"index": 0, "failed_checks": [], "not_representable_because": [], "representable": True,
                                  "accepted": True}]}
        flagged = release_cli.flag_damage(assessment, release.damaged_drafts(group_rows))
        self.assertFalse(flagged["groups"][0]["accepted"])
        self.assertIn("draft_lost_content_word", flagged["whole"]["failed_checks"])

    def test_corrections_resolved_ignores_number_words_the_piece_wrote_as_digits(self):
        plants = [{"kind": "value_cue", "said_first": "forty", "ended_on": "thirty eight"}]
        outcome, failed = groups_lib.group_checks("And I counted 40 I counted 38 tickets.", "and I counted 38 tickets,",
                                                  plants, "and i counted forty i counted thirty eight tickets")
        self.assertNotIn("corrections_resolved", failed)

    def test_cli_writes_the_groups_in_file_and_the_verdict_rows(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            (folder / "src.jsonl").write_text(json.dumps(SOURCE) + "\n", encoding="utf-8")
            (folder / "groups.jsonl").write_text(json.dumps(GROUP_ROW) + "\n", encoding="utf-8")
            (folder / "targets.jsonl").write_text(json.dumps({"id": "x", "pieces": PIECES}) + "\n", encoding="utf-8")
            self.assertEqual(release_cli.main(["groups-in", "--sources", str(folder / "src.jsonl"), "--out",
                                               str(folder / "r"), "--scratch-dir", str(folder)]), 0)
            row = json.loads((folder / "r.groups_in.jsonl").read_text().splitlines()[0])
            self.assertEqual(row["bundle"], release.AGENT_BUNDLE)
            self.assertEqual(release_cli.main(["verdicts-in", "--sources", str(folder / "src.jsonl"), "--groups",
                                               str(folder / "groups.jsonl"), "--targets", str(folder / "targets.jsonl"),
                                               "--out", str(folder / "r"), "--scratch-dir", str(folder)]), 0)
            ids = [json.loads(line)["id"] for line in (folder / "r.verdicts_in.jsonl").read_text().splitlines()]
            self.assertEqual(ids, ["x-whole", "x-whole-old", "x-g0", "x-g1"])


if __name__ == "__main__":
    unittest.main()
