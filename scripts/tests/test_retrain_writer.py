#!/usr/bin/env python3
"""Offline tests for the example writer and its checks. Network is a loopback fake server only; no real
key is read. All text is invented."""
import contextlib
import io
import json
from pathlib import Path
import re
import sys
import tempfile
import unittest
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
sys.path.insert(0, str(Path(__file__).resolve().parent))

import api_judge  # noqa: E402
import api_judge_client as client_module  # noqa: E402
import retrain_checks as checks  # noqa: E402
import retrain_numbers as numbers  # noqa: E402
import retrain_wordchecks as wordchecks  # noqa: E402
import retrain_writer as writer  # noqa: E402
from api_judge_verdict import VerdictError  # noqa: E402
from test_api_judge import AFTER_PREFIX, CACHED_PREFIX, FAKE_KEY, MARKER, OUTPUT, FakeApi, cache_aware, message  # noqa: E402

SPOKEN = ("um so the the meeting is on tuesday no wait wednesday at three o'clock and we're gonna talk about the "
          "budget which is uh about forty two hundred dollars. I do not I do not think Sarah should come because "
          "she was ill last week.")
GOOD = ("The meeting is on Wednesday at 3 o'clock, and we are going to talk about the budget, which is about "
        "$4,200.\n\nI do not think Sarah should come because she was ill last week.")
CORRECTIONS = [{"said_first": "tuesday", "ended_on": "wednesday"}]


def failing(spoken, typed, corrections=(), taken_back=(), **kw):
    return checks.failed(checks.run_checks(spoken, typed, corrections, taken_back, **kw))


class NumberTests(unittest.TestCase):
    def values(self, text):
        return [n.value for n in numbers.extract(text)]

    def test_words_and_digits_have_the_same_value(self):
        for said, typed in (("twenty five percent", "25%"), ("forty two hundred dollars", "$4,200"),
                            ("the twenty seventh", "the 27th"), ("three point five", "3.5"),
                            ("two hundred and fifty", "250"), ("a hundred", "100"), ("twenty-five", "25"),
                            ("two thousand and five", "2005")):
            self.assertEqual(self.values(said), self.values(typed), said)

    def test_years_and_digit_runs(self):
        found = numbers.extract("nineteen ninety")
        self.assertIn(1990, found[0].alternates)
        self.assertEqual(self.values("three three six zero"), [3, 3, 6, 0])
        self.assertEqual(self.values("3:30"), [3, 30])

    def test_lone_one_is_weak(self):
        self.assertTrue(numbers.extract("one of the things")[0].weak)
        self.assertFalse(numbers.extract("one hundred")[0].weak)


