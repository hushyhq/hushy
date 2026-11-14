"""Build the meeting-extract SFT set: labelled chunk rows -> app-shaped chat rows, split by whole meeting.

    PY=.build/finetune-venv/bin/python
    $PY scripts/meeting-extract/build_sft.py            # writes .build/public-data/meeting-extract/sft/

Row shape follows the next-message adapter (the next-message training data builder): {"id", "messages": [system, user,
assistant]}, the answer is the compact JSON the grammar would force. The app has no extract prompt yet (checked on
feat/meetings-integration, 2026-11-07), so SYSTEM and the user turn below DEFINE it; port them to Swift when the app
adopts the adapter and rerun the crosscheck idea of next_message_crosscheck.py.

Targets: AMI and ICSI chunks keep the annotators' records (human-linked gold) and add the agent records that do not
duplicate them. Every other chunk takes the judge-cleaned agent records. Chunks without any label are not used.
Outputs: train.jsonl, valid.jsonl, train-commercial.jsonl, valid-commercial.jsonl, meta.jsonl (id -> source, licence,
team, target source), manifest.json (sizes in the shape rl_estimate.plan_sft reads).

    $PY scripts/meeting-extract/build_sft.py --public   # writes .build/public-data/meeting-extract/sft-public/

`--public` is the public recipe (training/configs/meeting-extract-public.yaml): AMI and ICSI only, the annotators'
human-linked records only (no model-written labels), commercial-safe rows only (CC BY 4.0, attribution owed).
"""
import hashlib
import json
import os
import re
import sys
from collections import Counter, defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from common import DATA_ROOT, stable_hash, validate_row  # noqa: E402
from transformers import AutoTokenizer  # noqa: E402

LABELS = DATA_ROOT / "labels"
FINAL = DATA_ROOT / "final"
OUT = DATA_ROOT / "sft"
CLEAN_FILES = ["cal-test-v2.clean.jsonl", "elitr-v2.clean.jsonl", "qmsum-v2.clean.jsonl", "notsofar-v2.clean.jsonl",
               "meetingbank-s300-v2.clean.jsonl"]
HUMAN_FILES = ["gold-human.jsonl", "held-r10d-overlap.jsonl"]
SOURCES = {"ami", "icsi", "elitr", "qmsum-committee", "notsofar", "meetingbank"}
PUBLIC_SOURCES = {"ami", "icsi"}  # CC BY 4.0, with the annotators' own linked records
DEV_PERCENT = 10
DEV_SALT = "meeting-extract-dev-v1"
MAX_ROW_TOKENS = 6144          # the config's max_seq_length; longer rows would be cut inside the answer
# The tokenizer used to measure row length (any Qwen3.5 tokenizer folder); HUSHY_TOKENIZER_DIR overrides it.
TOKENIZER_DIR = Path(os.environ.get("HUSHY_TOKENIZER_DIR", Path(__file__).resolve().parents[2] / ".build/hosted-models/hushy-cleanup-4b-r10d-6bit"))
KIND_ORDER = {"decision": 0, "action": 1, "open_question": 2, "change": 3}
FORBIDDEN = ("heldout", "held-out", "sealed", "voicelab", "voice-lab", "application support/hushy", "/ab-", "set-c")

