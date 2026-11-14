"""Readers for the AMI and ICSI meeting transcripts (CC BY 4.0) used to mine long single-speaker stretches.

Both readers return `Meeting` objects whose speakers each have a time-ordered list of `Unit`s (one
utterance-sized run of that speaker's words). The text of the corpora is untrusted data: nothing
here executes it or parses it with an XML engine. AMI file names derived from its metadata are
validated and resolved inside the supplied corpus root before they are opened. Both
formats are read with regular expressions over fixed element and attribute names.

Conventions, and what this code does with them (sources read on 2026-10-08):

AMI  (ami_public_manual_1.6.2, NXT; 00README_MANUAL.txt, corpusdoc/annot_w.html, annot_dsfl.html)
  words/<meeting>.<agent>.words.xml     one <w starttime endtime> per word, punctuation as separate <w
                                        punc="true"> tokens (attached to the previous word here)
  trunc="true"                          a truncated word, written without a hyphen -> hyphen appended
  mispronounced="true", pron="..."      the word is written in standard spelling -> text kept, note dropped
  <vocalsound type=laugh|cough|...>     non-speech -> removed
  <gap/>                                an untranscribed stretch -> removed and counted (flag `gaps`)
  <disfmarker/>                         the annotators' mark for an interrupted utterance -> a lone "-"
                                        token, the same convention ICSI uses (can be dropped by the miner)
  <transformerror/>                     conversion artefact, 30 in the whole corpus -> ignored
  X_Y_Z_ , T_V_s                        spoken letters -> underscores removed ("XYZ", "TVs")
  disfluency/<meeting>.<agent>.disfluency.xml   <dsfl> elements pointing at word ranges, typed by
                                        ontologies/dsfl-types.xml (delete, disrupt, dm, eet, hesit, insert,
                                        mistake, omiss, order, other, repeat, replace, restart, sot,
                                        stutter, repair, reparans, reparandum). The corpus documentation only
                                        names the types; reading them as "taken back" / "the repair" below
                                        is this tool's interpretation, checked on sampled examples (the
                                        word that is abandoned carries repeat/replace/restart/disrupt, the
                                        word that replaces it carries reparans).

ICSI (ICSI_original_transcripts, MRT; doc/trans_guide.txt including its ADDENDUM)
  <Segment StartTime EndTime Participant>   one utterance-sized run; the NXT release was not used because its
                                        words carry timing for only part of the corpus and split compound
                                        hyphens into separate tokens
  DigitTask="true"                      the digit-reading task -> segment dropped
  segments without Participant         unattributed far-field material -> dropped
  <VocalSound/> <NonVocalSound/> <Pause/> <Comment/>  non-speech -> removed ("Censored" comments are counted:
                                        the transcribers masked something there)
  <Uncertain> words </Uncertain>        the transcriber is reasonably sure -> words kept
  <Uncertain ...> @@ </Uncertain>       undecipherable -> removed and counted (flag `unintelligible`)
  <Pronounce ...> word </Pronounce>     word kept, pronunciation note dropped
  <Foreign ...> words </Foreign>        words kept, counted (flag `foreign`)
  <Emphasis> word </Emphasis>           tags dropped
  th-   (truncated word)                kept as written, with its hyphen
  " - " (interrupted utterance)         kept as a lone "-" token
  O_K, A_, P_L_<Emphasis> P </Emphasis> spoken letters -> underscores removed ("OK", "A", "PLP")
"""

from __future__ import annotations

import html
import re
from dataclasses import dataclass, field
from pathlib import Path

AMI_UNIT_GAP_SECONDS = 1.0  # a pause this long inside one speaker's words starts a new unit
AMI_DISFLUENCY_FILLER = ("hesit", "dm", "eet")
AMI_DISFLUENCY_TAKEN_BACK = ("repeat", "replace", "restart", "disrupt", "delete", "insert", "sot",
                             "stutter", "order")
AMI_DISFLUENCY_REPAIR = ("reparans", "repair")
AMI_DSFL_NAMES = {1: "delete", 2: "disrupt", 3: "dm", 4: "eet", 5: "hesit", 6: "insert", 7: "mistake",
                  8: "omiss", 9: "order", 11: "other", 12: "repeat", 13: "replace", 14: "restart",
                  15: "sot", 16: "stutter", 17: "repair", 18: "reparans", 19: "reparandum"}

