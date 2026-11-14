#!/usr/bin/env python3
"""Builds the long-meeting digest eval (`murmur-eval meeting`) from hand-written plans.

Each plan (`Evals/meeting-eval/plans/mNN.json`) fixes the gold: the exact lines that carry every
action item, decision, correction and small-talk distractor ("snippets"), and which segment of
the meeting they fall in. An LLM (`claude -p`, no tools, no MCP — the dev-only CLI judge
invocation sanctioned in DECISIONS 2026-09-26) writes only the *filler* conversation around
them: each segment is written with `[[pN]]` placeholders, and this script splices the snippet
lines in verbatim, so the gold never depends on the generator copying text correctly. A second
call audits every generated segment for stray commitments, assignments, deadlines or decisions
(which would be unscored action items); a segment with any is regenerated.

Output: `Evals/meeting-eval/golden.json` — transcripts in the app's speaker-turn format
("Label: text" per turn; labels are display names, "You" + "Speaker N" for two-channel
recordings, or "Speaker N"), plus gold items with their word position in the meeting.

EVAL-ONLY DATA: never use these transcripts or plans for training or prompt tuning. The
fine-tune path guards refuse any path containing "meeting-eval".

    python3 scripts/meeting-eval/build_meetings.py [--only m01,m02] [--jobs 4] [--model sonnet]
"""

from __future__ import annotations

import argparse
import concurrent.futures as futures
import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PLANS = ROOT / "Evals/meeting-eval/plans"
OUT = ROOT / "Evals/meeting-eval/golden.json"
CACHE = ROOT / ".build/meeting-eval-cache"
WORDS_PER_MINUTE = 150
MAX_ATTEMPTS = 6

sys.path.insert(0, str(ROOT / "scripts"))
from sealed_guard import assert_tuning_safe  # noqa: E402


def claude(prompt: str, model: str) -> str:
    """One stateless `claude -p` call (cached by prompt hash)."""
    key = hashlib.sha256(f"{model}\n{prompt}".encode()).hexdigest()
    cached = CACHE / f"{key}.txt"
    if cached.exists():
        return cached.read_text()
    result = subprocess.run(
        ["claude", "-p", "--model", model, "--output-format", "json", "--tools", "", "--strict-mcp-config"],
        input=prompt, capture_output=True, text=True, timeout=600, check=True)
    text = json.loads(result.stdout)["result"]
    CACHE.mkdir(parents=True, exist_ok=True)
    cached.write_text(text)
    return text


def label_of(meeting: dict, name: str) -> str:
    return next(p["label"] for p in meeting["people"] if p["name"] == name)


def people_block(meeting: dict) -> str:
    rows = []
    for p in meeting["people"]:
        if p["label"] == p["name"]:
            rows.append(f'- "{p["label"]}": {p["name"]}, {p["role"]}')
        else:
            rows.append(f'- "{p["label"]}": {p["name"]}, {p["role"]} (the transcript labels them only as "{p["label"]}")')
    return "\n".join(rows)


def snippet_text(meeting: dict, sid: str) -> str:
    return "\n".join(f"{label_of(meeting, who)}: {text}" for who, text in meeting["snippets"][sid])


def generation_prompt(meeting: dict, index: int, words: int, feedback: str) -> str:
    segment = meeting["segments"][index]
    count = len(meeting["segments"])
    earlier = "; ".join(s["topic"] for s in meeting["segments"][:index]) or "nothing yet (this is the start)"
    position = ("This is the very start of the meeting." if index == 0 else
                "This is the end of the meeting: finish with a natural sign-off." if index == count - 1 else
                "This is the middle of the meeting: start and end mid-conversation, no greetings or goodbyes.")
    sids = segment["snippets"]
    exchanges = "\n\n".join(
        f"[[{sid}]] stands for this exchange (inserted later, verbatim):\n{snippet_text(meeting, sid)}" for sid in sids)
    placeholder_rules = (
        "Some exchanges in this part are already written. Instead of writing them, put a placeholder "
        "line where each one happens, and write the conversation so it leads into it and follows from it "
        "(people may react to it briefly, e.g. \"okay\", \"sounds good\"). Never repeat, paraphrase or "
        "contradict those exchanges.\n\n" + exchanges) if sids else "This part has no pre-written exchanges."
    structure = (
        "\n\nREQUIRED: your output must contain these placeholder lines, each alone on its own line, "
        f"in this order: {', '.join('[[' + s + ']]' for s in sids)}. Spread them through the part "
        "(not all at the very start or end). A draft without them is discarded.") if sids else ""
    fix = f"\n\nA previous draft was rejected because: {feedback}\nAvoid that." if feedback else ""
    return f"""Write part {index + 1} of {count} of a realistic meeting transcript, about {words} words.

Meeting: {meeting['title']}. {meeting['setting']}
Speakers and the exact labels to use:
{people_block(meeting)}

Covered earlier in the meeting: {earlier}.
This part's topic: {segment['topic']}
{position}

{placeholder_rules}

Rules for every line you write yourself (the pre-written exchanges are the only place where
tasks, owners, deadlines or decisions appear; that is intended):
- Nobody commits to doing anything after the meeting, nobody is asked or assigned to do anything,
  no deadlines or dates for work are set, and no decisions are made or confirmed. People discuss,
  share facts and numbers, give opinions, ask each other questions, disagree, think out loud.
- Do not mention any topic from later in the meeting.
- Sound like speech transcribed by a good speech recogniser: natural spoken sentences, a few
  fillers ("um", "you know", "I mean"), occasional false starts, short back-and-forth turns.
  Speakers labelled "Speaker N" still address each other by first name sometimes.

Output only transcript lines, one turn per line, each "Label: what they said", using only the
labels above, plus the placeholder lines. No headings, stage directions or commentary.{structure}{fix}"""


