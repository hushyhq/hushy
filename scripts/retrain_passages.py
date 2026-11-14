"""Joins one speaker's consecutive units across other people's short backchannels into 100-280 word
passages, and describes each passage (timing, intrusions, disfluency-layer marks, surface features).

A chain grows while the next unit of the same speaker starts within MAX_GAP_SECONDS and every
other-speaker unit that falls inside the chain's time window is a short backchannel (at most
MAX_BACKCHANNEL_WORDS words, MAX_INTRUSION_WORDS words in all). A chain longer than the maximum is cut
at sentence or unit boundaries into pieces of 100-280 words; a remainder under 100 words is dropped.
"""

from __future__ import annotations

import bisect
import re
from dataclasses import dataclass

import retrain_features as features
from retrain_corpora import is_word

MIN_WORDS = 100
MAX_WORDS = 280
MAX_GAP_SECONDS = 3.0
MAX_BACKCHANNEL_WORDS = 4
MAX_INTRUSION_WORDS = 10
LENGTH_BINS = ((100, 150), (150, 220), (220, 280))  # [low, high), the last one closed at 280


@dataclass
class Chain:
    units: list


class SpeakerIndex:
    """Start-sorted units of one speaker with a running maximum of ends, for overlap queries."""

    def __init__(self, units):
        self.units = units
        self.starts = [u.start for u in units]
        self.max_end = []
        top = float("-inf")
        for unit in units:
            top = max(top, unit.end)
            self.max_end.append(top)

    def inside(self, t0, t1):
        """Units whose midpoint lies in [t0, t1]."""
        first = bisect.bisect_left(self.max_end, t0)
        last = bisect.bisect_right(self.starts, t1)
        return [u for u in self.units[first:last] if t0 <= (u.start + u.end) / 2 <= t1]


def intrusion(others, t0, t1):
    """(words, events, longest event in words) of other speakers' units inside the window."""
    events = [u.word_count for index in others for u in index.inside(t0, t1)]
    events = [n for n in events if n]
    return sum(events), len(events), max(events, default=0)


def overlap_fraction(others, t0, t1):
    spans = sorted((max(u.start, t0), min(u.end, t1)) for index in others for u in index.inside(t0, t1))
    covered, edge = 0.0, t0
    for start, end in spans:
        start = max(start, edge)
        if end > start:
            covered += end - start
            edge = end
    return covered / (t1 - t0) if t1 > t0 else 0.0


def acceptable(others, t0, t1):
    words, _, longest = intrusion(others, t0, t1)
    return longest <= MAX_BACKCHANNEL_WORDS and words <= MAX_INTRUSION_WORDS


def build_chains(units, others):
    """Greedy chains of one speaker's units. Every unit lands in exactly one chain."""
    chains, current = [], []
    for unit in units:
        if current and unit.start - current[-1].end <= MAX_GAP_SECONDS and \
                acceptable(others, current[0].start, max(unit.end, current[-1].end)):
            current.append(unit)
            continue
        if current:
            chains.append(Chain(current))
        current = [unit]
    if current:
        chains.append(Chain(current))
    return chains


FINAL = re.compile(r"[.?!][\"')\]]*$")
OPENS_LOWERCASE = frozenset("i i'm i'll i've i'd".split()) | features.HESITATIONS


def is_sentence_final(text):
    """A token that ends a sentence as the transcript wrote it; "th-." (a cut-off word) and "-?" do not."""
    return bool(FINAL.search(text)) and not re.search(r"-[.?!]*$", text)


def starts_sentence(text):
    """False for a token written in lower case (a transcript only does that mid-sentence), except fillers
    and "I" forms, which transcripts write in lower case at the start of an utterance."""
    first = text.lstrip("\"'([")[:1]
    return not first.islower() or features.norm(text) in OPENS_LOWERCASE


def flatten(chain):
    """[(token, unit index)] for the chain's tokens, the token indices that end a sentence (a piece may end
    there), and the token indices that end a unit."""
    tokens, sentence_ends, unit_ends = [], [], []
    for index, unit in enumerate(chain.units):
        for token in unit.tokens:
            tokens.append((token, index))
            if is_sentence_final(token.text):
                sentence_ends.append(len(tokens))
        unit_ends.append(len(tokens))
    return tokens, sentence_ends, unit_ends


def word_prefix(tokens):
    counts = [0]
    for token, _ in tokens:
        counts.append(counts[-1] + (1 if is_word(token.text) else 0))
    return counts