ATTRIBUTE = re.compile(r'([\w:-]+)="([^"]*)"')
ELEMENT = re.compile(r"<(w|disfmarker|gap|vocalsound|transformerror)\s([^>]*?)(/>|>([^<]*)</w>)")
HAS_ALNUM = re.compile(r"[^\W_]")


@dataclass(frozen=True)
class Token:
    text: str
    roles: tuple = ()  # AMI disfluency roles, e.g. ("taken_back:restart",), ("repair",), ("filler:hesit",)


@dataclass
class Unit:
    speaker: str
    start: float
    end: float
    tokens: list
    gaps: int = 0
    unintelligible: int = 0
    foreign: int = 0
    censored: int = 0

    @property
    def word_count(self):
        return sum(1 for token in self.tokens if is_word(token.text))


@dataclass
class Meeting:
    corpus: str
    meeting_id: str
    speakers: dict = field(default_factory=dict)  # speaker id -> [Unit] ordered by start
    covered_speakers: frozenset = frozenset()  # AMI speakers that have a disfluency-layer file
    notes: dict = field(default_factory=dict)


def is_word(text):
    return bool(HAS_ALNUM.search(text))


DIGIT_READING_WORDS = frozenset("zero oh one two three four five six seven eight nine".split())


def is_digit_reading(tokens):
    """The digit-reading task also appears in segments the transcribers did not flag as DigitTask."""
    words = [re.sub(r"[^\w']", "", t.text.lower()) for t in tokens if is_word(t.text)]
    return len(words) >= 3 and all(w in DIGIT_READING_WORDS for w in words)


def attributes(text):
    return {name: html.unescape(value) for name, value in ATTRIBUTE.findall(text)}


def number(value):
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def read_text(path):
    return Path(path).read_text(encoding="iso-8859-1")


def tidy_letters(text):
    """Spoken-letter underscores: 'O_K' -> 'OK', 'T_V_s' -> 'TVs', 'C_zero' -> 'C zero'."""
    text = re.sub(r"_\s+(?=[A-Z](?:\s|[,.?!]|$))", "_", text)  # 'P_L_ P' from a stray emphasis tag
    text = re.sub(r"(?<=[A-Z])_(?=[a-z]{2,})", " ", text)
    return text.replace("_", "")


# ---- AMI -----------------------------------------------------------------------------------------

def ami_speaker_map(root):
    """{observation: {agent letter: (global name, role)}} from corpusResources/meetings.xml."""
    mapping = {}
    text = read_text(Path(root) / "corpusResources" / "meetings.xml")
    for block in re.finditer(r"<meeting\s([^>]*)>(.*?)</meeting>", text, re.S):
        observation = attributes(block.group(1)).get("observation")
        if not observation:
            continue
        agents = {}
        for speaker in re.finditer(r"<speaker\s([^>]*?)/>", block.group(2)):
            fields = attributes(speaker.group(1))
            if fields.get("nxt_agent") and fields.get("global_name"):
                agents[fields["nxt_agent"]] = (fields["global_name"], fields.get("role", ""))
        mapping[observation] = agents
    return mapping


def ami_disfluency_spans(path):
    """[(first word id, last word id, role)] for every <dsfl> in one disfluency file."""
    spans = []
    for block in re.finditer(r"<dsfl\s([^>]*)>(.*?)</dsfl>", read_text(path), re.S):
        body = block.group(2)
        type_id = re.search(r'role="dsfl-type"\s+href="[^"]*#id\(ami_dsfl_(\d+)\)', body)
        if not type_id:
            continue
        name = AMI_DSFL_NAMES.get(int(type_id.group(1)), "other")
        if name in AMI_DISFLUENCY_FILLER:
            role = f"filler:{name}"
        elif name in AMI_DISFLUENCY_TAKEN_BACK:
            role = f"taken_back:{name}"
        elif name in AMI_DISFLUENCY_REPAIR:
            role = "repair"
        else:
            role = f"marked:{name}"
        for href in re.findall(r'<nite:child\s+href="([^"]+)"', body):
            ids = re.findall(r"id\(([^)]+)\)", href)
            if ids:
                spans.append((ids[0], ids[-1], role))
    return spans


