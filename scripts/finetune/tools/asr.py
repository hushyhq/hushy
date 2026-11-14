"""ASR shaping for the voice-actions data: what a spoken command looks like after Parakeet.

The eval (and the runtime's tools prompt) sees lowercase text with no punctuation, disfluencies
kept. Parakeet drops most "um"/"uh", but keeps some, plus repeated words ("to to"), restarts
("remind me uh remind me to"), leading discourse words ("so", "okay", "hey") and trailing
politeness. Shaping only edits literal text between slots, so the label never changes.
"""

from __future__ import annotations

import random
import re
from typing import Any

from positives import Slot

LEADS = ["um", "uh", "so", "okay", "okay so", "hey", "um so", "uh so", "alright", "oh and", "yeah", "hmm", "so um", "right so"]
MIDS = ["uh", "um", "like", "you know", "uh", "um"]
TAILS = ["please", "thanks", "thank you", "for me", "real quick", "okay"]
PUNCTUATION = re.compile(r"[.,?!;:\"“”‘’()\[\]]")


def asr_text(text: str) -> str:
    """Lowercase, no punctuation (apostrophes kept), times "3:30" → "3 30", single spaces."""
    text = text.lower().replace("’", "'")
    text = re.sub(r"(\d):(\d\d)", r"\1 \2", text)
    text = text.replace("&", " and ").replace("%", " percent").replace("/", " ").replace("-", " ")
    text = PUNCTUATION.sub(" ", text)
    return re.sub(r"\s+", " ", text).strip()


def shape(segments: list[Any], rng: random.Random, rate: float = 1.0) -> tuple[list[Any], list[str]]:
    """Adds Parakeet-style disfluencies around the literal parts. Returns (segments, tags)."""
    out = [asr_segment(s) for s in segments]
    tags: list[str] = []
    literal = [i for i, s in enumerate(out) if isinstance(s, str) and s]
    if rng.random() < 0.22 * rate:
        out.insert(0, rng.choice(LEADS))
        tags.append("lead-filler")
    if literal and rng.random() < 0.14 * rate:
        index = rng.choice([i for i, s in enumerate(out) if isinstance(s, str) and s])
        out.insert(index + 1, rng.choice(MIDS))
        tags.append("mid-filler")
    if literal and rng.random() < 0.07 * rate:
        index = rng.choice([i for i, s in enumerate(out) if isinstance(s, str) and s and s not in LEADS])
        word = out[index].split()[-1]
        out[index] = out[index] + " " + word
        tags.append("repeat")
    if literal and rng.random() < 0.05 * rate:
        first = next((i for i, s in enumerate(out) if isinstance(s, str) and s and s not in LEADS), None)
        if first is not None and len(out[first].split()) >= 2:
            cue = rng.choice(["uh", "um", "i mean", ""])
            if "repeat" not in tags:  # one disfluency of this kind per utterance reads like speech; two read like noise
                out.insert(first + 1, cue + " " + out[first])
                tags.append("restart")
    if rng.random() < 0.06 * rate:
        out.append(rng.choice(TAILS))
        tags.append("tail")
    return out, tags


def asr_segment(segment: Any) -> Any:
    if isinstance(segment, Slot):
        return Slot(asr_text(segment.spoken))
    return asr_text(segment)


def join(segments: list[Any]) -> str:
    parts = [(s.spoken if isinstance(s, Slot) else s) for s in segments]
    return re.sub(r"\s+", " ", " ".join(p for p in parts if p)).strip()


def asr_value(value: Any) -> Any:
    """A label value in the same shape as the utterance text it was copied from."""
    if isinstance(value, str):
        return asr_text(value)
    if isinstance(value, list):
        return [asr_text(v) for v in value]
    return value
