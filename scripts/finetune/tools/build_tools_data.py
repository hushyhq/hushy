#!/usr/bin/env python3
"""Builds the voice-actions (tools-v1) fine-tune dataset (docs/product/FINETUNE.md "Voice actions data v1").

    python3 scripts/finetune/tools/build_tools_data.py --out <dir> \
        [--cleanup-pairs <cleanup build>/pairs.jsonl] [--cleanup-share 0.40] [--grammar tool-first]

v2 (hushy-tools-synth-v2) adds the gap generators of `gaps_v2.py` and three not-a-command kinds on
their own random stream / at the end of each LLM plan, so every v1 row and cached call is unchanged.

Stages (LLM answers are cached under .build/finetune-cache/llm, so a rerun is free and identical):
  1. guarded reads: the tools-v1 schema and the actions dev sets (contamination index + aggregate
     shapes only); every input goes through pathguard + sealed_guard, and into the manifest
  2. LLM content banks and not-a-command dictation (`tool_llm.py`, `murmur-eval finetune llm`)
  3. positives from slot grammars (`positives.py`), a paraphrased share, refusals (`refusals.py`),
     ASR shaping (`asr.py`); the LLM-written negatives go through an independent verify pass
  4. contamination (8-gram / whole-text vs every actions dev text), conflicting-label dedupe
  5. `murmur-eval finetune tools-check`: schema, pre-screen, VoiceToolGuard, sensitive screen,
     grounding, DateAnchor, SpokenDuration, grammar acceptance, envelope round trip
  6. balance to the per-tool / per-reason targets, split by seed, `finetune tools-export`
  7. cleanup replay slice (`mix_cleanup.py`) re-prepared under today's rules, mixed in
  8. manifest.json: every file read/written + SHA-256, prompt version + system SHA, counts,
     validator pass rates, held-out proof
"""

from __future__ import annotations

import argparse
import collections
import datetime as dt
import hashlib
import json
import random
import re
import subprocess
import sys
from pathlib import Path
from typing import Any
from zoneinfo import ZoneInfo

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent))
sys.path.insert(0, str(HERE.parents[1]))

import asr  # noqa: E402
import banks  # noqa: E402
import gaps_v2  # noqa: E402
import mix_cleanup  # noqa: E402
import positives  # noqa: E402
import refusals  # noqa: E402
import tool_llm  # noqa: E402
from pathguard import ACTIONS_DEV_ALLOWLIST, Manifest, check  # noqa: E402
from positives import Content, Draft, Slot  # noqa: E402
from sealed_guard import assert_tuning_safe  # noqa: E402
from shapes import words  # noqa: E402

ROOT = HERE.parents[2]
SEED = 11
SPLIT_SEED = "hushy-tools-v1"
# v2 appends kinds at the end of each plan, so every v1 prompt (and its cached answer) is unchanged.
BANK_PLAN = {"reminder": 10, "event": 10, "location": 4, "list_entry": 6, "note": 10, "message": 10, "email": 12,
             "issue": 10, "shortcut": 3, "timer_label": 2, "meeting": 10, "email_ask": 3}
NEG_PLAN = {"mention": 8, "reported": 8, "question": 5, "chat": 10, "ai_prompt": 7, "longform": 4, "pasted": 3,
            "note_prose": 4, "open_prose": 4, "recipe": 3}
# Final rows per tool (≥ 250 each) and per no_action reason (≥ 40% of the tool rows together).
TOOL_TARGETS = {"create_reminder": 330, "create_event": 320, "add_to_list": 260, "save_note": 270, "open_app": 250,
                "run_shortcut": 250, "set_timer": 250, "propose_email_draft": 260, "propose_message": 290,
                "propose_issue": 250, "propose_calendar_invite": 260}
REASON_TARGETS = {"not_a_command": 1600, "needs_clarification": 200, "unsupported": 230, "sensitive_content": 180,
                  "multi_intent": 200}
NOT_A_COMMAND_MIX = {"mention": 260, "reported": 260, "question": 150, "chat": 260, "ai_prompt": 210, "longform": 110, "pasted": 50,
                     "note_prose": 120, "open_prose": 120, "recipe": 60}
