#!/usr/bin/env python3
"""Offline tests for the passage miner, on small invented files in the AMI and ICSI formats.
No corpus text is used; the formats are documented in scripts/retrain_corpora.py."""
import contextlib
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))

import retrain_corpora as corpora  # noqa: E402
import retrain_features as features  # noqa: E402
import retrain_mine  # noqa: E402
import retrain_passages as passages  # noqa: E402
import retrain_stats as stats  # noqa: E402

HEADER = '<?xml version="1.0" encoding="ISO-8859-1" standalone="yes"?>\n<nite:root xmlns:nite="x">\n'


def ami_words(obs, agent, items, start=10.0, step=0.3):
    """items: strings; "," "." "?" become punc tokens; "~x" a truncated word; "|" a disfmarker; "!gap".
    Returns (xml, ids) where ids[i] is the nite:id of items[i]."""
    lines, ids, t = [], [], start
    for n, item in enumerate(items):
        word_id = f"{obs}.{agent}.words{n}"
        ids.append(word_id)
        if item in (",", ".", "?"):
            lines.append(f'<w nite:id="{word_id}" starttime="{t:.2f}" endtime="{t:.2f}" punc="true">{item}</w>')
            continue
        if item == "|":
            lines.append(f'<disfmarker nite:id="{word_id}" starttime="{t:.2f}" endtime="{t:.2f}"/>')
            continue
        if item == "!gap":
            lines.append(f'<gap nite:id="{word_id}" starttime="{t:.2f}" endtime="{t:.2f}"/>')
            continue
        if item == "!laugh":
            lines.append(f'<vocalsound nite:id="{word_id}" starttime="{t:.2f}" endtime="{t:.2f}" type="laugh"/>')
            continue
        trunc = ' trunc="true"' if item.startswith("~") else ""
        lines.append(f'<w nite:id="{word_id}" starttime="{t:.2f}" endtime="{t + 0.25:.2f}"{trunc}>{item.lstrip("~")}</w>')
        t += step
    return HEADER + "\n".join(lines) + "\n</nite:root>\n", ids


def sentences(count, words_per=10, prefix="w"):
    """count sentences of invented words, as AMI items."""
    items = []
    for s in range(count):
        items += [f"{prefix}{s}x{k}" for k in range(words_per)] + ["."]
    return items


class AmiParsingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "words").mkdir()
        (self.root / "disfluency").mkdir()
        (self.root / "corpusResources").mkdir()
        (self.root / "corpusResources" / "meetings.xml").write_text(
            '<root><meeting nite:id="m1" observation="T1000a" type="scenario">'
            '<speaker nite:id="s1" channel="0" nxt_agent="A" global_name="MXX001" role="PM"/>'
            '<speaker nite:id="s2" channel="1" nxt_agent="B" global_name="FXX002" role="ID"/></meeting></root>')

    def write(self, agent, items, **kw):
        xml, ids = ami_words("T1000a", agent, items, **kw)
        (self.root / "words" / f"T1000a.{agent}.words.xml").write_text(xml, encoding="iso-8859-1")
        return ids

    def test_conventions_are_applied(self):
        ids = self.write("A", ["So", ",", "I", "went", "to", "~th", "to", "!laugh", "the", "D_V_D_", "!gap",
                               "|", "store", "."])
        meeting = corpora.load_ami(self.root)[0]
        text = " ".join(t.text for t in meeting.speakers["MXX001"][0].tokens)
        self.assertEqual(text, "So, I went to th- to the DVD - store.")
        self.assertEqual(meeting.speakers["MXX001"][0].gaps, 1)
        self.assertEqual(ids[0], "T1000a.A.words0")

    def test_corpus_names_cannot_escape_root(self):
        self.write("A", ["safe", "."])
        outside = self.root.parent / (self.root.name + "-outside.xml")
        outside.write_text("outside")
        self.addCleanup(outside.unlink)
        (self.root / "words" / "T1000a.B.words.xml").symlink_to(outside)
        meetings = self.root / "corpusResources" / "meetings.xml"
        meetings.write_text(meetings.read_text().replace('nxt_agent="B"', 'nxt_agent="../B"'))
        counts = {}
        result = corpora.load_ami(self.root, stats=counts)
        self.assertEqual(set(result[0].speakers), {"MXX001"})
        self.assertEqual(counts["unsafe_corpus_paths"], 1)
        meetings.write_text(meetings.read_text().replace('nxt_agent="../B"', 'nxt_agent="B"'))
        counts = {}
        corpora.load_ami(self.root, stats=counts)
        self.assertEqual(counts["unsafe_corpus_paths"], 1)
        (self.root / "words" / "T1000a.B.words.xml").unlink()
        (self.root / "words" / "T1000a.B.words.xml").symlink_to("T1000a.B.words.xml")
        counts = {}
        corpora.load_ami(self.root, stats=counts)
        self.assertEqual(counts["unsafe_corpus_paths"], 1)
        meetings.write_text(meetings.read_text().replace('observation="T1000a"', 'observation="../T1000a"'))
        counts = {}
        self.assertEqual(corpora.load_ami(self.root, stats=counts), [])
        self.assertEqual(counts["unsafe_corpus_paths"], 2)

    def test_dashes_can_be_dropped(self):
        self.write("A", ["a", "b", "|", "c", "."])
        text = " ".join(t.text for t in corpora.load_ami(self.root, keep_dashes=False)[0].speakers["MXX001"][0].tokens)
        self.assertEqual(text, "a b c.")

    def test_disfluency_layer_roles(self):
        ids = self.write("A", ["we", "go", "um", "to", "to", "the", "shop", "."])
        links = lambda *i: "".join(f'<nite:child href="T1000a.A.words.xml#id({ids[k]})"/>' for k in i)  # noqa: E731
        layer = (HEADER + f'<dsfl nite:id="d1"><nite:pointer role="dsfl-type" href="dsfl-types.xml#id(ami_dsfl_5)"/>'
                 f'{links(2)}</dsfl>'
                 f'<dsfl nite:id="d2"><nite:pointer role="dsfl-type" href="dsfl-types.xml#id(ami_dsfl_12)"/>'
                 f'{links(3)}</dsfl>'
                 f'<dsfl nite:id="d3"><nite:pointer role="dsfl-type" href="dsfl-types.xml#id(ami_dsfl_18)"/>'
                 f'{links(4)}</dsfl></nite:root>')
        (self.root / "disfluency" / "T1000a.A.disfluency.xml").write_text(layer)
        meeting = corpora.load_ami(self.root)[0]
        roles = {t.text: t.roles for t in meeting.speakers["MXX001"][0].tokens}
        self.assertEqual(roles["um"], ("filler:hesit",))
        tokens = meeting.speakers["MXX001"][0].tokens
        self.assertEqual(tokens[3].roles, ("taken_back:repeat",))
        self.assertEqual(tokens[4].roles, ("repair",))
        self.assertIn("MXX001", meeting.covered_speakers)
        self.assertNotIn("FXX002", meeting.covered_speakers)

    def test_long_pause_splits_units(self):
        self.write("A", ["one", "two", "three", "."])
        xml, _ = ami_words("T1000a", "A", ["four", "five", "."], start=40.0)
        text = (self.root / "words" / "T1000a.A.words.xml").read_text(encoding="iso-8859-1")
        merged = text.replace("</nite:root>", xml.split("<nite:root xmlns:nite=\"x\">\n")[1])
        (self.root / "words" / "T1000a.A.words.xml").write_text(merged, encoding="iso-8859-1")
        units = corpora.load_ami(self.root)[0].speakers["MXX001"]
        self.assertEqual(len(units), 2)


MRT = """<?xml version="1.0" encoding="iso-8859-1"?>
<Meeting Session="Txx001"><Transcript StartTime="0.0" EndTime="100.0">
{segments}
</Transcript></Meeting>
"""


def segment(start, end, who, text, extra=""):
    return f'<Segment StartTime="{start}" EndTime="{end}" Participant="{who}"{extra}>\n  {text}\n</Segment>\n'


