#!/usr/bin/env python3
"""Token, marker and series rules for long-form extraction; fixture speech is invented."""

from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import retrain_longform_sources as sources  # noqa: E402

NLP_HEADER = "token|speaker|ts|endTs|punctuation|prepunctuation|case|tags\n"


def stretches(stream):
    return [(meeting, speaker, [item["word"] for item in tokens], [item["missing"] for item in tokens])
            for meeting, speaker, tokens in stream]


class TokenTests(unittest.TestCase):
    def test_numbers_stay_whole_with_their_signs(self):
        self.assertEqual(sources.words("It grew 2.5 to 10,000 then $100 and 75% at 3:05"),
                         ["it", "grew", "2.5", "to", "10,000", "then", "$100", "and", "75%", "at", "3:05"])
        self.assertEqual(sources.words("$1,250,000.75 €9 £2.5 -0.5% .9"), ["$1,250,000.75", "€9", "£2.5", "0.5%", ".9"])
        self.assertEqual(sources.words("2020. Next, 7, 8"), ["2020", "next", "7", "8"])
        self.assertEqual(sources.words("Q4 5G covid19 1st"), ["q4", "5g", "covid19", "1st"])
        self.assertEqual(sources.words("1,2 a,b 12,34"), ["1", "2", "a", "b", "12", "34"])

    def test_number_ranges_stay_whole(self):
        self.assertEqual(sources.words("4-5 2031-2032 $5-$10 10-15% 9-1-1 1.5-2.5"),
                         ["4-5", "2031-2032", "$5-$10", "10-15%", "9-1-1", "1.5-2.5"])
        self.assertEqual(sources.words("5-year lantern-19 5-10x 4- -7"), ["5", "year", "lantern", "19", "5", "10x", "4", "7"])

    def test_lost_speech(self):
        for token in ("%", "$", "€", "/", "+", "×", "*", "#", "and/or", "H7/H8", "amber@birch.com", "#1", "+5%",
                      "-5", "-0.5%", "-$9", "−3", "2031's", "3,45,000", "21,34%", "3,7", "sek3.75", "two.45",
                      "3:05pm", "401(k)", "7_K"):
            with self.subTest(token):
                self.assertTrue(sources.loses_speech(token))
        for token in ("lantern", "don't", "well-known", "'", "-", "--", "...", ",", '"', "u.s.", "birch&oak",
                      "Birch&amp;Oak", "L_C_D_", "2.5", "10,000", "$1,250,000.75", "75%", "3:05", ".9", "4-5", "10-15%",
                      "5-year", "lantern-19", "q4", "5g", "1st", "2031", "birch.com", "5-", "us$100"):
            with self.subTest(token):
                self.assertFalse(sources.loses_speech(token))

    def test_one_apostrophe_and_split_compounds(self):
        self.assertEqual(sources.words("Don’t say that's well-known"), ["don't", "say", "that's", "well", "known"])
        self.assertEqual(sources.words("Birch&amp;Oak L_C_D_"), ["birch", "oak", "l", "c", "d"])
        self.assertEqual(sources.words("% $ - ' ..."), [])

    def test_marker_kinds(self):
        for token in ("<inaudible>", "[inaudible]", "[INAUDIBLE]", "<unk>", "<crosstalk>", "(crosstalk)", "<foreign>",
                      "<phonetic>", "<mystery>", "[inaudible 00:12:01]"):
            with self.subTest(token):
                self.assertEqual(sources.marker_kind(token), "missing")
        for token in ("<laugh>", "[laughter]", "<silence>", "<cough>", "<clear_throat>", "<affirmative>", "<Laugh>"):
            with self.subTest(token):
                self.assertEqual(sources.marker_kind(token), "drop")
        for token in ("lantern", "th-", "$100", "<", "a<b>"):
            with self.subTest(token):
                self.assertIsNone(sources.marker_kind(token))

    def test_fragments(self):
        for token in ("th-", "lan-", "don't-", "Q4-"):
            self.assertTrue(sources.is_fragment(token), token)
        for token in ("well-known", "lantern", "-", "–", "$5-"):
            self.assertFalse(sources.is_fragment(token), token)

    def test_series(self):
        self.assertEqual(sources.series_of("ami", "ES2015a"), "ES2015")
        self.assertEqual(sources.series_of("ami", "ES2015d"), "ES2015")
        self.assertEqual(sources.series_of("ami", "IB4001"), "IB4001")
        self.assertEqual(sources.series_of("icsi", "Bmr007"), "Bmr")
        self.assertEqual(sources.series_of("icsi", "Bed012"), "Bed")
        self.assertEqual(sources.series_of("earnings21", "4320211"), "4320211")
        self.assertEqual(sources.series_of("earnings22", "invented-call-2020"), "invented-call-2020")