AUDIT_PROMPT = """You are checking a synthetic meeting transcript used as test data.
Lines marked [KEEP] are intentional and must be ignored. Look only at unmarked lines.

Imagine a careful human note-taker writing the meeting's action items and decisions. List only
unmarked lines that such a note-taker would put on that list as a NEW item, i.e. a concrete,
specific task that a named or clearly identified person will do after the meeting ("I'll send
the report Friday", "Tom, can you book the room?"), or a clear new decision by the group that
goes beyond what the [KEEP] lines already decided.

Do NOT list: agreement with or reactions to a [KEEP] line ("works for me", "fine by me, less to
build"), questions answered during the meeting, opinions, wishes, suggestions nobody takes up,
vague intentions ("I'll want to look at that once it's testable", "we'll keep an eye on it"),
facts, or anything a note-taker would leave out.

Answer with JSON only: {"violations": [{"line": "<the line>", "why": "<short reason>"}]}

Transcript:
"""


def parse_audit(text: str) -> list[dict]:
    start = text.find("{")
    try:
        return json.JSONDecoder().raw_decode(text[start:])[0].get("violations", []) if start >= 0 else []
    except json.JSONDecodeError:
        return [{"line": "?", "why": "unparsable audit"}]


def parse_segment(meeting: dict, index: int, draft: str) -> tuple[list[tuple[str, str, str | None]], str | None]:
    """Draft → [(label, text, snippet id or None)], or an error message."""
    labels = {p["label"] for p in meeting["people"]}
    wanted = meeting["segments"][index]["snippets"]
    turns: list[tuple[str, str, str | None]] = []
    seen: list[str] = []
    for raw in draft.splitlines():
        line = raw.strip().strip("*").strip()
        if not line:
            continue
        # "Sofia: [[p4]]" or "[[p4]] Right." — the placeholder, with any label or leftover words
        # around it dropped (the canonical lines carry their own labels).
        embedded = re.search(r"\[\[(p\d+)\]\]", line)
        leftover = re.sub(r"^[A-Za-z][A-Za-z0-9 ]{0,20}:\s*", "", line.replace(embedded.group(0), "")).strip() if embedded else ""
        if embedded and len(leftover.split()) <= 4:
            line = embedded.group(0)
        placeholder = re.fullmatch(r"\[\[(p\d+)\]\]", line)
        if placeholder:
            sid = placeholder.group(1)
            if sid not in wanted:
                return [], f"unexpected placeholder {line}"
            if sid in seen:
                continue
            seen.append(sid)
            turns += [(label_of(meeting, who), text, sid) for who, text in meeting["snippets"][sid]]
            continue
        match = re.match(r"^([A-Za-z][A-Za-z0-9 ]{0,20}):\s+(.+)$", line)
        # A draft that writes "Femi:" for a speaker labelled "Speaker 3" gets the label back.
        by_name = {p["name"]: p["label"] for p in meeting["people"]}
        if match and match.group(1) in by_name:
            match = re.match(r"^(.+?):\s+(.+)$", f"{by_name[match.group(1)]}: {match.group(2)}")
        if not match or match.group(1) not in labels:
            return [], f"line without a known speaker label: {line[:80]!r}"
        if "[[" in line:
            return [], "placeholder inside a spoken line"
        copied = next((sid for sid in wanted for _, text in meeting["snippets"][sid]
                       if text[:40].lower() in line.lower()), None)
        if copied:
            # The model wrote a pre-written line out instead of (or as well as) its placeholder:
            # treat the first copy as the placeholder and drop the rest; the canonical lines go in.
            if copied not in seen:
                seen.append(copied)
                turns += [(label_of(meeting, who), text, copied) for who, text in meeting["snippets"][copied]]
            continue
        turns.append((match.group(1), match.group(2).strip(), None))
    if seen != wanted:
        return [], f"placeholders {seen} but expected {wanted} in that order"
    return turns, None