class IcsiParsingTests(unittest.TestCase):
    def test_icsi_reads_the_checked_resolved_path(self):
        with tempfile.TemporaryDirectory() as root_dir:
            root = Path(root_dir)
            target = root / "target.txt"
            target.write_text(MRT.format(segments=segment(1, 2, "me001", "safe words.")))
            link = root / "meeting.mrt"
            link.symlink_to(target)
            with patch.object(corpora, "read_text", wraps=corpora.read_text) as read:
                corpora.load_icsi(root)
            self.assertEqual(read.call_args.args[0], target.resolve())

    def test_symlink_outside_corpus_is_skipped_and_counted(self):
        with tempfile.TemporaryDirectory() as root_dir, tempfile.TemporaryDirectory() as outside_dir:
            root = Path(root_dir)
            (root / "safe.mrt").write_text(MRT.format(segments=segment(1, 2, "me001", "safe words.")))
            outside = Path(outside_dir) / "outside.mrt"
            outside.write_text(MRT.format(segments=segment(1, 2, "me002", "outside words.")))
            (root / "escape.mrt").symlink_to(outside)
            stats = {}
            meetings = corpora.load_icsi(root, stats=stats)
            self.assertEqual([meeting.meeting_id for meeting in meetings], ["safe"])
            self.assertEqual(stats["unsafe_corpus_paths"], 1)

    def load(self, *segments):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        (Path(temp.name) / "Txx001.mrt").write_text(MRT.format(segments="".join(segments)), encoding="iso-8859-1")
        return corpora.load_icsi(temp.name)[0]

    def test_conventions_are_applied(self):
        meeting = self.load(
            segment(1.0, 4.0, "me001", 'O_K, so I was - th- <Emphasis> really </Emphasis> late. <VocalSound Description="laugh"/> '
                    '<Pause/> It&apos;s <Uncertain> fine </Uncertain>, <Uncertain NumSyllables="2"> @@ </Uncertain> '
                    '<Pronounce Pronunciation="x"> gonna </Pronounce> go.'),
            segment(5.0, 6.0, "me001", 'Name is <Comment Description="Censored"/> here.'),
            segment(7.0, 9.0, "me002", "one two three", ' DigitTask="true"'),
            segment(10.0, 12.0, "me002", "four five six seven"),
            segment(13.0, 14.0, "me002", "Hello there."))
        first = meeting.speakers["me001"][0]
        self.assertEqual(" ".join(t.text for t in first.tokens),
                         "OK, so I was - th- really late. It's fine, gonna go.")
        self.assertEqual(first.unintelligible, 1)
        self.assertEqual(meeting.speakers["me001"][1].censored, 1)
        self.assertEqual([u.start for u in meeting.speakers["me002"]], [13.0])  # digit readings dropped

    def test_segments_without_a_participant_are_dropped(self):
        meeting = self.load('<Segment StartTime="1.0" EndTime="2.0" CloseMic="x">\n lost\n</Segment>\n',
                            segment(3.0, 4.0, "me001", "kept words here."))
        self.assertEqual(list(meeting.speakers), ["me001"])


def unit(speaker, start, end, text):
    return corpora.Unit(speaker, start, end, [corpora.Token(w) for w in text.split()])


def speech(n, prefix="w"):
    """n invented words forming one sentence that starts with a capital and ends with a full stop."""
    return " ".join(f"{prefix.capitalize() if i == 0 else prefix}{i}" for i in range(n - 1)) + f" {prefix}end."


