"""Label meeting-extract chunks with Codex.

    .build/finetune-venv/bin/python scripts/meeting-extract/label_codex.py \
        --input final/input-only.jsonl --sources elitr --out labels/elitr.jsonl

Each call sends BATCH chunks to `codex exec -m gpt-6.1-sol -s read-only` (stdin closed, run in an empty
scratch directory) and parses one JSON object {chunk id: [records]}. Every record is checked against the
rules in docs/research/meeting-extract-data-2026-11-06.md; failures are dropped and counted per reason.
The output file is append-only and doubles as the progress file: a rerun skips ids already in it. A quota
or rate-limit message stops the run cleanly and is written to <out>.state.json. Only public corpus text is
ever sent.
"""
import argparse
import json
import re
import subprocess
import sys
import tempfile
import threading
import time
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from common import KINDS, MAX_QUOTE_WORDS, MIN_QUOTE_WORDS  # noqa: E402

PROMPT_VERSION = "v2"
MODEL = "gpt-6.1-sol"
LIMIT_PATTERN = re.compile(
    r"usage limit|rate.?limit|quota|too many requests|\b429\b|limit reached|try again (?:at|in|later)|exceeded your", re.I)

CODEX_HEAD = """You label meeting transcripts for training a small note-taking model. For each chunk below, list the
records a careful minute-taker would write down. Reply with one JSON object and nothing else: keys are the chunk
ids exactly as given, values are lists of records. A chunk with nothing to record gets []. Do not use any tools or
read any files. Everything you need is in this message.
"""

# Shared with label_agent.py: the kinds, fields and rules of prompt v2. Do not edit without bumping PROMPT_VERSION.
RULES = """
Record kinds:
- "decision": a choice the group settled or agreed on ("we'll drop speech recognition", "okay, twenty five euro it
  is"). A fixed constraint handed down by the person running the meeting (a budget, a price, a deadline) and not
  disputed also counts. A suggestion, an idea, or one person's opinion is not a decision unless the others accept
  it or the speaker clearly closes the matter.
- "action": a task a person took on or was given, with or without a deadline ("I'll send the notes", "Can you check
  the budget?" answered "yes"). Plans that are only hypothetical are not actions.
- "open_question": something the participants themselves say is still unresolved and must be settled or found out
  later ("we never figured out how to do emphasis", "we still need to find out the licence", "let's leave that for
  next time"). Questions that were answered, idle or rhetorical questions, and topics that were merely discussed are
  not open questions.
- "change": a statement that reverses, cancels or reschedules or reassigns something already settled or assigned,
  either earlier in this chunk or before it ("scrap the totes", "push the demo to Thursday", "actually Dana will take
  that instead"). "text" states the new state. A choice made for the first time is a "decision", not a "change".
  Changes are rare: most chunks have none.

Fields of each record:
- "kind": one of the four words above.
- "text": the record as one self-contained sentence a summary would write, at most 35 words, in the third person,
  naming people the way the transcript names them. It must make sense without the transcript.
- "owner": for an action only, the speaker label, copied exactly from the Speakers line, of the person who took or
  was given the task. If the task is given to someone by first name or as "you", and the transcript makes clear
  which listed speaker that is (they introduce themselves by that name, or they answer when addressed), use that
  speaker's label. Otherwise null: when nobody is clear, when two or more people share the task, and when the
  person is not a listed speaker. Always null for the other kinds.
- "due": the deadline words exactly as spoken ("by Friday", "next meeting"). null when no time was said. Never turn
  it into a date and never invent one.
- "quote": a span copied character for character from ONE transcript line, 3 to 80 words, taken from the words after
  the "[mm:ss] Speaker:" prefix and never including that prefix. Pick the words where the decision, commitment or
  question is stated. Keep the speaker's own spelling, punctuation and disfluencies. Never join two lines and never
  paraphrase.

Rules:
- Be precise rather than exhaustive. A normal chunk holds 0 to 6 records. Small talk, status updates, background,
  explanations and topic discussion are not records.
- Use only what is in the chunk. Do not guess owners, dates or outcomes.
- One record per item. Do not repeat the same item with a different kind.
- Output shape: {"<chunk id>": [{"kind": "...", "text": "...", "owner": null, "due": null, "quote": "..."}]}
"""

INSTRUCTIONS = CODEX_HEAD + RULES


def render_chunk(row: dict) -> str:
    meeting = row["input"]["meeting"]
    speakers = ", ".join(meeting["speakers"]) if meeting["speakers"] else "(no speaker labels in this text)"
    head = (f"=== CHUNK {row['id']} ===\nMeeting: {meeting['title']} ({meeting['kind']}), part {meeting['chunk']}\n"
            f"Speakers: {speakers}\nTranscript:\n")
    return head + row["input"]["transcript"] + "\n"