class CheckTests(unittest.TestCase):
    def test_a_good_row_passes_every_check(self):
        self.assertEqual(failing(SPOKEN, GOOD, CORRECTIONS), [])

    def test_a_changed_number_is_caught_on_both_sides(self):
        result = checks.run_checks(SPOKEN, GOOD.replace("$4,200", "$5,200"), CORRECTIONS)
        self.assertEqual(result["numbers"]["added"], [5200])
        self.assertEqual(result["numbers"]["missing"], [4200])
        self.assertEqual(failing(SPOKEN, GOOD.replace("$4,200", "$5,200"), CORRECTIONS), ["numbers"])

    def test_a_dropped_number_is_caught(self):
        typed = GOOD.replace(", which is about $4,200", "")
        self.assertIn("numbers", failing(SPOKEN, typed, CORRECTIONS))

    def test_the_first_value_kept_after_a_correction(self):
        typed = GOOD.replace("Wednesday", "Tuesday")
        found = failing(SPOKEN, typed, CORRECTIONS)
        self.assertIn("dates", found)
        self.assertIn("taken_back_residue", found)

    def test_both_values_kept(self):
        typed = GOOD.replace("Wednesday", "Tuesday, no, Wednesday")
        self.assertIn("taken_back_residue", failing(SPOKEN, typed, CORRECTIONS))

    def test_a_name_that_was_not_said(self):
        typed = GOOD.replace("Sarah", "Sarah and Tom")
        result = checks.run_checks(SPOKEN, typed, CORRECTIONS)
        self.assertEqual(result["names"]["added"], ["tom"])
        self.assertFalse(result["content_words_added"]["ok"])

    def test_a_name_that_was_dropped(self):
        typed = GOOD.replace("Sarah", "she").replace("because she was", "because she was")
        self.assertEqual(checks.run_checks(SPOKEN, typed, CORRECTIONS)["names"]["missing"], ["sarah"])

    def test_negation_dropped_and_added(self):
        dropped = GOOD.replace("I do not think", "I think")
        added = GOOD.replace("Sarah should come", "Sarah should not come")
        self.assertEqual(checks.run_checks(SPOKEN, dropped, CORRECTIONS)["negation"]["problems"], ["negation_lost"])
        self.assertEqual(checks.run_checks(SPOKEN, added, CORRECTIONS)["negation"]["problems"], ["negation_added"])

    def test_negation_inside_a_resolved_correction_may_go(self):
        spoken = "we should not ship friday I mean we should ship friday because the tests pass"
        typed = "We should ship Friday because the tests pass."
        bad = checks.run_checks(spoken, typed, [])
        self.assertEqual(bad["negation"]["problems"], ["negation_lost"])
        good = checks.run_checks(spoken, typed, [{"said_first": "we should not ship friday",
                                                  "ended_on": "we should ship friday"}])
        self.assertTrue(good["negation"]["ok"])

    def test_an_added_content_word(self):
        typed = GOOD.replace("I do not think", "I strongly do not think")
        result = checks.run_checks(SPOKEN, typed, CORRECTIONS)
        self.assertEqual(result["content_words_added"]["added"], [checks.stem("strongly")])
        self.assertEqual(checks.failed(checks.run_checks(SPOKEN, typed, CORRECTIONS, max_added=1)), [])

    def test_grammar_repairs_and_contractions_are_free(self):
        spoken = "i don't wanna go and they was late 'cause it's raining"
        typed = "I do not want to go, and they were late because it is raining."
        self.assertEqual(checks.run_checks(spoken, typed)["content_words_added"]["added"], [])

    def test_over_deletion_and_under_deletion_are_counted_apart(self):
        short = checks.run_checks(SPOKEN, "The meeting is on Wednesday.", CORRECTIONS)["length"]
        self.assertEqual(short["label"], "over_deletion")
        long = checks.run_checks(SPOKEN, GOOD + " " + GOOD[:80], CORRECTIONS)["length"]
        self.assertEqual(long["label"], "under_deletion")
        self.assertEqual(checks.run_checks(SPOKEN, GOOD, CORRECTIONS)["length"]["label"], "ok")

    def test_moved_paragraph_breaks_the_order(self):
        first, second = GOOD.split("\n\n")
        swapped = second + "\n\n" + first
        result = checks.run_checks(SPOKEN, swapped, CORRECTIONS)
        self.assertFalse(result["order"]["ok"])
        self.assertTrue(checks.run_checks(SPOKEN, GOOD, CORRECTIONS)["order"]["ok"])

    def test_fillers_repeats_fragments_and_dashes_left_in(self):
        for typed in (GOOD.replace("The meeting", "Um, the meeting"), GOOD.replace("the budget", "the the budget"),
                      GOOD.replace("talk", "ta- talk"), GOOD.replace("Wednesday at", "Wednesday - at")):
            self.assertEqual(checks.run_checks(SPOKEN, typed, CORRECTIONS)["fillers"]["ok"], False, typed)
        self.assertTrue(checks.check_fillers("They said uh-huh and left.")["ok"])

    def test_an_invented_correction_is_not_grounded(self):
        fake = [{"said_first": "thursday", "ended_on": "friday"}]
        self.assertEqual(checks.check_corrections_grounded(SPOKEN, fake)["ungrounded"], ["thursday"])
        self.assertTrue(checks.check_corrections_grounded(SPOKEN, CORRECTIONS)["ok"])

    def test_layer_marked_words_are_reported_but_never_quarantine(self):
        spoken = "send it to the ham no the sam office"
        typed = "Send it to the Ham office."
        self.assertNotIn("taken_back_residue", failing(spoken, typed, taken_back=["ham"]))
        report = checks.run_report_only(spoken, typed, taken_back=["ham"])
        self.assertEqual(report["layer_taken_back_residue"]["leftover"], ["ham"])
        self.assertEqual(checks.noted(report), ["layer_taken_back_residue"])
        self.assertEqual(checks.noted(checks.run_report_only(spoken, "Send it to the sam office.", ["ham"])), [])

    def test_words_the_writer_itself_reported_as_taken_back_still_quarantine(self):
        spoken = "send it to the ham no the sam office"
        corrections = [{"said_first": "the ham", "ended_on": "the sam"}]
        self.assertIn("taken_back_residue", failing(spoken, "Send it to the Ham office.", corrections))
        self.assertNotIn("taken_back_residue", failing(spoken, "Send it to the sam office.", corrections))

    def test_each_check_is_reported_separately(self):
        result = checks.run_checks(SPOKEN, "x", CORRECTIONS)
        self.assertEqual(set(result), set(checks.CHECK_NAMES))
        self.assertEqual(set(checks.run_report_only(SPOKEN, "x")), set(checks.REPORT_ONLY_NAMES))
        self.assertTrue(all("ok" in v for v in result.values()))

    def test_fragments_and_fillers_in_the_spoken_text_do_not_demand_survival(self):
        spoken = "we need ten- twenty people and um thirty- two chairs"
        self.assertEqual(failing(spoken, "We need 20 people and 32 chairs."), [])