class ChainTests(unittest.TestCase):
    def meeting(self, units_by_speaker):
        meeting = corpora.Meeting("TEST", "m1")
        meeting.speakers = units_by_speaker
        return meeting

    def mine(self, units_by_speaker):
        return passages.mine_meeting(self.meeting(units_by_speaker), (set(), set()))

    def test_joins_across_a_backchannel_and_a_short_gap(self):
        a = [unit("A", 0, 20, speech(60, "x")), unit("A", 22, 40, speech(60, "y"))]
        b = [unit("B", 21, 21.5, "yeah right")]
        found = self.mine({"A": a, "B": b})
        self.assertEqual(len(found), 1)
        self.assertEqual(found[0]["words"], 120)
        self.assertEqual(found[0]["intrusion"]["words"], 2)
        self.assertNotIn("yeah", found[0]["text"])

    def test_a_long_turn_by_someone_else_breaks_the_chain(self):
        a = [unit("A", 0, 20, speech(110, "x")), unit("A", 30, 50, speech(110, "y"))]
        b = [unit("B", 21, 29, speech(30, "b"))]
        found = self.mine({"A": a, "B": b})
        self.assertEqual(sorted(p["words"] for p in found), [110, 110])

    def test_a_large_gap_breaks_the_chain(self):
        a = [unit("A", 0, 20, speech(110, "x")), unit("A", 40, 60, speech(110, "y"))]
        self.assertEqual(len(self.mine({"A": a})), 2)

    def test_short_stretches_are_dropped(self):
        self.assertEqual(self.mine({"A": [unit("A", 0, 5, speech(99))]}), [])
        self.assertEqual(len(self.mine({"A": [unit("A", 0, 5, speech(100))]})), 1)

    def test_long_chain_is_cut_at_sentence_ends_into_100_to_280_word_pieces(self):
        sentences_ = [unit("A", i * 4, i * 4 + 3, speech(20, f"s{i}")) for i in range(40)]  # 800 words
        found = self.mine({"A": sentences_})
        self.assertTrue(found)
        for piece in found:
            self.assertTrue(100 <= piece["words"] <= 280, piece["words"])
            self.assertTrue(piece["text"].rstrip().endswith("."))
        self.assertEqual(len({p["id"] for p in found}), len(found))
        self.assertGreaterEqual(sum(p["words"] for p in found), 800 - 100)

    def test_cross_talk_inside_a_piece_rejects_it(self):
        a = [unit("A", 0, 30, speech(150, "x"))]
        b = [unit("B", 5, 25, speech(20, "b"))]
        rejected = {}
        found = passages.mine_meeting(self.meeting({"A": a, "B": b}), (set(), set()), rejected)
        self.assertEqual(found, [])
        self.assertEqual(rejected["cross_talk"], 1)

    def test_passage_carries_the_ami_layer_marks(self):
        tokens = [corpora.Token("Start")] + [corpora.Token(f"w{i}") for i in range(97)]
        tokens += [corpora.Token("um", ("filler:hesit",)), corpora.Token("to", ("taken_back:repeat",)),
                   corpora.Token("to.", ("repair",))]
        meeting = self.meeting({"A": [corpora.Unit("A", 0, 20, tokens)]})
        meeting.corpus = "AMI"
        meeting.covered_speakers = frozenset({"A"})
        layer = passages.mine_meeting(meeting, (set(), set()))[0]["ami_layer"]
        self.assertTrue(layer["covered"])
        self.assertEqual(layer["taken_back"], [{"i": 99, "word": "to", "type": "repeat"}])
        self.assertEqual((layer["repairs"], layer["fillers_marked"]), (1, 1))


class TrimmingTests(ChainTests):
    def test_leading_fragment_and_trailing_fragment_are_trimmed_to_sentence_boundaries(self):
        lead = unit("A", 0, 3, "and then we went to the")           # starts in lower case: mid-sentence
        middle = unit("A", 4, 20, "Done now. " + speech(120, "k"))
        tail = unit("A", 21, 23, "Is that")                        # unfinished
        found = self.mine({"A": [lead, middle, tail]})
        self.assertEqual(len(found), 1)
        self.assertTrue(found[0]["text"].startswith("K0"))
        self.assertTrue(found[0]["text"].endswith("kend."))
        self.assertNotIn("Is that", found[0]["text"])
        self.assertEqual(found[0]["words"], 120)

    def test_trimming_below_the_floor_drops_the_stretch(self):
        found = self.mine({"A": [unit("A", 0, 5, "tail of a sentence."), unit("A", 6, 10, speech(95, "j"))]})
        self.assertEqual(found, [])

    def test_a_cut_word_with_a_full_stop_does_not_end_a_sentence(self):
        self.assertFalse(passages.is_sentence_final("th-."))
        self.assertFalse(passages.is_sentence_final("-?"))
        self.assertTrue(passages.is_sentence_final('"right".'))
        self.assertTrue(passages.starts_sentence("um"))
        self.assertFalse(passages.starts_sentence("and"))

    def test_trimmed_words_are_counted(self):
        counts = {}
        units = [unit("A", 0, 3, "and then we went to the"), unit("A", 4, 20, "Done now. " + speech(120, "k")),
                 unit("A", 21, 23, "Is that")]
        passages.mine_meeting(self.meeting({"A": units}), (set(), set()), counts)
        self.assertEqual(counts["trimmed_words"], 8 + 2)  # "and then ... Done now." and "Is that"