def audit(turns: list[tuple[str, str, str | None]], model: str) -> list[dict]:
    marked = "\n".join(f"{'[KEEP] ' if sid else ''}{label}: {text}" for label, text, sid in turns)
    keep = [f"{label}: {text}"[:60].lower() for label, text, sid in turns if sid]
    # The auditor sometimes lists a [KEEP] line anyway (saying it must be ignored): drop those.
    return [v for v in parse_audit(claude(AUDIT_PROMPT + marked, model))
            if not v.get("line", "").startswith("[KEEP]")
            and not any(k in v.get("line", "").lower() or v.get("line", "").lower()[:60] in k for k in keep)]


def without_flagged(turns: list[tuple[str, str, str | None]], violations: list[dict]) -> list[tuple[str, str, str | None]]:
    """Drops the generated (never the [KEEP]) lines the audit flagged."""
    flagged = [re.sub(r"^\[KEEP\]\s*", "", v.get("line", "")).strip()[:60].lower() for v in violations]
    return [t for t in turns if t[2] or not any(f and f in f"{t[0]}: {t[1]}".lower() for f in flagged)]


def build_segment(meeting: dict, index: int, model: str) -> list[tuple[str, str, str | None]]:
    words = meeting["minutes"] * WORDS_PER_MINUTE // len(meeting["segments"])
    feedback = ""
    for attempt in range(MAX_ATTEMPTS):
        prompt = generation_prompt(meeting, index, words, feedback) + ("\n" * attempt)
        turns, error = parse_segment(meeting, index, claude(prompt, model))
        if error is None:
            total = sum(len(text.split()) for _, text, _ in turns)
            if not 0.5 * words <= total <= 1.5 * words:
                error = f"{total} words, wanted about {words}"
        if error is None:
            violations = audit(turns, model)
            if not violations:
                return turns
            # A good draft with a stray commitment or two: drop those lines and re-check.
            pruned = without_flagged(turns, violations)
            if len(pruned) < len(turns) and len(turns) - len(pruned) <= 3 and not audit(pruned, model):
                return pruned
            error = "; ".join(f"{v.get('line', '')[:100]!r} ({v.get('why', '')})" for v in violations[:4])
        feedback = error
        print(f"  {meeting['id']} part {index + 1}: retry {attempt + 1}: {error[:200]}", file=sys.stderr)
    raise RuntimeError(f"{meeting['id']} part {index + 1}: no clean draft after {MAX_ATTEMPTS} attempts ({feedback})")


def assemble(meeting: dict, segments: list[list[tuple[str, str, str | None]]]) -> dict:
    turns = [turn for segment in segments for turn in segment]
    offsets: dict[str, int] = {}
    words = 0
    for label, text, sid in turns:
        if sid and sid not in offsets:
            offsets[sid] = words
        words += len(text.split())
    transcript = "\n".join(f"{label}: {text}" for label, text, _ in turns)

    def placed(items: list[dict]) -> list[dict]:
        out = []
        for item in items:
            fraction = offsets[item["snippet"]] / words
            out.append({**item, "position": round(fraction, 4), "quartile": min(4, int(fraction * 4) + 1),
                        "lastTenMinutes": fraction >= 1 - 10 / meeting["minutes"]})
        return out

    return {
        "id": meeting["id"], "title": meeting["title"], "minutes": meeting["minutes"], "style": meeting["style"],
        "people": meeting["people"], "words": words, "transcript": transcript,
        "actionItems": placed(meeting["actionItems"]), "superseded": placed(meeting["superseded"]),
        "decisions": placed(meeting["decisions"]), "distractors": placed(meeting["distractors"]),
    }


def build_meeting(path: Path, model: str, jobs: int) -> dict:
    assert_tuning_safe(path, purpose="meeting-eval builder")
    meeting = json.loads(path.read_text())
    with futures.ThreadPoolExecutor(max_workers=jobs) as pool:
        segments = list(pool.map(lambda i: build_segment(meeting, i, model), range(len(meeting["segments"]))))
    built = assemble(meeting, segments)
    print(f"{built['id']}: {built['words']} words, {len(built['actionItems'])} action items", file=sys.stderr)
    return built


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--only", default="")
    parser.add_argument("--jobs", type=int, default=4)
    parser.add_argument("--model", default="sonnet")
    args = parser.parse_args()
    only = {x for x in args.only.split(",") if x}
    existing = {m["id"]: m for m in json.loads(OUT.read_text())["meetings"]} if OUT.exists() else {}
    for path in sorted(PLANS.glob("m*.json")):
        if only and path.stem not in only:
            continue
        existing[path.stem] = build_meeting(path, args.model, args.jobs)
        OUT.write_text(json.dumps({
            "note": "EVAL-ONLY synthetic meetings for `murmur-eval meeting`. Never train or tune prompts on this file. "
                    "Built by scripts/meeting-eval/build_meetings.py from Evals/meeting-eval/plans.",
            "meetings": [existing[k] for k in sorted(existing)],
        }, indent=1, ensure_ascii=False) + "\n")


if __name__ == "__main__":
    main()