DATASET = "hushy-tools-synth-v2"
OVERSAMPLE = 1.5
PARAPHRASE_SHARE = 0.3
CROSS_TOOL_SHARE = 0.04
INJECTED_NOTES = 40
PARAPHRASE_BATCH = 25
VERIFY_BATCH = 50


# -- stage 1: guarded reads ------------------------------------------------------------------------


def guarded_json(manifest: Manifest, path: Path, dev_set: bool = False) -> Any:
    assert_tuning_safe(str(path), purpose="voice-actions data builder")
    return manifest.read_json(path, dev_set=dev_set, allowlist=ACTIONS_DEV_ALLOWLIST)


def guarded_jsonl(manifest: Manifest, path: Path) -> list[dict[str, Any]]:
    assert_tuning_safe(str(path), purpose="voice-actions data builder")
    return manifest.read_jsonl(path)


class Contamination:
    """Index over every text in the actions dev sets: a training utterance is dropped when it
    shares an 8-gram with a dev text or equals one; a positive is dropped when any copied label
    value of two or more words equals a dev label value (short values slip past n-grams)."""

    def __init__(self, texts: list[str], values: list[str] | None = None, n: int = 8) -> None:
        self.n = n
        self.whole = {" ".join(words(t)) for t in texts}
        self.grams = {tuple(ws[i : i + n]) for t in texts for ws in [words(t)] for i in range(len(ws) - n + 1)}
        self.values = {" ".join(words(v)) for v in values or [] if len(words(v)) >= 2}

    def hits(self, text: str) -> bool:
        ws = words(text)
        return " ".join(ws) in self.whole or any(tuple(ws[i : i + self.n]) in self.grams for i in range(len(ws) - self.n + 1))

    def label_hits(self, call: dict[str, Any]) -> bool:
        for key, value in call["args"].items():
            if key in ("channel", "tracker", "reason", "duration_minutes"):
                continue
            if any(" ".join(words(v)) in self.values for v in (value if isinstance(value, list) else [value])):
                return True
        return False


def dev_values(dev: dict[str, Any]) -> list[str]:
    """Every expected argument value (and accepted alternative) in the dev set."""
    out: list[str] = []
    for case in dev["cases"]:
        expect = case["expect"]
        pools = [expect.get("args", {})] + [alt.get("args", {}) for alt in expect.get("alternatives") or []]
        pools += [call.get("args", {}) for call in expect.get("split") or []]
        values = [v for pool in pools for v in pool.values()] + [v for vs in (expect.get("accept") or {}).values() for v in vs]
        for value in values:
            out += [x for x in (value if isinstance(value, list) else [value]) if isinstance(x, str)]
    return out


def dev_texts(dev: dict[str, Any], golden: list[Any], adversarial: list[Any]) -> list[str]:
    """Every utterance (any length: "open it" as a whole utterance is a dev case too) plus the
    longer argument values (a one- or two-word value like "slack" is vocabulary, not a case)."""
    utterances = [case["utterance"] for case in dev["cases"]] + [case.get("utterance", "") for case in golden]
    utterances += [case.get(key, "") for case in adversarial for key in ("spoken", "expected")]
    values: list[str] = []
    for case in dev["cases"]:
        for value in case["expect"].get("args", {}).values():
            values += value if isinstance(value, list) else [str(value)]
    return [t for t in utterances if isinstance(t, str) and words(t)] + [v for v in values if len(words(v)) >= 3]


def dev_shapes(dev: dict[str, Any]) -> dict[str, Any]:
    """Aggregate counts only (no utterance ever leaves the dev file)."""
    cases = dev["cases"]
    return {
        "cases": len(cases),
        "byCategory": dict(collections.Counter(c["category"] for c in cases)),
        "byDecisionTool": dict(collections.Counter(f"{c['expect']['decision']}:{c['expect']['tool']}" for c in cases)),
        "byLocale": dict(collections.Counter(c["context"]["locale"] for c in cases)),
        "noActionShare": round(sum(c["expect"]["tool"] == "no_action" for c in cases) / len(cases), 3),
    }