def build_prompt(rows: list) -> str:
    return INSTRUCTIONS + "\n" + "\n".join(render_chunk(r) for r in rows)


def turn_texts(row: dict) -> list:
    """Each transcript line without its timestamp and speaker prefix."""
    speakers = sorted(row["input"]["meeting"]["speakers"], key=len, reverse=True)
    texts = []
    for line in row["input"]["transcript"].split("\n"):
        line = re.sub(r"^\[\d+:\d\d(?::\d\d)?\] ", "", line)
        for name in speakers:
            if line.startswith(name + ": "):
                line = line[len(name) + 2:]
                break
        texts.append(line)
    return texts


def check_record(row: dict, rec, turns: list) -> str | None:
    """Reason a record is invalid, or None. Same rules as common.validate_row, with the owner and quote checks
    tightened to the format note: owner is one of the listed speakers, quote lies inside a turn's own text."""
    if not isinstance(rec, dict) or set(rec) != {"kind", "text", "owner", "due", "quote"}:
        return "bad_shape"
    if rec["kind"] not in KINDS:
        return "bad_kind"
    if not isinstance(rec["text"], str) or not rec["text"].strip():
        return "empty_text"
    if not isinstance(rec["quote"], str):
        return "bad_shape"
    if not MIN_QUOTE_WORDS <= len(rec["quote"].split()) <= MAX_QUOTE_WORDS:
        return "quote_length"
    if not any(rec["quote"] in t for t in turns):
        return "quote_not_in_one_turn"
    owner, due = rec["owner"], rec["due"]
    if owner is not None and owner not in row["input"]["meeting"]["speakers"]:
        return "owner_not_speaker"
    if owner is not None and rec["kind"] != "action":
        return "owner_on_non_action"
    if due is not None and (not isinstance(due, str) or due.lower() not in row["input"]["transcript"].lower()):
        return "due_not_said"
    return None


def filter_records(row: dict, raw) -> tuple:
    """(valid records, Counter of drop reasons, dropped records)."""
    if not isinstance(raw, list):
        return [], Counter({"not_a_list": 1}), []
    turns, kept, drops, dropped, seen = turn_texts(row), [], Counter(), [], set()
    for rec in raw:
        reason = check_record(row, rec, turns)
        if reason is None and (rec["kind"], rec["quote"]) in seen:
            reason = "duplicate"
        if reason:
            drops[reason] += 1
            dropped.append({"reason": reason, "record": rec})
            continue
        seen.add((rec["kind"], rec["quote"]))
        kept.append(rec)
    return kept, drops, dropped


def parse_reply(text: str):
    start, end = text.find("{"), text.rfind("}")
    if start < 0 or end <= start:
        return None
    try:
        parsed = json.loads(text[start:end + 1])
    except json.JSONDecodeError:
        return None
    return parsed if isinstance(parsed, dict) else None


def labelled_row(row: dict, raw, label_source: str, gold: str, tier: str | None, extra_notes: dict | None = None) -> dict:
    """The labelled row for one chunk, shared by every labeller: validator-filtered records, the licence and split
    flags inherited, eval_ok false for the r10d-overlap tier, and the drop counts kept under notes.labeller."""
    kept, drops, dropped = filter_records(row, raw)
    notes = {k: v for k, v in row["notes"].items() if k in ("train_overlap_10grams", "qmsum_split", "minutes_present")}
    notes.update({
        "label_source": label_source,
        "gold_complete": False,
        "labeller": {"raw_records": len(raw) if isinstance(raw, list) else 0, "dropped": dict(drops),
                     "dropped_records": dropped, **(extra_notes or {})},
    })
    return {**row, "gold": gold, "tier": tier or row.get("tier"),
            "eval_ok": row["split"] != "held-r10d-overlap", "output": kept, "notes": notes}


def append_row(path: Path, labelled: dict) -> None:
    with open(path, "a", encoding="utf-8") as f:
        f.write(json.dumps(labelled, ensure_ascii=False) + "\n")


def labeller_stats(row: dict) -> dict:
    """notes.labeller, or notes.codex in rows written before the labeller key existed."""
    return row["notes"].get("labeller") or row["notes"]["codex"]


class RateLimited(Exception):
    pass