class WordFamilyAndFunctionTests(unittest.TestCase):
    SPOKEN = ("so I think because of our highly uh requirements we need an advanced chip and the remote should be "
              "technological innovative and less of them will buy it in the colour of the spongey material")

    def test_informal_negations_count_on_the_spoken_side(self):
        spoken = "well I dunno how much it costs and I cant say when"
        typed = "Well, I don't know how much it costs, and I can't say when."
        self.assertEqual(checks.run_checks(spoken, typed)["negation"]["problems"], [])
        self.assertEqual(checks.negation_count("I dunno and nah"), 2)
        lost = checks.run_checks(spoken, "Well, I know how much it costs, and I can't say when.")
        self.assertEqual(lost["negation"]["problems"], ["negation_lost"])

    def test_same_word_family_and_spelling_variants_are_related_not_added(self):
        typed = ("So I think because of our high requirements we need an advanced chip, and the remote should be "
                 "technologically innovative, and fewer of them will buy it in the color of the spongy material.")
        found = checks.run_checks(self.SPOKEN, typed)["content_words_added"]
        self.assertTrue(found["ok"], found)
        self.assertEqual(sorted(found["related"]), ["color", "fewer", "high", "spongy", "technologically"])

    def test_a_new_content_word_is_still_an_addition(self):
        typed = "So I think because of our high requirements we need an advanced chip and a battery."
        self.assertEqual(checks.run_checks(self.SPOKEN, typed)["content_words_added"]["added"], ["battery"])

    def test_function_words_the_content_check_ignores_are_counted_on_their_own(self):
        spoken = "the data came from the site " * 6
        typed = "Now the data only came from the site. " * 6
        result = checks.run_checks(spoken, typed)
        self.assertTrue(result["content_words_added"]["ok"])
        self.assertEqual(result["function_words_added"]["surplus"], {"now": 6, "only": 6})
        self.assertFalse(result["function_words_added"]["ok"])

    def test_function_word_rate_has_a_tolerance(self):
        spoken = " ".join(f"word{i}" for i in range(60)) + " and then we left"
        typed = " ".join(f"word{i}" for i in range(60)) + ". Now we left."
        ok = wordchecks.check_function_words_added(spoken, typed, tolerance_per100=5)
        self.assertTrue(ok["ok"], ok)
        self.assertFalse(wordchecks.check_function_words_added(spoken, typed, tolerance_per100=0.5)["ok"])

    def test_an_added_subject_and_modal_at_a_sentence_start_is_caught(self):
        spoken = ("our budget would have to affect um try not to reflect our budget and we might have a gap " * 2
                  + "we could see it later")
        supplied = "Try not to reflect our budget. We would try again. " + "word " * 40
        found = wordchecks.check_function_words_added(spoken, supplied, tolerance_per100=100)
        self.assertEqual(found["supplied_subject_modal"], ["we would"])
        self.assertFalse(found["ok"])
        said = "We could see it later. " + "word " * 40
        self.assertEqual(wordchecks.check_function_words_added(spoken, said, 100)["supplied_subject_modal"], [])
        self.assertEqual(wordchecks.check_function_words_added("we'll go then " + "x " * 30, "We will go then. " + "x " * 30,
                                                            100)["supplied_subject_modal"], [])

    def test_compound_ordinals_with_and_read_as_one_number(self):
        spoken = "it's a hundred and first in the top two hundred and fifty"
        typed = "It's 101st in the top 250."
        self.assertNotIn("numbers", failing(spoken, typed))
        self.assertEqual([n.value for n in numbers.extract("a hundred and first")], [101])
        self.assertEqual([n.value for n in numbers.extract("a hundred and twentieth")], [120])
        self.assertIn("numbers", failing(spoken, "It's 100th in the top 250."))

    def test_mixed_number_style_is_reported_never_gating(self):
        typed = "We need two minutes for setup and 30 minutes for the demo. It costs five dollars."
        report = checks.run_report_only("x", typed)
        self.assertEqual(report["mixed_number_style"]["kinds"], ["minute"])
        self.assertEqual(checks.noted(report), ["mixed_number_style"])
        self.assertTrue(checks.run_report_only("x", "We need 2 minutes and 30 minutes, five dollars.")["mixed_number_style"]["ok"])
        self.assertNotIn("mixed_number_style", checks.CHECK_NAMES)

    def test_a_leading_capital_after_an_interruption_is_not_a_name(self):
        spoken = "and wow and so uh right were um - Not right. Right is a backchannel and we are done here today"
        typed = "Wow and so and right were not right. Right is a backchannel and we are done here today."
        self.assertEqual(checks.run_checks(spoken, typed)["names"]["missing"], [])