def ami_word_roles(path, ordered_ids):
    """{word id: tuple(roles)} for one speaker, expanding id ranges over the words file's own order."""
    position = {word_id: i for i, word_id in enumerate(ordered_ids)}
    found = {}
    for first, last, role in ami_disfluency_spans(path):
        if first not in position or last not in position:
            continue
        for word_id in ordered_ids[position[first]:position[last] + 1]:
            found.setdefault(word_id, []).append(role)
    return {word_id: tuple(sorted(set(roles))) for word_id, roles in found.items()}


def _ami_stream(path):
    """[(id, kind, text, start, end, attrs)] in document order, kind in w|disfmarker|gap."""
    stream = []
    for match in ELEMENT.finditer(read_text(path)):
        kind, attr_text, _, body = match.groups()
        if kind in ("vocalsound", "transformerror"):
            continue
        fields = attributes(attr_text)
        stream.append((fields.get("nite:id", ""), kind, html.unescape(body or ""),
                       number(fields.get("starttime")), number(fields.get("endtime")), fields))
    return stream


def ami_speaker_units(words_path, disfluency_path, speaker, keep_dashes=True):
    stream = _ami_stream(words_path)
    roles = ami_word_roles(disfluency_path, [item[0] for item in stream]) if disfluency_path else {}
    units, tokens, pending_gaps = [], [], 0
    first_start = last_end = None

    def close():
        nonlocal tokens, first_start, last_end, pending_gaps
        if any(is_word(t.text) for t in tokens) and first_start is not None:
            units.append(Unit(speaker, first_start, last_end if last_end is not None else first_start,
                              tokens, gaps=pending_gaps))
        tokens, first_start, last_end, pending_gaps = [], None, None, 0

    for word_id, kind, text, start, end, fields in stream:
        if kind == "gap":
            pending_gaps += 1
            continue
        if kind == "disfmarker":
            if keep_dashes and tokens:
                tokens.append(Token("-"))
            continue
        if start is not None and last_end is not None and start - last_end > AMI_UNIT_GAP_SECONDS:
            close()
        text = tidy_letters(text.strip())
        if not text:
            continue
        if fields.get("punc") == "true":
            if tokens and is_word(tokens[-1].text):
                tokens[-1] = Token(tokens[-1].text + text, tokens[-1].roles)
            elif tokens and tokens[-1].text == "-" and text in ("?",):
                tokens[-1] = Token("-" + text)
            continue
        if fields.get("trunc") == "true":
            text += "-"
        tokens.append(Token(text, roles.get(word_id, ())))
        if first_start is None:
            first_start = start
        if end is not None:
            last_end = end
        elif start is not None:
            last_end = start
    close()
    return units


def contained_corpus_file(root, candidate):
    """Return a file path only when its resolved target stays inside the corpus root."""
    try:
        resolved = candidate.resolve(strict=candidate.is_symlink())
    except (OSError, RuntimeError):
        return None
    return resolved if resolved.is_relative_to(Path(root).resolve()) else None


def safe_ami_file(root, folder, observation, agent, suffix):
    """Resolve corpus-derived names before opening either AMI layer."""
    for value in (observation, agent):
        if "/" in value or "\\" in value or ".." in value:
            return None
    candidate = root / folder / f"{observation}.{agent}.{suffix}.xml"
    return contained_corpus_file(root, candidate)