# Stricter than SensitiveContentScreen (which only flags a value with a digit/symbol or quotes after
# "is"): a positive call whose utterance names a secret followed by a value is never trained on.
SECRET = re.compile(r"\b(password|passcode|passphrase|pin|otp|cvv|ssn|social security( number)?|aadhaar( number)?|"
                    r"account number|routing number|card number|api key|secret key|verification code|2fa code|"
                    r"one time code|door code)\b(\s+(is|was|number is|code is))?\s+(\d|[a-z]+\s*\d)")


def list_convention_ok(call: dict[str, Any]) -> bool:
    """The list-item convention (`gaps_v2.py`): an item may contain "and" only as a fixed binomial."""
    if call["tool"] != "add_to_list":
        return True
    return all(" and " not in f" {item} " or item in gaps_v2.BINOMIALS for item in call["args"]["items"])


def check_schema(schema: dict[str, Any], call: dict[str, Any]) -> str | None:
    """The published tools-v1 JSON Schema, checked in Python too (the Swift check is the gate)."""
    tools = {t["name"]: t["input_schema"] for t in schema["tools"]}
    spec = tools.get(call["tool"])
    if spec is None:
        return "unknown tool"
    for key, value in call["args"].items():
        prop = spec["properties"].get(key)
        if prop is None:
            return f"unknown argument {key}"
        kinds = prop["type"] if isinstance(prop["type"], list) else [prop["type"]]
        ok = any((k == "string" and isinstance(value, str) and value.strip()) or (k == "integer" and isinstance(value, int))
                 or (k == "array" and isinstance(value, list) and value and all(isinstance(v, str) and v.strip() for v in value))
                 for k in kinds)
        if not ok or ("enum" in prop and value not in prop["enum"]):
            return f"bad value for {key}"
    missing = [k for k in spec.get("required", []) if k not in call["args"]]
    return f"missing {missing}" if missing else None


# -- stage 2: LLM ----------------------------------------------------------------------------------


def run_eval(binary: Path, *args: str) -> None:
    command = [str(binary), "finetune", *args]
    print("$", " ".join(command[1:3]), flush=True)
    subprocess.run(command, cwd=ROOT, check=True)