class BatchTwoFixTests(unittest.TestCase):
    def test_round_hours_clock_marks_and_number_words(self):
        self.assertTrue(checks.check_numbers("seven o'clock and nine o'clock", "7:00 and 9:00", [], [])["ok"])
        self.assertTrue(checks.check_names("at 2 PM with Tom", "at 2 p.m. with Tom", [], [])["ok"])
        self.assertTrue(wordchecks.check_content_words_added("we had 4 fail in 10 minutes",
                                                              "four failed in ten minutes")["ok"])
        self.assertTrue(wordchecks.check_content_words_added("the rewards underscore v two underscore flag",
                                                              "the rewards_v2_flag")["ok"])

    def test_a_long_restart_counts_one_negation(self):
        spoken = "I don't want to push the, I don't want to push the episode because sales lose it"
        self.assertEqual(checks.negation_count(spoken, collapse=True), 1)
        self.assertEqual(failing(spoken, "I don't want to push the episode because sales lose it."), [])

    def test_taken_back_phrase_is_matched_in_place_not_as_loose_words(self):
        spoken = "there're two separate things we do uh at least two things matter and the separate budget is fine"
        corr = [{"said_first": "there're two separate things", "ended_on": "at least two"}]
        # "separate" and "things" occur legitimately elsewhere in the typed text; the phrase does not
        typed = "At least two things matter, and the separate budget is fine."
        self.assertNotIn("taken_back_residue", failing(spoken, typed, corr))
        left_in = "There are two separate things we do. At least two things matter and the separate budget is fine."
        self.assertIn("taken_back_residue", failing(spoken, left_in, corr))

    def test_a_one_word_taken_back_value_must_go_unless_said_again_after(self):
        corr = [{"said_first": "most important", "ended_on": "most probable"}]
        spoken = "it is most important no wait most probable that we ship"
        self.assertIn("taken_back_residue", failing(spoken, "It is most important that we ship.", corr))
        self.assertNotIn("taken_back_residue", failing(spoken, "It is most probable that we ship.", corr))
        again = "it is most important no wait most probable that we ship and the important part is the budget"
        self.assertNotIn("taken_back_residue", failing(again, "It is most probable that we ship, and the important part is the budget.", corr))

    def test_a_one_word_value_said_earlier_in_the_speech_may_stay(self):
        spoken = "there are different prices for each and there is an extra price in that sense sorry an extra cost in that sense"
        corr = [{"said_first": "an extra price in that sense", "ended_on": "an extra cost in that sense"}]
        typed = "There are different prices for each, and there is an extra cost in that sense."
        self.assertNotIn("taken_back_residue", failing(spoken, typed, corr))

    def test_fragments_in_said_first_do_not_make_phrases(self):
        corr = [{"said_first": "fancy mobi-", "ended_on": "remote controls"}]
        spoken = "we want fancy mobi- remote controls and a fancy look"
        self.assertNotIn("taken_back_residue", failing(spoken, "We want remote controls and a fancy look.", corr))

    def test_n_and_a_half_and_currency_with_a_scale_word(self):
        spoken = "it takes twelve and a half minutes and we want fifty million Euros for the twenty five Euro unit"
        typed = "It takes 12.5 minutes and we want €50 million for the €25 unit."
        found = checks.run_checks(spoken, typed)
        self.assertEqual((found["numbers"]["added"], found["numbers"]["missing"]), ([], []))
        self.assertTrue(found["names"]["ok"], found["names"])
        self.assertEqual([n.value for n in numbers.extract("one and a half hours and 3 million")], [1.5, 3000000])
        self.assertIn("numbers", failing(spoken, typed.replace("12.5", "12")))

    def test_two_spoken_words_written_as_one_and_function_prefixes(self):
        spoken = "it is wide screen and none of us knows whether the online thing works"
        typed = "It is widescreen, and none of us knows whether the non-online thing works."
        found = checks.run_checks(spoken, typed)["content_words_added"]
        self.assertTrue(found["ok"], found)
        self.assertIn("whether", wordchecks.FUNCTION_WORDS)
        self.assertIn("non", wordchecks.FUNCTION_WORDS)


def fake_writer(request):
    """A stand-in model: removes fillers and immediate repeats, capitalises."""
    content = request["messages"][0]["content"]
    spoken = re.search(r"<spoken>\n(.*?)\n</spoken>", content, re.S).group(1)
    out = []
    for word in spoken.split():
        if word.lower().strip(",.") in ("um", "uh"):
            continue
        if out and out[-1].lower().strip(",.") == word.lower().strip(",."):
            out.pop()
        out.append(word)
    typed = " ".join(out)
    typed = typed[:1].upper() + typed[1:]
    return {"typed": typed, "corrections": [], "unsure": [], "usable": True, "unusable_reason": ""}


def unsure(kind, quote="x", note="n"):
    return {"kind": kind, "quote": quote, "note": note}


PASSAGES = [
    {"id": "p1", "spoken": "um so the the meeting is on wednesday at three and uh bring the the laptop please "
                           "because we will demo it to Marta on Friday", "corpus": "TEST"},
    {"id": "p2", "spoken": "we should not ship on friday because the tests are are flaky and the docs "
                           "um are not done yet", "corpus": "TEST"},
    {"id": "p3", "spoken": "the budget is about forty five hundred dollars and uh we have to decide by "
                           "the end of the month who pays for the licences", "corpus": "TEST"}]