def split_chain(chain, trimmed=None):
    """[(first token index, end token index)] pieces of MIN_WORDS..MAX_WORDS words that start where a
    sentence starts and end where one ends. A leading fragment that starts mid-sentence and a trailing
    unfinished fragment are left out (counted in `trimmed["trimmed_words"]`); a stretch that falls under
    MIN_WORDS after trimming is dropped."""
    tokens, ends, unit_ends = flatten(chain)
    words = word_prefix(tokens)
    if not tokens or not ends:
        return []
    position = 0 if starts_sentence(tokens[0][0].text) else ends[0]
    limit = ends[-1]
    if trimmed is not None and words[-1] >= MIN_WORDS:
        trimmed["trimmed_words"] = trimmed.get("trimmed_words", 0) + (words[position] - words[0]) \
            + (words[-1] - words[limit])
    pieces = []
    while words[limit] - words[position] >= MIN_WORDS:
        if words[limit] - words[position] <= MAX_WORDS:
            end = limit
        else:
            candidates = [c for c in ends if position < c <= limit
                          and MIN_WORDS <= words[c] - words[position] <= MAX_WORDS]
            clean = [c for c in candidates if words[limit] - words[c] >= MIN_WORDS or c == limit]
            if candidates:
                end = max(clean or candidates)
            else:  # one sentence longer than the maximum: cut at a unit end, else at the maximum
                inside = [c for c in unit_ends if position < c <= limit and MIN_WORDS <= words[c] - words[position] <= MAX_WORDS]
                end = max(inside) if inside else next(
                    i for i in range(position, len(tokens) + 1) if words[i] - words[position] >= MAX_WORDS)
        pieces.append((position, end))
        position = end
    if not pieces and trimmed is not None and words[-1] >= MIN_WORDS:
        trimmed["below_floor_after_trim"] = trimmed.get("below_floor_after_trim", 0) + 1
    return pieces


def render(tokens):
    return " ".join(token.text for token, _ in tokens)


def ami_layer(tokens, covered):
    """The disfluency layer's marks inside a passage, as word indices into the passage's word list."""
    marks, fillers, repairs, index = [], 0, 0, -1
    for token, _ in tokens:
        if not is_word(token.text):
            continue
        index += 1
        roles = token.roles
        repair = "repair" in roles
        repairs += repair
        fillers += any(r.startswith("filler:") for r in roles)
        if not repair:
            for role in roles:
                if role.startswith("taken_back:"):
                    marks.append({"i": index, "word": features.norm(token.text), "type": role.split(":")[1]})
    return {"covered": covered, "taken_back": marks, "fillers_marked": fillers, "repairs": repairs}


def describe(meeting, speaker, chain, span, others, lexicons, keep_ami):
    tokens = flatten(chain)[0]
    first, end = span
    piece = tokens[first:end]
    unit_ids = sorted({u for _, u in piece})
    used = [chain.units[i] for i in unit_ids]
    t0, t1 = used[0].start, used[-1].end
    raw = [token.text for token, _ in piece]
    text = render(piece)
    in_words, in_events, longest = intrusion(others, t0, t1)
    overlap = overlap_fraction(others, t0, t1)
    feats = features.passage_features([t for t in raw if is_word(t)], text, *lexicons)
    word_total = sum(1 for t in raw if is_word(t))
    passage = {
        "id": f"{meeting.corpus}-{meeting.meeting_id}-{speaker}-{int(t0 * 1000)}-{first}",
        "corpus": meeting.corpus, "meeting": meeting.meeting_id, "speaker": speaker,
        "start": round(t0, 3), "end": round(t1, 3), "words": word_total, "text": text,
        "units": len(used), "flags": {"gaps": sum(u.gaps for u in used),
                                      "unintelligible": sum(u.unintelligible for u in used),
                                      "foreign": sum(u.foreign for u in used),
                                      "censored": sum(u.censored for u in used)},
        "intrusion": {"words": in_words, "events": in_events, "longest": longest,
                      "overlap_fraction": round(overlap, 3)},
        "features": feats,
        "monologue_score": features.monologue_score(feats["cues"], in_words, overlap),
    }
    if keep_ami:
        passage["ami_layer"] = ami_layer(piece, speaker in meeting.covered_speakers)
    return passage


def mine_meeting(meeting, lexicons, rejected=None):
    """Every passage in one meeting. A piece whose window holds more than backchannels from other
    speakers (cross-talk, or the speaker's own first unit sitting on top of someone else's turn) is
    dropped and counted in `rejected["cross_talk"]`."""
    indexes = {s: SpeakerIndex(units) for s, units in meeting.speakers.items()}
    passages = []
    for speaker, index in indexes.items():
        others = [i for s, i in indexes.items() if s != speaker]
        for chain in build_chains(index.units, others):
            for span in split_chain(chain, rejected):
                passage = describe(meeting, speaker, chain, span, others, lexicons, meeting.corpus == "AMI")
                if passage["intrusion"]["words"] > MAX_INTRUSION_WORDS or \
                        passage["intrusion"]["longest"] > MAX_BACKCHANNEL_WORDS:
                    if rejected is not None:
                        rejected["cross_talk"] = rejected.get("cross_talk", 0) + 1
                    continue
                passages.append(passage)
    return passages


def length_bin(words):
    for low, high in LENGTH_BINS:
        if low <= words < high or (high == MAX_WORDS and words == high):
            return f"{low}-{high}"
    return "other"