class FeatureTests(unittest.TestCase):
    def test_feature_counts(self):
        text = "Um so I went on Tuesday at twenty five past three, no wait, four, and I I did not see Sarah."
        found = features.passage_features(text.split(), text, {"sarah"}, {"sarah"})
        self.assertEqual(found["hesitations"], 1)
        self.assertEqual(found["repeats"], 1)
        self.assertEqual(found["dates"], 1)
        self.assertGreaterEqual(found["numbers"], 3)
        self.assertEqual(found["explicit_self_correction"], 1)
        self.assertEqual(found["numeric_correction_cue"], 1)
        self.assertEqual(found["pii"]["person_name"], 1)

    def test_personal_data_cues(self):
        text = "my number is 0 7 7 one two three four five six seven and my knee hurts and I owe him rent at 5 Oak Street"
        pii = features.personal_data(text, set(), text.split())
        self.assertGreaterEqual(pii["phone"], 1)
        self.assertEqual(pii["health"], 1)
        self.assertEqual(pii["address"], 1)
        self.assertEqual(pii["money_personal"], 1)

    def test_mask_names_is_consistent_and_leaves_other_words(self):
        masked = features.mask_names("Thanks Adam, Adam said Bob agreed with Adam.", {"adam", "bob"}, "k")
        self.assertNotIn("Adam", masked)
        self.assertNotIn("Bob", masked)
        names = [w.strip(",.") for w in masked.split() if w[0].isupper() and w != "Thanks"]
        self.assertEqual(len(set(names)), 2)

    def test_lexicon_finds_vocatives(self):
        lists = [("so thanks Adam . Adam can you go ? hi Adam , we met Berkeley people in Berkeley and Berkeley").split()
                 for _ in range(3)]
        proper, names = features.derive_lexicons(lists)
        self.assertIn("adam", names)
        self.assertNotIn("berkeley", names)


def row(corpus, speaker, meeting, words, **extra):
    base = {"id": f"{corpus}-{meeting}-{speaker}", "corpus": corpus, "meeting": meeting, "speaker": speaker,
            "words": words, "text": "t", "flags": {"gaps": 0, "unintelligible": 0, "foreign": 0, "censored": 0},
            "intrusion": {"words": 0, "events": 0, "longest": 0, "overlap_fraction": 0.0}, "monologue_score": 0.9,
            "features": {"filler_per100": 3.0, "hesitations": 3, "repeats": 1, "fragments": 1, "numbers": 0, "dates": 0,
                         "names": 0, "explicit_self_correction": 0, "numeric_correction_cue": 0, "i_mean": 0,
                         "cues": {"you_per100": 0.0, "questions_per100": 0.0, "first_person_per100": 5.0},
                         "pii": {k: 0 for k in stats.PII_KINDS}}}
    base.update(extra)
    return base


class SelectionAndSampleTests(unittest.TestCase):
    def rows(self):
        out = []
        for i in range(30):
            out.append(row("AMI" if i % 2 else "ICSI", f"s{i % 7}", f"m{i % 11}", 100 + 20 * (i % 9),
                           ami_layer={"covered": False, "taken_back": [], "fillers_marked": 0, "repairs": 0}))
        return out

    def test_sample_is_deterministic_and_varied(self):
        a = stats.sample_varied(self.rows(), 20, seed=5)
        b = stats.sample_varied(self.rows(), 20, seed=5)
        self.assertEqual([r["id"] for r in a], [r["id"] for r in b])
        self.assertEqual(len(a), 20)
        self.assertNotEqual([r["id"] for r in a], [r["id"] for r in stats.sample_varied(self.rows(), 20, seed=6)])
        self.assertEqual({r["corpus"] for r in a}, {"AMI", "ICSI"})

    def test_select_filters(self):
        rows = self.rows()
        rows[0]["features"]["cues"]["you_per100"] = 9.0
        rows[1]["features"]["pii"]["person_name"] = 2
        rows[2]["flags"]["gaps"] = 1
        chosen = stats.select(rows, exclude_pii=("person_name",))
        ids = {r["id"] for r in chosen}
        self.assertNotIn(rows[0]["id"], ids)
        self.assertNotIn(rows[1]["id"], ids)
        self.assertNotIn(rows[2]["id"], ids)
        self.assertEqual(len(stats.select(rows, monologue=False, allow_flags=True)), 30)

    def test_caps_limit_passages_per_meeting_and_speaker_deterministically(self):
        rows = [row("AMI", "s1", "ES2002a", 120, id=f"r{i}") for i in range(10)] + \
               [row("AMI", f"t{i}", "ES2002b", 120, id=f"q{i}") for i in range(10)]
        for r in rows:
            r["start"] = 1.0
        kept = stats.apply_caps(rows, per_meeting=3, per_speaker=2, seed=1)
        self.assertEqual(sum(1 for r in kept if r["meeting"] == "ES2002a"), 2)   # the speaker cap bites first
        self.assertEqual(sum(1 for r in kept if r["meeting"] == "ES2002b"), 3)   # the meeting cap
        self.assertEqual([r["id"] for r in kept], [r["id"] for r in stats.apply_caps(rows, 3, 2, 1)])
        self.assertEqual(len(stats.apply_caps(rows, 0, 0, 1)), 20)

    def test_meeting_groups_and_cap_summary(self):
        rows = [row("AMI", "a", "EN2001a", 120), row("AMI", "b", "ES2002a", 120), row("ICSI", "c", "Bro004", 120),
                row("AMI", "d", "IB4010", 120)]
        self.assertEqual([stats.meeting_group(r) for r in rows],
                         ["AMI non-scenario (EN/IB/IN)", "AMI scenario (ES/IS/TS)", "ICSI Bro (Robustness)",
                          "AMI non-scenario (EN/IB/IN)"])
        summary = stats.cap_summary(rows, rows[:2])
        self.assertEqual(summary["before_caps"]["passages"], 4)
        self.assertEqual(summary["after_caps"]["groups"]["AMI scenario (ES/IS/TS)"]["meetings"], 1)

    def test_sample_spreads_over_meeting_groups(self):
        rows = [row("AMI", f"s{i}", f"ES20{i:02d}a", 120, id=f"sc{i}") for i in range(12)] + \
               [row("AMI", f"n{i}", f"EN20{i:02d}a", 120, id=f"en{i}") for i in range(12)] + \
               [row("ICSI", f"m{i}", f"Bro{i:03d}", 120, id=f"ic{i}") for i in range(12)]
        picked = stats.sample_varied(rows, 9, seed=3)
        self.assertEqual(sorted({r["id"][:2] for r in picked}), ["en", "ic", "sc"])

    def test_stats_report_shares_and_ami_coverage(self):
        rows = self.rows()
        rows[1]["ami_layer"] = {"covered": True, "taken_back": [{"i": 1, "word": "x", "type": "restart"}],
                                "fillers_marked": 0, "repairs": 1}
        result = stats.build_stats(rows)
        self.assertEqual(result["all"]["passages"], 30)
        self.assertEqual(result["ami_layer"]["covered_by_disfluency_layer"], 1)
        self.assertEqual(result["ami_layer"]["covered_with_replace_or_restart"], 1)
        self.assertIn("AMI 100-150", result["by_corpus_and_length"])