class WriterTestCase(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="retrain-writer-test-")
        self.addCleanup(self.temp.cleanup)
        self.dir = Path(self.temp.name).resolve()
        self.secret = tempfile.TemporaryDirectory(prefix="retrain-writer-key-")
        self.addCleanup(self.secret.cleanup)
        self.key_file = Path(self.secret.name) / "key"
        self.key_file.write_text(FAKE_KEY + "\n")
        self.key_file.chmod(0o600)
        patcher = patch.object(api_judge, "SLEEP", lambda s: None)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.passages = self.dir / "passages.jsonl"
        self.set_passages(PASSAGES)

    def set_passages(self, rows):
        self.passages.write_text("".join(json.dumps(r) + "\n" for r in rows))

    def server(self, answer=fake_writer, status=200, hook=None):
        def respond(index, request, headers):
            if hook:
                return hook(index, request, headers)
            return status, {}, message(answer(request))
        api = FakeApi(respond)
        self.addCleanup(api.close)
        return api

    def run_cli(self, *extra, server=None, out="run", command="write"):
        argv = [command, "--scratch-dir", str(self.dir), "--invented-or-public", "--out", str(self.dir / out)]
        if command == "write":
            argv += ["--passages", str(self.passages), "--state-dir", str(self.dir / "state"),
                     "--key-file", str(self.key_file), "--max-dollars", "5"]
            if server:
                argv += ["--base-url", server.url]
        argv += list(extra)
        stdout, stderr = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            code = writer.main(argv)
        return code, stdout.getvalue(), stderr.getvalue()

    def lines(self, name, out="run"):
        path = self.dir / f"{out}.{name}"
        return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]

    def everything_written(self):
        return "".join(p.read_text(errors="replace") for p in self.dir.rglob("*") if p.is_file())