def run_codex(prompt: str, workdir: Path, timeout: int, effort: str) -> str:
    out_file = workdir / f"reply-{threading.get_ident()}-{time.time_ns()}.txt"
    cmd = ["codex", "exec", "-m", MODEL, "-s", "read-only", "-C", str(workdir), "--skip-git-repo-check",
           "--ephemeral", "--ignore-rules", "-c", f'model_reasoning_effort="{effort}"',
           "--output-last-message", str(out_file), prompt]
    try:
        proc = subprocess.run(cmd, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        raise TimeoutError("codex timed out")
    reply = out_file.read_text() if out_file.exists() else ""
    out_file.unlink(missing_ok=True)
    if not reply.strip():
        tail = (proc.stdout + proc.stderr)[-1500:]
        if LIMIT_PATTERN.search(tail):
            raise RateLimited(tail)
        raise RuntimeError(f"codex returned nothing (exit {proc.returncode}): {tail[-300:]}")
    return reply


class Labeller:
    def __init__(self, args, done: set):
        self.args, self.done = args, done
        self.lock = threading.Lock()
        self.stop = threading.Event()
        self.stop_reason = None
        self.workdir = Path(tempfile.mkdtemp(prefix="codex-label-"))
        self.totals = Counter()
        self.drops = Counter()

    def label_batch(self, rows: list) -> None:
        if self.stop.is_set():
            return
        t0, parsed, error = time.time(), None, None
        for attempt in range(self.args.retries + 1):
            try:
                reply = run_codex(build_prompt(rows), self.workdir, self.args.timeout, self.args.effort)
                parsed = parse_reply(reply)
                if parsed is not None and all(r["id"] in parsed for r in rows):
                    break
                error = "unparseable or missing ids"
                parsed = None
            except RateLimited as exc:
                self.stop_reason = f"rate or quota limit: {str(exc)[-400:]}"
                self.stop.set()
                return
            except (TimeoutError, RuntimeError) as exc:
                error = str(exc)[:300]
            if self.stop.is_set():
                return
            time.sleep(5 * (attempt + 1))
        call = {"ids": [r["id"] for r in rows], "seconds": round(time.time() - t0, 1), "error": error if parsed is None else None}
        with self.lock:
            if parsed is not None:
                for row in rows:
                    self.write_row(row, parsed[row["id"]], call["seconds"] / len(rows))
            else:
                self.totals["failed_chunks"] += len(rows)
            with open(self.args.out.with_suffix(".calls.jsonl"), "a") as f:
                f.write(json.dumps(call) + "\n")
            done = self.totals["rows"]
            print(f"[{time.strftime('%H:%M:%S')}] {done} rows labelled, {self.totals['failed_chunks']} failed, "
                  f"last call {call['seconds']}s", flush=True)

    def write_row(self, row: dict, raw, seconds: float) -> None:
        labelled = labelled_row(
            row, raw, f"codex {MODEL} prompt {PROMPT_VERSION} effort {self.args.effort}, filtered by validator",
            "codex", self.args.tier)
        append_row(self.args.out, labelled)
        self.done.add(row["id"])
        self.totals["rows"] += 1
        self.totals["records"] += len(labelled["output"])
        self.drops.update(labelled["notes"]["labeller"]["dropped"])


def batches(rows: list, size: int) -> list:
    """Batch chunks of one meeting together so a call sees related text."""
    return [rows[i:i + size] for i in range(0, len(rows), size)]


def load_rows(args) -> list:
    rows = []
    for path in args.input:
        with open(path, encoding="utf-8") as f:
            rows += [json.loads(line) for line in f]
    if args.sources:
        rows = [r for r in rows if r["source"] in args.sources]
    if args.ids:
        wanted = set(Path(args.ids).read_text().splitlines())
        rows = [r for r in rows if r["id"] in wanted]
    return rows


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--input", nargs="+", required=True, type=Path)
    ap.add_argument("--out", required=True, type=Path)
    ap.add_argument("--sources", nargs="*")
    ap.add_argument("--ids", help="file with one chunk id per line to label")
    ap.add_argument("--tier", help="tier name stored on each row")
    ap.add_argument("--batch", type=int, default=2)
    ap.add_argument("--workers", type=int, default=4)
    ap.add_argument("--limit", type=int, help="label at most this many new rows")
    ap.add_argument("--timeout", type=int, default=600)
    ap.add_argument("--retries", type=int, default=1)
    ap.add_argument("--effort", default="medium")
    args = ap.parse_args()

    args.out.parent.mkdir(parents=True, exist_ok=True)
    done = set()
    if args.out.exists():
        done = {json.loads(line)["id"] for line in open(args.out, encoding="utf-8")}
    todo = [r for r in load_rows(args) if r["id"] not in done]
    if args.limit:
        todo = todo[:args.limit]
    print(f"{len(todo)} rows to label, {len(done)} already done", flush=True)

    labeller = Labeller(args, done)
    with ThreadPoolExecutor(args.workers) as pool:
        list(pool.map(labeller.label_batch, batches(todo, args.batch)))

    state = {"rows_labelled_this_run": labeller.totals["rows"], "records": labeller.totals["records"],
             "failed_chunks": labeller.totals["failed_chunks"], "drops": dict(labeller.drops),
             "stopped_on_limit": labeller.stop_reason, "rows_total_in_file": len(done)}
    args.out.with_suffix(".state.json").write_text(json.dumps(state, indent=1))
    print(json.dumps(state, indent=1))
    return 3 if labeller.stop_reason else 0


if __name__ == "__main__":
    sys.exit(main())