def load_ami(root, keep_dashes=True, only=None, stats=None):
    """Every AMI meeting under `root` (the unpacked manual-annotations folder)."""
    root = Path(root)
    speakers_by_meeting = ami_speaker_map(root)
    meetings = []
    for observation in sorted(speakers_by_meeting):
        if only and observation not in only:
            continue
        meeting = Meeting("AMI", observation)
        covered = set()
        for agent, (global_name, role) in sorted(speakers_by_meeting[observation].items()):
            words = safe_ami_file(root, "words", observation, agent, "words")
            disfluency = safe_ami_file(root, "disfluency", observation, agent, "disfluency")
            if words is None or disfluency is None:
                if stats is not None:
                    stats["unsafe_corpus_paths"] = stats.get("unsafe_corpus_paths", 0) + 1
                continue
            if not words.is_file():
                continue
            has_layer = disfluency.is_file()
            units = ami_speaker_units(words, disfluency if has_layer else None, global_name, keep_dashes)
            speaker_id = f"{global_name}"
            meeting.speakers[speaker_id] = sorted(units, key=lambda u: (u.start, u.end))
            meeting.notes[speaker_id] = {"agent": agent, "role": role}
            if has_layer:
                covered.add(speaker_id)
        meeting.covered_speakers = frozenset(covered)
        if meeting.speakers:
            meetings.append(meeting)
    return meetings


# ---- ICSI ----------------------------------------------------------------------------------------

SEGMENT = re.compile(r"<Segment\s([^>]*)>(.*?)</Segment>", re.S)
ICSI_NON_SPEECH = re.compile(r"<(?:VocalSound|NonVocalSound|Pause)\b[^>]*/>")
ICSI_COMMENT = re.compile(r"<Comment\b([^>]*)/>")
ICSI_UNCERTAIN_BLANK = re.compile(r"<Uncertain\b[^>]*>\s*@@\s*</Uncertain>")


def clean_icsi_text(raw):
    """(text, counts) for one segment's body. See the module docstring for each convention."""
    counts = {"unintelligible": 0, "foreign": 0, "censored": 0}
    text = ICSI_NON_SPEECH.sub(" ", raw)

    def comment(match):
        if "Censored" in match.group(1):
            counts["censored"] += 1
        return " "

    text = ICSI_COMMENT.sub(comment, text)
    text, counts["unintelligible"] = ICSI_UNCERTAIN_BLANK.subn(" ", text)
    counts["foreign"] = len(re.findall(r"<Foreign\b", text))
    text = re.sub(r"<[^>]+>", "", text)
    text = html.unescape(text)
    text = text.replace("@@", " ")
    text = tidy_letters(text)
    text = re.sub(r"\s+([,.?!;:])", r"\1", text)
    return " ".join(text.split()), counts


def icsi_segment_tokens(text, keep_dashes=True):
    tokens = []
    for piece in text.split():
        if not is_word(piece):
            if keep_dashes and piece in ("-", "--"):
                tokens.append(Token("-"))
            elif tokens and piece in (",", ".", "?", "!", "..", "..."):
                tokens[-1] = Token(tokens[-1].text + piece, tokens[-1].roles)
            continue
        tokens.append(Token(piece))
    return tokens


def load_icsi(root, keep_dashes=True, only=None, stats=None):
    """Every ICSI meeting transcript (*.mrt except preambles.mrt) in the transcripts folder `root`."""
    meetings = []
    for path in sorted(Path(root).glob("*.mrt")):
        if path.name == "preambles.mrt" or (only and path.stem not in only):
            continue
        checked = contained_corpus_file(root, path)
        if checked is None:
            if stats is not None:
                stats["unsafe_corpus_paths"] = stats.get("unsafe_corpus_paths", 0) + 1
            continue
        meeting = Meeting("ICSI", path.stem)
        per_speaker = {}
        for match in SEGMENT.finditer(read_text(checked)):
            fields = attributes(match.group(1))
            speaker, start, end = fields.get("Participant"), number(fields.get("StartTime")), \
                number(fields.get("EndTime"))
            if not speaker or start is None or end is None or fields.get("DigitTask") == "true":
                continue
            text, counts = clean_icsi_text(match.group(2))
            tokens = icsi_segment_tokens(text, keep_dashes)
            if not any(is_word(t.text) for t in tokens) or is_digit_reading(tokens):
                continue
            per_speaker.setdefault(speaker, []).append(
                Unit(speaker, start, end, tokens, unintelligible=counts["unintelligible"],
                     foreign=counts["foreign"], censored=counts["censored"]))
        meeting.speakers = {speaker: sorted(units, key=lambda u: (u.start, u.end))
                            for speaker, units in per_speaker.items()}
        if meeting.speakers:
            meetings.append(meeting)
    return meetings