class StreamTests(unittest.TestCase):
    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.root = Path(folder.name)

    def nlp(self, tokens):
        (self.root / "call.nlp").write_text(NLP_HEADER + "".join(f"{token}|A||||||[]\n" for token in tokens))
        return stretches(sources.earnings_stream(self.root))

    def xml(self, folder, elements):
        (self.root / folder).mkdir()
        (self.root / folder / "Room1a.A.words.xml").write_text("<root>" + "".join(elements) + "</root>")
        return stretches(sources.meeting_stream(self.root))

    def test_earnings_markers_and_fragments(self):
        (_, _, words, missing), = self.nlp(["Amber", "<laugh>", "lan-", "lantern", "<inaudible>", "glows", "[inaudible]",
                                            "<unk>", "at", "$2.5", "<crosstalk>"])
        self.assertEqual(words, ["amber", "lantern", "glows", "at", "$2.5"])
        self.assertEqual(missing, [False, True, True, False, True])

    def test_earnings_sign_written_apart_or_broken_number_marks_missing(self):
        (_, _, words, missing), = self.nlp(["amber", "4-5", "%", "lantern", "1", "/", "3", "glows", "$", "2.5", "now",
                                            "2031's", "birch", "-5", "cedar", "'", "21", "-", "well-known", "birch&oak"])
        self.assertEqual(words, ["amber", "4-5", "lantern", "1", "3", "glows", "2.5", "now", "2031", "s", "birch", "5",
                                 "cedar", "21", "well", "known", "birch", "oak"])
        self.assertEqual(missing, [False, True, False, True, False, True, False, False, True, False, False, True,
                                   False, False, False, False, False, False])

    def test_earnings_prefix_written_apart_from_its_word_is_kept(self):
        # "non- glowing" is the word "non-glowing"; "re- reuse" and "th- the" are cut-off starts.
        (_, _, words, missing), = self.nlp(["amber", "non-", "glowing", "lantern", "re-", "reuse", "Pre-", "th-", "the",
                                            "cedar", "post-"])
        self.assertEqual(words, ["amber", "non", "glowing", "lantern", "reuse", "pre", "the", "cedar", "post"])
        self.assertEqual(missing, [False] * 9)
        self.assertEqual(sources.detached_prefix("non-", "glowing"), "non")
        self.assertIsNone(sources.detached_prefix("re-", "Reuse"))
        self.assertIsNone(sources.detached_prefix("lan-", "glowing"))
        self.assertIsNone(sources.detached_prefix("non", "glowing"))

    def test_earnings_marker_before_the_first_word_marks_it(self):
        (_, _, words, missing), = self.nlp(["<inaudible>", "amber", "lantern"])
        self.assertEqual((words, missing), (["amber", "lantern"], [True, False]))
        (_, _, words, missing), = self.nlp(["<silence>", "amber", "lantern", "<laugh>"])
        self.assertEqual((words, missing), (["amber", "lantern"], [False, False]))

    def test_ami_gap_truncation_and_sounds(self):
        timed = lambda i: f'starttime="{i * .2:.1f}" endtime="{i * .2 + .1:.1f}"'
        (meeting, speaker, words, missing), = self.xml("words", [
            f'<w {timed(0)}>Amber</w>', f'<vocalsound {timed(1)} type="laugh"/>', f'<w {timed(2)} trunc="true">lan</w>',
            f'<w {timed(3)}>lantern</w>', f'<gap {timed(4)}/>', f'<w {timed(5)}>glows</w>', f'<disfmarker {timed(6)}/>',
            f'<w {timed(7)}>here</w>', f'<transformerror {timed(8)} errortype="x" w="y"/>', f'<w {timed(9)}>now</w>',
            f'<w {timed(10)} punc="true">.</w>'])
        self.assertEqual((meeting, speaker), ("Room1a", "A"))
        self.assertEqual(words, ["amber", "lantern", "glows", "here", "now"])
        self.assertEqual(missing, [False, True, False, True, False])

    def test_icsi_classes_comments_and_clitics(self):
        timed = lambda i: f'starttime="{i * .2:.1f}" endtime="{i * .2 + .1:.1f}"'
        (_, _, words, missing), = self.xml("Words", [
            f'<w {timed(0)} c="W">The</w>', f'<w {timed(1)} c="W">lantern</w>', f'<w {timed(1)} c="APOSS">\'s</w>',
            f'<w {timed(2)} c="TRUNCW">gl</w>', f'<w {timed(3)} c="W">glow</w>', f'<w {timed(4)} c="SYM">@</w>',
            f'<w {timed(4)} c="SYM">@</w>', f'<w {timed(5)} c="W">fades</w>', f'<w {timed(6)} c="HYPH">-</w>',
            f'<w {timed(7)} c="W">slowly</w>', f'<comment {timed(8)} description="Censored"/>',
            f'<w {timed(9)} c="W">tonight</w>', f'<comment {timed(10)} description="while laughing"/>',
            f'<vocalsound {timed(11)} description="laugh"/>', f'<nonvocalsound {timed(12)} description="mike noise"/>',
            f'<w {timed(13)} c="W">again</w>', f'<w {timed(13)} c=".">.</w>'])
        self.assertEqual(words, ["the", "lantern's", "glow", "fades", "slowly", "tonight", "again"])
        self.assertEqual(missing, [False, False, True, False, True, False, False])

    def test_icsi_words_without_a_time_are_kept_and_clitics_join_their_host(self):
        # ICSI times only some word edges: a host and its clitic share one span, and whole runs carry no time.
        word = lambda text, start="", end="", c="W": f'<w starttime="{start}" endtime="{end}" c="{c}">{text}</w>'
        (_, _, words, missing), = self.xml("Words", [
            word("Amber", 0.0, 0.2), word("lantern", 0.2), word("'s", end=0.5, c="APOSS"), word("they", 0.5),
            word("'re", end=0.8), word("glowing"), word("G", 0.8, c="LET"), word("-", c="HYPH"), word("lamp", end=1.1),
            word("I"), word("'ve"), word("here", 1.1, 1.3), word(".", 1.3, 1.3, c=".")])
        self.assertEqual(words, ["amber", "lantern's", "they're", "glowing", "g", "lamp", "i've", "here"])
        self.assertEqual(missing, [False] * 8)

    def test_a_long_silence_still_breaks_a_stretch_that_holds_untimed_words(self):
        word = lambda text, start="", end="", c="W": f'<w starttime="{start}" endtime="{end}" c="{c}">{text}</w>'
        first, second = self.xml("Words", [word("amber", 0.0, 0.2), word("lantern"), word("glows", 5.0, 5.2),
                                           word("here")])
        self.assertEqual((first[2], second[2]), (["amber", "lantern"], ["glows", "here"]))

    def test_icsi_clitic_never_joins_an_earlier_word(self):
        word = lambda text, start="", end="", c="W": f'<w starttime="{start}" endtime="{end}" c="{c}">{text}</w>'
        (_, _, words, _), = self.xml("Words", [
            word("amber", 0.0, 0.2), word("lan", 0.2, 0.3, c="TRUNCW"), word("'s", end=0.4, c="APOSS"),
            word("glows", 0.4, 0.6), '<disfmarker/>', word("'re", end=0.7), word("birch", 0.7, 0.9),
            word('"', c="RQUOTE"), word("'s", end=1.0, c="APOSS"), word("'s", end=1.1, c="APOSS"),
            word("cedar", 1.1, 1.3), word("'ve", end=1.4), word("'ve", end=1.5), word("'d", end=1.6)])
        self.assertEqual(words, ["amber", "glows", "birch's", "cedar've'd"])

    def test_icsi_read_out_digits_mark_the_stretch(self):
        word = lambda text, start="", end="", c="W": f'<w starttime="{start}" endtime="{end}" c="{c}">{text}</w>'
        (_, _, words, missing), = self.xml("Words", [
            word("amber", 0.0, 0.2), word("lantern", 0.2, 0.4), '<comment description="Digits"/>', word("nine"),
            word("O", c="LET"), word("two"), '<comment description="Digits"/>', word("four"), word("glows", 1.0, 1.2)])
        self.assertEqual(words, ["amber", "lantern", "nine", "o", "two", "four", "glows"])
        self.assertEqual(missing, [False, True, True, False, True, True, False])

    def test_ami_word_that_starts_with_an_apostrophe_is_a_word(self):
        timed = lambda i: f'starttime="{i * .2:.1f}" endtime="{i * .2 + .1:.1f}"'
        (_, _, words, _), = self.xml("words", [f'<w {timed(0)}>amber</w>', f"<w {timed(1)}>'cause</w>",
                                               "<w>'kay</w>", f'<w {timed(3)}>lantern</w>'])
        self.assertEqual(words, ["amber", "cause", "kay", "lantern"])

    def test_icsi_clitic_with_nothing_before_it_is_dropped(self):
        timed = lambda i: f'starttime="{i * .2:.1f}" endtime="{i * .2 + .1:.1f}"'
        (_, _, words, _), = self.xml("Words", [f'<w {timed(0)} c="APOSS">\'s</w>', f'<w {timed(1)} c="W">amber</w>'])
        self.assertEqual(words, ["amber"])


if __name__ == "__main__":
    unittest.main()