INSTRUCTIONS = (
    "You extract the records a careful minute-taker would write down from one chunk of a meeting transcript.\n"
    "The user message gives the meeting's title, kind, speakers and the chunk position, then the transcript, one line "
    "per turn.\n"
    "Kinds: decision is a settled choice or agreement, including a fixed constraint from the person running the "
    "meeting. action is a task someone takes on or is given, with or without an owner or a time. open_question is a "
    "question the participants say is unresolved and must come back. change reverses, cancels, reschedules or "
    "reassigns something already settled.\n"
    "text is one self-contained sentence, as a summary would write it. quote is copied exactly from one turn, 3 to 80 "
    "words, without the timestamp or the speaker. owner is a speaker label from the list, only for an action someone "
    "took, else null. due is the deadline words as spoken, else null.\n"
    "Never invent names, numbers, dates or owners. List records in the order they occur. If the chunk holds none, "
    "return an empty list."
)
SCHEMA_JSON = (
    '{"additionalProperties":false,"properties":{"records":{"description":"The records in transcript order, or empty",'
    '"items":{"additionalProperties":false,"properties":{"kind":{"enum":["decision","action","open_question","change"],'
    '"type":"string"},"text":{"type":"string"},"owner":{"anyOf":[{"type":"string"},{"type":"null"}]},'
    '"due":{"anyOf":[{"type":"string"},{"type":"null"}]},"quote":{"type":"string"}},'
    '"required":["kind","text","owner","due","quote"],"type":"object","x-order":["kind","text","owner","due","quote"]},'
    '"type":"array"}},"required":["records"],"title":"MeetingRecords","type":"object","x-order":["records"]}'
)
SYSTEM = (f"{INSTRUCTIONS}\n\nReply with only a JSON object that conforms to this JSON schema (each field's "
          f"description says what goes in it):\n{SCHEMA_JSON}")
SYSTEM_SHA256 = hashlib.sha256(SYSTEM.encode()).hexdigest()


def user_turn(row: dict) -> str:
    m = row["input"]["meeting"]
    speakers = ", ".join(m["speakers"]) if m["speakers"] else "not labelled"
    return (f"Meeting: {m['title']} ({m['kind']})\nSpeakers: {speakers}\nChunk: {m['chunk']}\n\n"
            f"Transcript:\n{row['input']['transcript']}\n\nExtract the records.")


def answer(records: list) -> str:
    keys = ("kind", "text", "owner", "due", "quote")
    body = [{k: r[k] for k in keys} for r in records]
    return json.dumps({"records": body}, ensure_ascii=False, separators=(",", ":"))


def read_jsonl(path: Path) -> list:
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]


def team_key(row: dict) -> str:
    """Whole-meeting unit: the design team (series) for AMI, whose four meetings share speakers; the meeting for the rest."""
    return f"{row['source']}:{row['series'] if row['source'] == 'ami' else row['meeting_id']}"


def is_dev(row: dict) -> bool:
    return stable_hash(f"{DEV_SALT}:{team_key(row)}") % 100 < DEV_PERCENT


def turn_of(quote: str, lines: list) -> int:
    for i, line in enumerate(lines):
        if quote in line:
            return i
    return -1


def merge(human: list, agent: list, lines: list) -> list:
    """Human records stay; an agent record is added unless a human record of the same kind sits in the same turn."""
    taken = {(r["kind"], turn_of(r["quote"], lines)) for r in human}
    extra = [r for r in agent if (r["kind"], turn_of(r["quote"], lines)) not in taken]
    return human + extra


def order(records: list, lines: list) -> list:
    return sorted(records, key=lambda r: (turn_of(r["quote"], lines), KIND_ORDER[r["kind"]]))


def load_human() -> dict:
    out = {}
    for name in HUMAN_FILES:
        if not (FINAL / name).exists():
            continue
        for row in read_jsonl(FINAL / name):
            if row["gold"] == "human-linked" and row["output"] is not None:
                out[row["id"]] = row
    return out


def load_targets(public: bool = False) -> tuple:
    """id -> (row, agent records or None, human records or None). Public: human records only."""
    if public:
        return {rid: (row, None, row["output"]) for rid, row in load_human().items() if row["output"] is not None}
    agent = {}
    for name in CLEAN_FILES:
        for row in read_jsonl(LABELS / name):
            agent[row["id"]] = row
    human = load_human()
    targets = {}
    for rid, row in agent.items():
        targets[rid] = (row, row["output"], human[rid]["output"] if rid in human else None)
    for rid, row in human.items():
        if rid not in targets and row["output"]:
            targets[rid] = (row, None, row["output"])
    return targets


def sft_row(row: dict, records: list) -> dict:
    return {"id": row["id"], "messages": [{"role": "system", "content": SYSTEM},
                                          {"role": "user", "content": user_turn(row)},
                                          {"role": "assistant", "content": answer(records)}]}


def count_tokens(tokenizer, messages: list) -> int:
    """Tokens of the chat-templated row through the r10d tokenizer (the same text the trainer packs)."""
    return len(tokenizer(tokenizer.apply_chat_template(messages, tokenize=False))["input_ids"])