def llm(args: argparse.Namespace, manifest: Manifest, name: str, rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    prompts, answers = args.out / f"llm/{name}-prompts.jsonl", args.out / f"llm/{name}-responses.jsonl"
    manifest.write_jsonl(prompts, rows)
    run_eval(args.eval_bin, "llm", "--in", str(prompts), "--out", str(answers), "--llm", args.llm, "--model", args.llm_model,
             "--max-calls", str(args.llm_calls))
    manifest.sections.setdefault("llm", {"backend": args.llm, "model": args.llm_model, "stages": {}})["stages"][name] = {
        "calls": len(rows), "promptsSHA256": {r["id"]: hashlib.sha256(r["prompt"].encode()).hexdigest()[:16] for r in rows}}
    return guarded_jsonl(manifest, answers)


def content_banks(responses: list[dict[str, Any]]) -> dict[str, list[Any]]:
    bank: dict[str, list[Any]] = collections.defaultdict(list)
    seen: set[str] = set()
    for response in responses:
        for item in tool_llm.parse(response.get("text")):
            key = json.dumps(item, sort_keys=True)
            if key in seen:
                continue
            seen.add(key)
            clean = clean_bank_item(response["kind"], item)
            if clean is not None:
                bank[response["kind"]].append(clean)
    return bank


def clean_bank_item(kind: str, item: Any) -> Any:
    def text(value: Any, lo: int, hi: int) -> str | None:
        if not isinstance(value, str):
            return None
        value = asr.asr_text(value)
        return value if lo <= len(value.split()) <= hi else None

    if kind in ("reminder", "event", "location", "message", "shortcut", "timer_label", "email_ask"):
        limits = {"reminder": (2, 10), "event": (1, 7), "location": (1, 7), "message": (2, 22), "shortcut": (1, 5), "timer_label": (1, 4),
                  "email_ask": (3, 16)}[kind]
        return text(item, *limits)
    if not isinstance(item, dict):
        return None
    if kind == "list_entry":
        items = [x for x in (text(i, 1, 4) for i in item.get("items") or []) if x]
        name = text(item.get("list"), 1, 4)
        return {"list": name.removesuffix(" list"), "items": sorted(set(items))} if name and len(set(items)) >= 3 else None
    if kind == "note":
        body = text(item.get("text"), 4, 30)
        return {"text": body, "title": text(item.get("title"), 1, 5)} if body else None
    if kind == "email":
        body = text(item.get("body"), 6, 40)
        return {"body": body, "subject": text(item.get("subject"), 1, 6)} if body else None
    if kind == "issue":
        title = text(item.get("title"), 2, 12)
        return {"title": title, "description": text(item.get("description"), 4, 25)} if title else None
    if kind == "meeting":
        title = text(item.get("title"), 1, 7)
        return {"title": title, "notes": text(item.get("notes"), 3, 14)} if title else None
    return None


# -- stage 3: examples -----------------------------------------------------------------------------


def context(rng: random.Random, locale: str | None = None, front: str | None = "random") -> dict[str, Any]:
    locale = locale or ("en_IN" if rng.random() < 0.25 else "en_US")
    zone = banks.IN_ZONE if locale == "en_IN" else rng.choice(banks.US_ZONES)
    day = dt.date(2026, 10, 1) + dt.timedelta(days=rng.randint(0, 181))
    now = dt.datetime(day.year, day.month, day.day, rng.randint(7, 22), rng.randint(0, 59), tzinfo=ZoneInfo(zone))
    if front == "random":
        roll = rng.random()
        front = (None if roll < 0.45 else rng.choice(list(banks.CHAT_APPS)) if roll < 0.7
                 else rng.choice(list(banks.TRACKER_APPS)) if roll < 0.75 else rng.choice(banks.FRONT_APPS_OTHER))
    return {"now": now.isoformat(), "timeZone": zone, "locale": locale, "frontmostApp": front}


def row(draft: Draft, ctx: dict[str, Any], kind: str, source: str, seed_id: str, tags: list[str]) -> dict[str, Any]:
    args = {k: (v if k in ("channel", "tracker", "reason", "duration_minutes") else asr.asr_value(v)) for k, v in draft.args.items()}
    return {"id": seed_id, "seedId": seed_id, "utterance": asr.join(draft.segments), "context": ctx,
            "call": {"tool": draft.tool, "args": args}, "kind": kind, "source": source, "tags": sorted(set(draft.tags + tags))}


def marked(draft: Draft) -> str:
    return " ".join(f"[[{asr.asr_text(s.spoken)}]]" if isinstance(s, Slot) else asr.asr_text(s) for s in draft.segments if (s.spoken if isinstance(s, Slot) else s))


def resegment(text: str) -> list[Any]:
    out: list[Any] = []
    for index, part in enumerate(tool_llm.SLOT.split(text)):
        out.append(Slot(part) if index % 2 else asr.asr_text(part))
    return out


def make_positives(rng: random.Random, content: Content) -> list[tuple[Draft, dict[str, Any], str]]:
    drafts = []
    for tool, target in TOOL_TARGETS.items():
        for index in range(int(target * OVERSAMPLE)):
            ctx = context(rng)
            draft = positives.GENERATORS[tool](rng, content, ctx)
            if rng.random() < CROSS_TOOL_SHARE:
                draft = positives.cross_tool_correction(draft, rng)
            drafts.append((draft, ctx, f"pos-{tool}-{index:04d}"))
    for index in range(int(INJECTED_NOTES * OVERSAMPLE)):
        ctx = context(rng)
        drafts.append((refusals.injected_note(rng, content, ctx), ctx, f"pos-injnote-{index:04d}"))
    return drafts


def paraphrase(args: argparse.Namespace, manifest: Manifest, rng: random.Random,
               drafts: list[tuple[Draft, dict[str, Any], str]], stage: str = "paraphrase") -> dict[str, list[Any]]:
    chosen = [d for d in drafts if rng.random() < PARAPHRASE_SHARE and "tool-switch" not in d[0].tags]
    items = [{"id": seed, "locale": ctx["locale"], "text": marked(draft)} for draft, ctx, seed in chosen]
    responses = llm(args, manifest, stage, tool_llm.batch_prompts(tool_llm.PARAPHRASE, "para", items, PARAPHRASE_BATCH))
    originals = {item["id"]: item["text"] for item in items}
    tools = {seed: draft.tool for draft, _, seed in chosen}
    out: dict[str, list[Any]] = {}
    for response in responses:
        for answer in tool_llm.parse(response.get("text")):
            if not isinstance(answer, dict) or answer.get("id") not in originals or not isinstance(answer.get("text"), str):
                continue
            text = answer["text"].lower()
            if (tool_llm.paraphrase_ok(originals[answer["id"]], text) and text.strip() != originals[answer["id"]]
                    and tool_llm.keeps_trigger(tools[answer["id"]], text)):
                out[answer["id"]] = resegment(text)
    manifest.sections[stage] = {"asked": len(items), "kept": len(out)}
    return out


def make_v2(rng: random.Random, content: Content) -> list[tuple[Draft, dict[str, Any], str]]:
    """The v2 gap generators (`gaps_v2.py`), on their own random stream."""
    out = []
    for name, (generate, target) in gaps_v2.GENERATORS_V2.items():
        for index in range(int(target * OVERSAMPLE)):
            ctx = context(rng)
            draft = generate(rng, content, ctx)
            draft.tags.append(f"v2:{name}")
            out.append((draft, ctx, f"v2-{name}-{index:04d}"))
    return out


def v2_quota() -> dict[str, int]:
    quota: dict[str, int] = collections.Counter()
    probe = random.Random(0)
    for name, (generate, target) in gaps_v2.GENERATORS_V2.items():
        quota[gaps_v2.label_of(generate(probe, Content({}, probe), context(probe)))] += target
    return dict(quota)


def make_refusals(rng: random.Random, content: Content) -> list[tuple[Draft, dict[str, Any], str]]:
    out = []
    for reason, target in REASON_TARGETS.items():
        if reason == "not_a_command":
            continue
        for index in range(int(target * OVERSAMPLE)):
            ctx = context(rng)
            out.append((refusals.REFUSALS[reason](rng, content, ctx), ctx, f"ref-{reason}-{index:04d}"))
    return out


def llm_negatives(args: argparse.Namespace, manifest: Manifest, rng: random.Random) -> list[dict[str, Any]]:
    responses = llm(args, manifest, "negatives", tool_llm.negative_prompts(NEG_PLAN))
    candidates = []
    seen: set[str] = set()
    for response in responses:
        for index, item in enumerate(tool_llm.parse(response.get("text"))):
            text = asr.asr_text(item) if isinstance(item, str) else ""
            if not 3 <= len(text.split()) <= 35 or text in seen:
                continue
            seen.add(text)
            front = response.get("app") or None
            ctx = context(rng, front=front if front else "random")
            draft = Draft([text], "no_action", {"reason": "not_a_command"}, ["false-fire", response["kind"]])
            shaped, tags = asr.shape(draft.segments, rng, rate=0.6)
            draft.segments = shaped
            candidates.append(row(draft, ctx, f"neg:not_a_command:{response['kind']}", "llm", f"{response['id']}#{index}", tags))
    # Independent second opinion: anything that reads as a command to the app is dropped.
    items = [{"id": r["id"], "frontmost_app": r["context"]["frontmostApp"] or "unknown", "text": r["utterance"]} for r in candidates]
    verdicts: dict[str, str] = {}
    for response in llm(args, manifest, "verify", tool_llm.batch_prompts(tool_llm.VERIFY, "verify", items, VERIFY_BATCH)):
        for answer in tool_llm.parse(response.get("text")):
            if isinstance(answer, dict) and isinstance(answer.get("id"), str):
                verdicts[answer["id"]] = str(answer.get("verdict", ""))
    kept = [r for r in candidates if verdicts.get(r["id"]) == "dictation"]
    manifest.sections["notACommandVerify"] = {
        "candidates": len(candidates), "judgedDictation": len(kept),
        "judgedCommand": sum(v == "command" for v in verdicts.values()), "unjudged": len(candidates) - len(verdicts),
        "byKind": dict(collections.Counter(r["kind"].rsplit(":", 1)[1] for r in kept)),
    }
    return kept


# -- stages 4–6 --------------------------------------------------------------------------------------


def dedupe(rows: list[dict[str, Any]]) -> tuple[list[dict[str, Any]], int]:
    """One row per utterance; an utterance generated with two different labels is dropped entirely."""
    by_text: dict[str, list[dict[str, Any]]] = collections.defaultdict(list)
    for r in rows:
        by_text[" ".join(words(r["utterance"]))].append(r)
    out, conflicts = [], 0
    for group in by_text.values():
        labels = {json.dumps(r["call"], sort_keys=True) for r in group}
        if len(labels) > 1:
            conflicts += len(group)
            continue
        out.append(group[0])
    return out, conflicts


def label_key(r: dict[str, Any]) -> str:
    call = r["call"]
    return call["args"]["reason"] if call["tool"] == "no_action" else call["tool"]


def balance(rows: list[dict[str, Any]], rng: random.Random) -> list[dict[str, Any]]:
    """Draw each tool / reason to its target; self-corrections, paraphrases and hard kinds first."""
    by: dict[str, list[dict[str, Any]]] = collections.defaultdict(list)
    extra: dict[str, list[dict[str, Any]]] = collections.defaultdict(list)
    for r in rows:
        (extra if any(t.startswith("v2:") for t in r["tags"]) else by)[label_key(r)].append(r)
    chosen: list[dict[str, Any]] = []
    for key, quota in v2_quota().items():
        pool = sorted(extra.get(key, []), key=lambda r: r["seedId"])
        rng.shuffle(pool)
        per_kind: dict[str, list[dict[str, Any]]] = collections.defaultdict(list)
        for r in pool:
            per_kind[next(t for t in r["tags"] if t.startswith("v2:"))].append(r)
        want = {f"v2:{name}": target for name, (_, target) in gaps_v2.GENERATORS_V2.items()}
        for kind, group in per_kind.items():
            chosen += group[: want.get(kind, len(group))]
    for key, target in {**TOOL_TARGETS, **REASON_TARGETS}.items():
        pool = by.get(key, [])
        rng.shuffle(pool)
        if key == "not_a_command":
            chosen += not_a_command_mix(pool)
            continue
        if key == "save_note":
            injected = [r for r in pool if "injection" in r["tags"]][:INJECTED_NOTES]
            pool = injected + [r for r in pool if "injection" not in r["tags"]]
        pool.sort(key=lambda r: ("self-correction" not in r["tags"], r["source"] != "paraphrase"))
        corrections = [r for r in pool if "self-correction" in r["tags"]][: int(target * 0.14)]
        rest = [r for r in pool if r not in corrections]
        rng.shuffle(rest)
        rest.sort(key=lambda r: "injection" not in r["tags"])
        chosen += corrections + rest[: target - len(corrections)]
    rng.shuffle(chosen)
    return chosen


def not_a_command_mix(pool: list[dict[str, Any]]) -> list[dict[str, Any]]:
    by_kind: dict[str, list[dict[str, Any]]] = collections.defaultdict(list)
    for r in pool:
        by_kind[r["kind"].rsplit(":", 1)[1]].append(r)
    out = []
    for kind, want in NOT_A_COMMAND_MIX.items():
        out += by_kind.get(kind, [])[:want]
    spare = [r for r in pool if r not in out]
    return out + spare[: max(0, REASON_TARGETS["not_a_command"] - len(out))]


def pass_rates(checked: list[dict[str, Any]]) -> dict[str, float]:
    groups: dict[str, list[dict[str, Any]]] = collections.defaultdict(list)
    for r in checked:
        groups[label_key(r)].append(r)
    return {k: round(sum(not r["rejection"] for r in g) / len(g), 3) for k, g in sorted(groups.items())}


def stable_fraction(key: str) -> float:
    return int(hashlib.sha256(f"{SPLIT_SEED}|{key}".encode()).hexdigest()[:8], 16) / 0xFFFFFFFF


def stats(rows: list[dict[str, Any]]) -> dict[str, Any]:
    total = len(rows)
    no_action = sum(r["call"]["tool"] == "no_action" for r in rows)
    return {
        "total": total, "train": sum(r.get("split") == "train" for r in rows), "valid": sum(r.get("split") == "valid" for r in rows),
        "noActionShare": round(no_action / max(1, total), 3),
        "byLabel": dict(collections.Counter(label_key(r) for r in rows).most_common()),
        "bySource": dict(collections.Counter(r["source"] for r in rows).most_common()),
        "byKind": dict(collections.Counter(r["kind"] for r in rows).most_common()),
        "byLocale": dict(collections.Counter(r["context"]["locale"] for r in rows)),
        "selfCorrections": sum("self-correction" in r["tags"] for r in rows),
        "byV2Generator": dict(collections.Counter(t for r in rows for t in r["tags"] if t.startswith("v2:"))),
        "selfCorrectionsByTool": dict(collections.Counter(label_key(r) for r in rows if "self-correction" in r["tags"])),
        "disfluent": sum(any(t in r["tags"] for t in ("lead-filler", "mid-filler", "repeat", "restart", "tail")) for r in rows),
        "withWhen": sum("when" in r["call"]["args"] for r in rows),
        "utteranceWordsMedian": sorted(len(r["utterance"].split()) for r in rows)[total // 2] if rows else 0,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out", type=Path, required=True)
    built = [p for p in (ROOT / ".build/release/murmur-eval", ROOT / ".build/debug/murmur-eval") if p.exists()]
    parser.add_argument("--eval-bin", type=Path, default=max(built, key=lambda p: p.stat().st_mtime) if built else None,
                        help="murmur-eval with the finetune tools-* subcommands (default: the newer of release/debug)")
    parser.add_argument("--llm", default="claude")
    parser.add_argument("--llm-model", default="haiku")
    parser.add_argument("--llm-calls", type=int, default=120, help="uncached LLM calls allowed per stage")
    parser.add_argument("--grammar", default="tool-first", choices=["tool-first", "strict"])
    parser.add_argument("--cleanup-pairs", type=Path, default=None, help="a cleanup build's pairs.jsonl (replay slice)")
    parser.add_argument("--cleanup-share", type=float, default=0.40)
    parser.add_argument("--valid-share", type=float, default=0.08)
    args = parser.parse_args()
    args.out = check(args.out.resolve())
    args.out.mkdir(parents=True, exist_ok=True)
    manifest = Manifest(ROOT)
    rng = random.Random(SEED)

    schema = guarded_json(manifest, ROOT / "Evals/tools-v1.schema.json", dev_set=True)
    dev = guarded_json(manifest, ROOT / "Evals/actions-tools-dev.json", dev_set=True)
    golden = guarded_json(manifest, ROOT / "Evals/actions-golden.json", dev_set=True)
    adversarial = guarded_json(manifest, ROOT / "Evals/adversarial-golden.json", dev_set=True)
    index = Contamination(dev_texts(dev, golden, adversarial), dev_values(dev))
    manifest.sections["devShapes"] = dev_shapes(dev)

    content = Content(content_banks(llm(args, manifest, "banks", tool_llm.bank_prompts(BANK_PLAN))), rng)
    manifest.sections["contentBanks"] = {k: len(v) for k, v in content.bank.items()}
    drafts = make_positives(rng, content)
    paraphrases = paraphrase(args, manifest, rng, drafts)
    candidates = []
    for draft, ctx, seed in drafts + make_refusals(rng, content):
        source = "template"
        if seed in paraphrases:
            draft = Draft(paraphrases[seed], draft.tool, draft.args, draft.tags)
            source = "paraphrase"
        shaped, tags = asr.shape(draft.segments, rng)
        kind = f"pos:{draft.tool}" if draft.tool != "no_action" else f"neg:{draft.args['reason']}"
        candidates.append(row(Draft(shaped, draft.tool, draft.args, draft.tags), ctx, kind, source, seed, tags))
    # v2 gap rows: their own random stream and paraphrase stage, so every v1 row above is unchanged.
    rng2 = random.Random(SEED + 10)
    drafts2 = make_v2(rng2, content)
    paraphrases2 = paraphrase(args, manifest, rng2, [d for d in drafts2 if d[0].tool != "no_action"], stage="paraphrase-v2")
    for draft, ctx, seed in drafts2:
        source = "template"
        if seed in paraphrases2:
            draft = Draft(paraphrases2[seed], draft.tool, draft.args, draft.tags)
            source = "paraphrase"
        shaped, tags = asr.shape(draft.segments, rng2)
        kind = f"pos:{draft.tool}" if draft.tool != "no_action" else f"neg:{draft.args['reason']}"
        candidates.append(row(Draft(shaped, draft.tool, draft.args, draft.tags), ctx, kind, source, seed, tags))
    # Own RNG: the not-a-command stage (and its cached verify calls) doesn't move when the positives change.
    candidates += llm_negatives(args, manifest, random.Random(SEED + 2))

    counts: dict[str, Any] = {"candidates": len(candidates)}
    schema_bad = [r for r in candidates if check_schema(schema, r["call"])]
    counts["pythonSchemaRejected"] = len(schema_bad)
    rows = [r for r in candidates if not check_schema(schema, r["call"])]
    before = len(rows)
    rows = [r for r in rows if not index.hits(r["utterance"])]
    counts["droppedContamination"] = before - len(rows)
    before = len(rows)
    rows = [r for r in rows if not index.label_hits(r["call"])]
    counts["droppedDevLabelValue"] = before - len(rows)
    before = len(rows)
    rows = [r for r in rows if r["call"]["tool"] == "no_action" or not SECRET.search(r["utterance"])]
    counts["droppedSecretInPositive"] = before - len(rows)
    before = len(rows)
    rows = [r for r in rows if list_convention_ok(r["call"])]
    counts["droppedListConvention"] = before - len(rows)
    rows, counts["droppedConflictingLabels"] = dedupe(rows)

    path_in, path_out = args.out / "work/check-in.jsonl", args.out / "work/check-out.jsonl"
    manifest.write_jsonl(path_in, rows)
    run_eval(args.eval_bin, "tools-check", "--in", str(path_in), "--out", str(path_out), "--grammar", args.grammar)
    checked = guarded_jsonl(manifest, path_out)
    rejected = collections.Counter(r["rejection"].split(":")[0] for r in checked if r["rejection"])
    counts["validator"] = {
        "checked": len(checked), "accepted": sum(not r["rejection"] for r in checked),
        "passRate": round(sum(not r["rejection"] for r in checked) / max(1, len(checked)), 4),
        "rejectedByReason": dict(rejected.most_common()),
        "passRateByLabel": pass_rates(checked),
    }
    accepted = [r for r in checked if not r["rejection"]]
    final = balance(accepted, random.Random(SEED + 1))
    for r in final:
        r["split"] = "valid" if stable_fraction(r["seedId"]) < args.valid_share else "train"
    manifest.write_jsonl(args.out / "tools-rows.jsonl", final)
    run_eval(args.eval_bin, "tools-export", "--in", str(args.out / "tools-rows.jsonl"), "--out-dir", str(args.out / "mlx-tools"),
             "--grammar", args.grammar)
    for name in ("train.jsonl", "valid.jsonl", "export.json"):
        manifest.record_write(args.out / "mlx-tools" / name)
    export = json.loads((args.out / "mlx-tools/export.json").read_text())
    manifest.sections["prompt"] = {k: export[k] for k in ("promptVersion", "catalog", "grammar", "systemSHA256", "userTemplate")}
    counts["final"] = stats(final)

    mix = mix_cleanup.build(args, manifest, tools_rows=len(final), run_eval=run_eval, guarded_jsonl=guarded_jsonl)
    manifest.sections["counts"] = counts
    manifest.sections["mix"] = mix
    manifest.sections["generator"] = {"dataset": DATASET, "seed": SEED, "splitSeed": SPLIT_SEED, "grammar": args.grammar, "targets": {**TOOL_TARGETS, **REASON_TARGETS},
                                      "scripts": "scripts/finetune/tools/"}
    manifest.save(args.out / "manifest.json")
    print(json.dumps({"validator": counts["validator"], "final": counts["final"], "mix": mix}, indent=2))


if __name__ == "__main__":
    main()