class WriteRunTests(WriterTestCase):
    def test_good_rows_are_accepted_with_their_checks(self):
        api = self.server()
        code, out, _ = self.run_cli(server=api)
        self.assertEqual(code, 0, out)
        accepted = self.lines("accepted.jsonl")
        self.assertEqual([r["id"] for r in accepted], ["p1", "p2", "p3"])
        self.assertEqual(self.lines("quarantine.jsonl"), [])
        row = accepted[0]
        self.assertEqual(row["writer"]["instructions"], "typed-writer-v2")
        self.assertEqual(set(row["checks"]), set(checks.CHECK_NAMES))
        self.assertEqual(row["meta"]["corpus"], "TEST")
        self.assertEqual(len(api.requests), 3)

    def test_request_shape_and_blindness(self):
        api = self.server()
        self.run_cli(server=api, command="write")
        body = api.requests[0]
        self.assertEqual(body["model"], "claude-opus-5-5")
        self.assertEqual(body["output_config"]["format"]["type"], "json_schema")
        self.assertNotIn("tool_choice", body)
        self.assertNotIn("temperature", body)
        self.assertEqual([block["type"] for block in body["system"]], ["text"])
        self.assertIn("Writer version: typed-writer-v2", body["system"][0]["text"])
        self.assertIn("<spoken>", body["messages"][0]["content"])
        self.assertEqual(api.headers[0]["x-api-key"], FAKE_KEY)

    def test_bad_rows_are_quarantined_with_reasons_and_never_dropped_or_fixed(self):
        def answer(request):
            written = fake_writer(request)
            if "forty five hundred" in request["messages"][0]["content"]:
                written["typed"] = written["typed"].replace("forty five hundred", "$5,400")
            if "not ship" in request["messages"][0]["content"]:
                written["typed"] = written["typed"].replace("should not ship", "should ship")
            return written
        self.run_cli(server=self.server(answer))
        accepted, quarantined = self.lines("accepted.jsonl"), self.lines("quarantine.jsonl")
        self.assertEqual(len(accepted) + len(quarantined), 3)
        by_id = {r["id"]: r for r in quarantined}
        self.assertIn("check:numbers", by_id["p3"]["quarantine_reasons"])
        self.assertIn("$5,400", by_id["p3"]["typed"])  # kept as written
        self.assertIn("check:negation", by_id["p2"]["quarantine_reasons"])
        report = json.loads((self.dir / "run.report.json").read_text())
        self.assertEqual(report["per_check"]["numbers"]["failed"], 1)
        self.assertEqual(report["per_check"]["negation"]["failed"], 1)
        self.assertEqual(report["accepted"], 1)

    def test_unsure_kinds_are_in_the_schema_and_a_meaning_item_quarantines(self):
        api = self.server(lambda r: {**fake_writer(r), "unsure": [unsure("context"), unsure("meaning", "wednesday")]})
        self.run_cli(server=api)
        kinds = api.requests[0]["output_config"]["format"]["schema"]["properties"]["unsure"]["items"]["properties"]["kind"]
        self.assertEqual(kinds["enum"], ["context", "garbled", "meaning"])
        self.assertEqual(self.lines("accepted.jsonl"), [])
        self.assertIn("unsure:meaning", self.lines("quarantine.jsonl")[0]["quarantine_reasons"])
        self.assertEqual(json.loads((self.dir / "run.report.json").read_text())["unsure_by_kind"],
                         {"context": 3, "meaning": 3})

    def test_context_items_alone_do_not_quarantine(self):
        self.run_cli(server=self.server(lambda r: {**fake_writer(r), "unsure": [unsure("context")] * 3}))
        self.assertEqual(len(self.lines("accepted.jsonl")), 3)

    def test_two_garbled_items_set_the_row_aside_as_not_reading_as_typed(self):
        def answer(request):
            garbled = 2 if "Marta" in request["messages"][0]["content"] else 1
            return {**fake_writer(request), "unsure": [unsure("garbled")] * garbled}
        self.run_cli(server=self.server(answer))
        self.assertEqual(sorted(r["id"] for r in self.lines("accepted.jsonl")), ["p2", "p3"])
        aside = self.lines("not_typed.jsonl")
        self.assertEqual([r["id"] for r in aside], ["p1"])
        self.assertFalse(aside[0]["reads_as_typed"])
        self.assertEqual(aside[0]["quarantine_reasons"], [])
        self.assertEqual(self.lines("quarantine.jsonl"), [])
        report = json.loads((self.dir / "run.report.json").read_text())
        self.assertEqual((report["accepted"], report["quarantined"], report["not_typed"]), (2, 0, 1))

    def test_a_wrong_row_is_quarantined_even_when_it_is_also_garbled(self):
        def answer(request):
            written = fake_writer(request)
            return {**written, "typed": written["typed"].replace("wednesday", "thursday"), "unsure": [unsure("garbled")] * 2}
        self.run_cli(server=self.server(answer))
        self.assertIn("check:dates", self.lines("quarantine.jsonl")[0]["quarantine_reasons"])
        self.assertEqual(self.lines("not_typed.jsonl") and self.lines("not_typed.jsonl")[0]["id"] != "p1", True)

    def test_report_only_findings_are_recorded_without_quarantine(self):
        self.set_passages([{"id": "m1", "spoken": "um we need five minutes for the setup and thirty minutes for the demo"}])
        answer = {"typed": "We need five minutes for the setup and 30 minutes for the demo.", "corrections": [],
                  "unsure": [], "usable": True, "unusable_reason": ""}
        self.run_cli(server=self.server(lambda request: answer))
        row = self.lines("accepted.jsonl")[0]
        self.assertEqual(row["report_only_findings"], ["mixed_number_style"])
        report = json.loads((self.dir / "run.report.json").read_text())
        self.assertEqual(report["report_only"]["mixed_number_style"]["flagged"], 1)

    def test_writer_flag_unusable_goes_to_quarantine(self):
        def answer(request):
            return {**fake_writer(request), "usable": False, "unusable_reason": "needs unseen context"}
        self.run_cli(server=self.server(answer))
        self.assertEqual(self.lines("accepted.jsonl"), [])
        self.assertIn("writer_flagged_unusable", self.lines("quarantine.jsonl")[0]["quarantine_reasons"])

    def test_second_run_is_served_from_the_cache_without_calls(self):
        api = self.server()
        self.run_cli(server=api)
        count = len(api.requests)
        code, out, _ = self.run_cli(server=api, out="again")
        self.assertEqual(code, 0)
        self.assertEqual(len(api.requests), count)
        self.assertEqual(len(self.lines("accepted.jsonl", "again")), 3)

    def test_ledger_counts_tokens_and_dollars(self):
        self.run_cli(server=self.server())
        ledger = [json.loads(x) for x in (self.dir / "state" / "ledger.jsonl").read_text().splitlines()]
        reservations = [row for row in ledger if "reservation" in row]
        settled = [row for row in ledger if "settles" in row]
        self.assertEqual(len(reservations), len(settled))
        self.assertEqual(len(settled), 3)
        self.assertEqual({row["reservation"] for row in reservations}, {row["settles"] for row in settled})
        self.assertGreater(settled[0]["dollars"], 0)
        self.assertEqual(settled[0]["tool"], "retrain_writer")

    def test_cap_stops_before_the_call_that_could_exceed_it(self):
        api = self.server()
        code, _, _ = self.run_cli("--max-dollars", "0.0001", server=api)
        self.assertEqual(len(api.requests), 0)
        self.assertEqual(code, 3)
        self.assertEqual({r["error"] for r in self.lines("failed.jsonl")}, {"budget"})

    def test_write_requires_an_explicit_finite_cap(self):
        args = writer.parser().parse_args(["write", "--passages", "x", "--out", "y"])
        self.assertIsNone(args.max_dollars)
        for value in (None, float("nan"), float("inf"), 0, -1):
            args.max_dollars = value
            with self.assertRaises(writer.WriterError):
                writer.validate_spend_cap(args)

    def test_resume_ledger_blocks_calls_before_client_is_opened(self):
        ledger = api_judge.Ledger(self.dir / "state" / "ledger.jsonl")
        ledger.append({"dollars": 0.5})
        code, _, _ = self.run_cli("--max-dollars", "0.5")
        self.assertEqual(code, 3)
        self.assertEqual({row["error"] for row in self.lines("failed.jsonl")}, {"budget"})

    def test_malformed_answer_is_retried_once_then_listed_as_failed(self):
        api = self.server(hook=lambda i, r, h: (200, {}, message(None, text="not json")))
        code, _, _ = self.run_cli(server=api)
        self.assertEqual(code, 3)
        self.assertEqual(len(api.requests), 6)
        failed = self.lines("failed.jsonl")
        self.assertEqual(len(failed), 3)
        self.assertIn("malformed", failed[0]["error"])

    def test_bad_request_stops_the_run(self):
        error = {"type": "error", "error": {"type": "invalid_request_error", "message": "bad"}}
        api = self.server(hook=lambda i, r, h: (400, {}, error))
        code, _, err = self.run_cli(server=api)
        self.assertEqual(code, 2)
        self.assertEqual(len(api.requests), 1)

    def test_key_never_reaches_any_output(self):
        self.run_cli(server=self.server())
        self.assertNotIn(FAKE_KEY, self.everything_written())