def main() -> None:
    public = "--public" in sys.argv[1:]
    tokenizer = AutoTokenizer.from_pretrained(TOKENIZER_DIR)
    targets = load_targets(public)
    seen, rows, skipped = set(), [], Counter()
    for rid in sorted(targets):
        row, agent_records, human_records = targets[rid]
        if row["source"] not in (PUBLIC_SOURCES if public else SOURCES):
            skipped["source not allowed"] += 1
            continue
        if public and not row["commercial_safe"]:
            skipped["not commercial-safe"] += 1
            continue
        lines = row["input"]["transcript"].split("\n")
        if agent_records is None:
            records, origin = human_records, "human-only"
        elif human_records is None:
            records, origin = agent_records, "agent"
        else:
            records, origin = merge(human_records, agent_records, lines), "human+agent"
        records = order(records, lines)
        probe = {**row, "output": records}
        if validate_row(probe):
            skipped["fails validate_row"] += 1
            continue
        digest = hashlib.sha256(row["input"]["transcript"].encode()).hexdigest()
        if digest in seen:
            skipped["duplicate transcript"] += 1
            continue
        seen.add(digest)
        out = sft_row(row, records)
        tokens = count_tokens(tokenizer, out["messages"])
        if tokens > MAX_ROW_TOKENS:
            skipped["over token cap"] += 1
            continue
        notes = json.dumps(row.get("notes", {})).lower()
        if any(f in notes for f in FORBIDDEN):
            skipped["forbidden string in notes"] += 1
            continue
        meta = {"id": rid, "source": row["source"], "licence": row["licence"], "commercial_safe": row["commercial_safe"],
                "meeting_id": row["meeting_id"], "team": team_key(row), "target_source": origin,
                "records": len(records), "dev": is_dev(row), "tokens": tokens}
        rows.append((out, meta))
    write(rows, skipped, DATA_ROOT / "sft-public" if public else OUT, "meeting-extract-public" if public else None)


def write(rows: list, skipped: Counter, out_dir: Path = OUT, round_name: str | None = None) -> None:
    out_dir.mkdir(parents=True, exist_ok=True)
    files = {"train.jsonl": lambda m: not m["dev"], "valid.jsonl": lambda m: m["dev"],
             "train-commercial.jsonl": lambda m: not m["dev"] and m["commercial_safe"],
             "valid-commercial.jsonl": lambda m: m["dev"] and m["commercial_safe"]}
    manifest_files = {}
    for name, keep in files.items():
        chosen = [(r, m) for r, m in rows if keep(m)]
        (out_dir / name).write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r, _ in chosen), encoding="utf-8")
        manifest_files[name] = {"rows": len(chosen), "chars": sum(len(x["content"]) for r, _ in chosen for x in r["messages"]),
                                "tokens": sum(m["tokens"] for _, m in chosen),
                                "empty_targets": sum(m["records"] == 0 for _, m in chosen),
                                "records": sum(m["records"] for _, m in chosen),
                                "bytes": (out_dir / name).stat().st_size}
    (out_dir / "meta.jsonl").write_text("".join(json.dumps(m) + "\n" for _, m in rows), encoding="utf-8")
    by = defaultdict(Counter)
    for _, m in rows:
        by[m["source"]]["dev" if m["dev"] else "train"] += 1
    manifest = {"round": round_name or "meeting-extract-v1", "system_sha256": SYSTEM_SHA256, "files": manifest_files,
                "skipped": dict(skipped), "rows_by_source": {s: dict(c) for s, c in sorted(by.items())},
                "prompt_source": "defined in scripts/meeting-extract/build_sft.py (no extract prompt in the app yet)",
                "split": f"whole team/meeting by sha256('{DEV_SALT}:<team>') % 100 < {DEV_PERCENT}"}
    (out_dir / "manifest.json").write_text(json.dumps(manifest, indent=1) + "\n", encoding="utf-8")
    print(json.dumps({"files": manifest_files, "skipped": manifest["skipped"], "by_source": manifest["rows_by_source"]}, indent=1))


if __name__ == "__main__":
    main()