class CommandLineTests(unittest.TestCase):
    def test_mine_select_and_stats_end_to_end(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            icsi = root / "icsi"
            icsi.mkdir()
            segments = "".join(segment(i * 4.0, i * 4.0 + 3.0, "me001", speech(20, f"q{i}")) for i in range(12))
            (icsi / "Txx001.mrt").write_text(MRT.format(segments=segments), encoding="iso-8859-1")
            out = root / "out"
            with contextlib.redirect_stdout(io.StringIO()):
                code = retrain_mine.main(["mine", "--icsi-dir", str(icsi), "--out-dir", str(out)])
            self.assertEqual(code, 0)
            rows = [json.loads(line) for line in (out / "passages.jsonl").read_text().splitlines()]
            self.assertTrue(rows and all(100 <= r["words"] <= 280 for r in rows))
            self.assertTrue((out / "sample20.txt").read_text().strip())
            with contextlib.redirect_stdout(io.StringIO()):
                code = retrain_mine.main(["select", "--passages", str(out / "passages.jsonl"), "--out",
                                          str(out / "w.jsonl"), "--mask-names"])
            self.assertEqual(code, 0)
            with contextlib.redirect_stdout(io.StringIO()):
                retrain_mine.main(["select", "--passages", str(out / "passages.jsonl"), "--out",
                                   str(out / "one.jsonl"), "--sample", "1"])
            self.assertEqual(len((out / "one.jsonl").read_text().splitlines()), 1)
            chosen = [json.loads(line) for line in (out / "w.jsonl").read_text().splitlines()]
            self.assertEqual(set(chosen[0]) >= {"id", "spoken", "corpus", "attribution"}, True)
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(retrain_mine.main(["stats", "--passages", str(out / "passages.jsonl")]), 0)

    def test_forbidden_paths_are_refused(self):
        buffer = io.StringIO()
        with contextlib.redirect_stderr(buffer):
            code = retrain_mine.main(["mine", "--icsi-dir", "/tmp/heldout-x", "--out-dir", "/tmp/out"])
        self.assertEqual(code, 1)
        self.assertIn("forbidden", buffer.getvalue())


if __name__ == "__main__":
    unittest.main()