class DryRunAndGuardTests(WriterTestCase):
    def test_resumed_dry_run_reports_spend_and_headroom(self):
        api_judge.Ledger(self.dir / "state" / "ledger.jsonl").append({"dollars": 0.25})
        code, out, _ = self.run_cli("--dry-run", "--max-dollars", "1")
        self.assertEqual(code, 0)
        self.assertIn("ledger so far $0.25", out)
        self.assertIn("remaining $0.75", out)

    def test_dry_run_counts_calls_and_estimates_cost_without_network_or_key(self):
        code, out, _ = self.run_cli("--dry-run", "--assume", "20", "500", "3000",
                                    "--key-file", str(self.dir / "no-such-key"))
        self.assertEqual(code, 0)
        self.assertIn("3 calls to make", out)
        self.assertRegex(out, r"500 passages .*typical \$\d+\.\d\d")
        self.assertIn("3000 passages", out)
        self.assertIn("key file was not opened", out)
        self.assertFalse((self.dir / "state").exists())

    def test_forbidden_input_and_output_paths_are_refused(self):
        bad = self.dir / "heldout-set.jsonl"
        bad.write_text(self.passages.read_text())
        self.passages = bad
        code, _, err = self.run_cli("--dry-run")
        self.assertEqual(code, 1)
        self.assertIn("forbidden", err)
        self.passages = self.dir / "passages.jsonl"
        code, _, err = self.run_cli("--dry-run", out="voice-lab-out")
        self.assertEqual(code, 0)  # a dry run writes nothing
        code, _, err = self.run_cli(out="voice-lab-out", server=self.server())
        self.assertEqual(code, 1)

    def test_outside_evals_and_scratch_is_refused(self):
        with tempfile.TemporaryDirectory() as other:
            outside = Path(other) / "p.jsonl"
            outside.write_text(self.passages.read_text())
            self.passages = outside
            code, _, err = self.run_cli("--dry-run")
        self.assertEqual(code, 1)
        self.assertIn("outside", err)

    def test_invented_or_public_flag_is_required(self):
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            code = writer.main(["write", "--scratch-dir", str(self.dir), "--passages", str(self.passages),
                                "--out", str(self.dir / "x"), "--dry-run"])
        self.assertEqual(code, 1)
        self.assertIn("invented-or-public", stderr.getvalue())

    def test_duplicate_ids_and_empty_text_are_input_errors(self):
        self.set_passages([PASSAGES[0], PASSAGES[0]])
        self.assertEqual(self.run_cli("--dry-run")[0], 1)
        self.set_passages([{"id": "x", "spoken": "  "}])
        self.assertEqual(self.run_cli("--dry-run")[0], 1)

    def test_validate_written_rejects_every_unguessable_shape(self):
        good = {"typed": "t", "corrections": [], "unsure": [], "usable": True, "unusable_reason": ""}
        self.assertEqual(writer.validate_written(good)["typed"], "t")
        for broken in ({**good, "extra": 1}, {k: v for k, v in good.items() if k != "typed"},
                       {**good, "usable": "yes"}, {**good, "corrections": [{"said_first": "a"}]},
                       {**good, "unsure": ["text"]}, {**good, "unsure": [{"quote": "a", "note": "b"}]},
                       {**good, "unsure": [{"kind": "other", "quote": "a", "note": "b"}]}, {**good, "typed": None}, "text", None):
            with self.assertRaises(VerdictError):
                writer.validate_written(broken)

    def test_instructions_file_is_versioned_and_holds_the_standard(self):
        text = writer.DEFAULT_INSTRUCTIONS.read_text()
        self.assertEqual(writer.instructions_version(text), "typed-writer-v2")
        for phrase in ("order of points", "paragraph", "self-correction", "usable", "unsure", "$4,200"):
            self.assertIn(phrase, text)


class RecheckTests(WriterTestCase):
    def test_check_command_reruns_checks_on_written_rows_without_api(self):
        self.run_cli(server=self.server())
        code, out, _ = self.run_cli("--rows", str(self.dir / "run.accepted.jsonl"), "--band-low", "0.99",
                                    command="check", out="rechecked")
        self.assertEqual(code, 0)
        self.assertEqual(len(self.lines("quarantine.jsonl", "rechecked")), 3)
        self.assertIn("check:length", self.lines("quarantine.jsonl", "rechecked")[0]["quarantine_reasons"])

    def test_check_command_reads_version_one_rows_and_several_files(self):
        old = [{"id": f"o{i}", "spoken": PASSAGES[i]["spoken"], "typed": fake_writer(
            {"messages": [{"content": "<spoken>\n" + PASSAGES[i]["spoken"] + "\n</spoken>"}]})["typed"],
            "corrections": [], "usable": True, "unusable_reason": "",
            "unsure": [{"quote": "q", "note": "n"}]} for i in range(2)]
        first, second = self.dir / "a.jsonl", self.dir / "b.jsonl"
        first.write_text(json.dumps(old[0]) + "\n")
        second.write_text(json.dumps(old[1]) + "\n")
        code, out, _ = self.run_cli("--rows", str(first), str(second), command="check", out="legacy")
        self.assertEqual(code, 0, out)
        rows = self.lines("accepted.jsonl", "legacy")
        self.assertEqual(len(rows), 2)
        self.assertEqual(rows[0]["unsure"][0]["kind"], "unclassified")


class PromptCacheTests(WriterTestCase):
    def brief(self):
        return writer.DEFAULT_INSTRUCTIONS.read_text(encoding="utf-8")

    def paid(self):
        rows = [json.loads(line) for line in (self.dir / "state" / "ledger.jsonl").read_text().splitlines()]
        return [row for row in rows if row.get("tool") == "retrain_writer"]

    def test_the_brief_is_sent_as_one_marked_block(self):
        api = self.server()
        self.assertEqual(self.run_cli(server=api)[0], 0)
        for body in api.requests:
            self.assertEqual(body["system"], [{"type": "text", "text": self.brief(), "cache_control": MARKER}])
            self.assertNotIn("cache_control", body)

    def test_the_switch_sends_the_plain_brief(self):
        api = self.server()
        self.assertEqual(self.run_cli("--no-prompt-cache", server=api)[0], 0)
        for body in api.requests:
            self.assertEqual(body["system"], self.brief())
            self.assertNotIn("cache_control", json.dumps(body))

    def test_ledger_rows_count_cache_tokens_and_the_run_prints_the_share(self):
        api = FakeApi(cache_aware(lambda request: message(fake_writer(request))))
        self.addCleanup(api.close)
        code, out, _ = self.run_cli("--workers", "3", server=api)
        self.assertEqual(code, 0, out)
        rows = self.paid()
        self.assertEqual(sorted(r["cache_write_tokens"] for r in rows), [0, 0, CACHED_PREFIX])
        self.assertEqual(sorted(r["cache_read_tokens"] for r in rows), [0, CACHED_PREFIX, CACHED_PREFIX])
        write = (AFTER_PREFIX * 4 + CACHED_PREFIX * 5 + OUTPUT * 20) / 1_000_000
        read = (AFTER_PREFIX * 4 + CACHED_PREFIX * 0.20 + OUTPUT * 20) / 1_000_000
        for row in rows:
            self.assertAlmostEqual(row["dollars"], write if row["cache_write_tokens"] else read)
        self.assertIn(f"retrain-writer: ${write + 2 * read:.4f} this run", out)
        self.assertIn("retrain-writer: prompt cache: 1400 of 3000 input tokens read from cache (46.7%), 700 written",
                      out)

    def test_rows_written_before_the_marker_are_not_asked_for_again(self):
        api = self.server()
        self.run_cli("--no-prompt-cache", server=api)
        self.assertEqual(len(api.requests), 3)
        code, out, _ = self.run_cli(server=api)
        self.assertEqual((code, len(api.requests)), (0, 3))
        self.assertIn("$0.0000 this run", out)
        body = writer.request_body("claude-opus-5-5", "Writer version: w1\nWrite.", "spoken words", 300)
        self.assertEqual(api_judge.cache_key("claude-opus-5-5", "w1", body),
                         "2afa44d431d8c733bcc038519280a61437546ca2d8311f55c2215f1126bd7a77")

    def test_dry_run_measures_the_brief_against_the_minimum(self):
        code, out, _ = self.run_cli("--dry-run")
        self.assertEqual(code, 0)
        self.assertRegex(out, r"prompt cache: prefix \(tools \+ system\) about \d+ tokens .* is 512: clears it; "
                              r"over 3 calls")
        estimate, cautious = client_module.cache_prefix_tokens(
            writer.request_body("claude-opus-5-5", self.brief(), "x", 100))
        self.assertGreater(cautious, client_module.CACHE_MIN_TOKENS["claude-opus-5-5"])
        self.assertGreater(estimate, cautious)


if __name__ == "__main__":
    unittest.main()
