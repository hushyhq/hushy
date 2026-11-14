#!/usr/bin/env python3
"""Builds the synthetic cleanup dataset for the M7 fine-tune (docs/product/FINETUNE.md).

    python3 scripts/finetune/build_data.py --out <dir> [--llm-calls 110] [--jev-calls 170]

Stages (each cached, so a rerun is free and byte-identical):
  1. dev-set shapes + contamination index (allow-listed dev sets only; held-out/Voice Lab refused)
  2. content generation through the CLI LLM (`murmur-eval finetune llm`, cached)
  3. deterministic pair templates (`templates.py`)
  4. contamination filter (8-gram overlap with any dev text → dropped)
  5. canonical targets and the production guards (`murmur-eval finetune prepare`)
  6. Jev rubric v2 (`murmur-eval finetune jev`): every LLM-written label must score pBad < 0.3;
     a random audit sample of template labels is judged too and failing ones are dropped
  7. balance (≥ 30% leave-unchanged), split by seed (validation slice), export
     (`murmur-eval finetune export`: compact prompt + exact JSON answer), manifest
"""

from __future__ import annotations

import argparse
import collections
import hashlib
import json
import random
import re
import subprocess
import sys
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))

import llm_prompts  # noqa: E402
import shapes  # noqa: E402
import templates  # noqa: E402
from pathguard import Manifest, check  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
# v2's 109 calls (cached) + v3's long passages, frame-switch slots and Polished negatives (70 calls).
LLM_PLAN = {"sentences": 45, "lists": 12, "grammar": 20, "corrections": 20, "negatives": 12,
            "long": 25, "frames": 30, "polishedneg": 15,
            # v4 (52 calls): correction-looking negatives, number-keeping agreement, tense, garbled.
            "frameneg": 15, "agreement": 12, "tense": 10, "garbled": 15,
            # v4b (8 calls): "I mean"/"rather"/"make that" as content, not a correction.
            "meanneg": 8,
            # v5 (18 calls): casual "like" kept, existential agreement, double-negative seeds.
            "casualneg": 6, "existential": 6, "negation": 6,
            # v5.2 (30 calls): the grammar shapes v5.1 still missed, LLM-written, Jev-filtered.
            "garbledmiss": 30,
            # v5.2 (5 calls): subject + modal sentences for the dangling-modal restart templates.
            "modalseed": 5,
            # v5.4 (65 calls): negative robustness — 3 batches per register (15 registers), plus
            # "tempting" negatives a fluent editor would want to rephrase.
            "registerneg": 45, "temptingneg": 20,
            # v5.5 (32 calls): "and … and … because" run-on splits (Jev-filtered), meaningful
            # "actually"/"sort of"/"honestly" kept, and more technical/code-ish/number negatives.
            "runonchain": 12, "meaningneg": 5, "techneg": 15}
# Kinds a balanced draw always keeps (the shapes v3 exists for).
PRIORITY_CHANGED = ("correction-in-frame", "discourse-filler:", "llm-grammar:runon-chain", "hedge-lead:", "llm-grammar:miss-", "modal-restart", "garbled-hedge-restart", "frame:", "long:", "agreement:", "tense", "llm-grammar:garbled", "list:inline", "correction-varied:",
                    "article:", "existential", "double-negative")
PRIORITY_UNCHANGED = ("negative:meaning-", "negative:register-", "negative:tempting", "negative:bare-series", "negative:frame-", "negative:ack-", "negative:casual-like", "negative:mean-", "negative:polished-",
                      "clean-keeps-grammar:", "list:inline")
# v5.3: only the new kind; the earlier kinds were audited in their own versions (answers reused).
AUDIT_KINDS = ("correction-in-frame", "discourse-filler:")  # v5.5; earlier kinds reuse their answers
# v5.4: leave-unchanged rows audited by Jev at Polished (is the text really fine as dictated?).
NEG_AUDIT_KINDS = ("negative:meaning-", "negative:register-", "negative:tempting")
# Registers whose texts get a punctuation-only twin (lower-case, unpunctuated → as written). Not
# casual/social/code-ish, where lower case and bare punctuation are the style.
PUNCT_ONLY_REGISTERS = {"formal-email", "technical", "names-numbers", "meeting-notes", "support-reply", "clinical",
                        "legal-admin", "academic", "instructions", "quotes", "parenting-school", "long-form"}
PUNCT_ONLY_SHARE = 0.35
# Tempting negatives left out: a sentence-initial "Like," / "I mean," / "Honestly, I mean" is a
# discourse filler Clean may remove, and a dash-interrupted sentence is a real restart. The Jev
# audit failed these as "disfluency left" (v5.4 pass 1: 9 of the 13 tempting fails).
TEMPTING_AMBIGUOUS = re.compile(r"^(?:like|i mean|honestly,? i mean|so,? like|well,? like)\b|—|--|\bi mean,? i\b", re.I)
# v5: share of sentence seeds that get a varied-cue correction (v4: 0.25), and of "I mean"-as-content
# negatives kept (v4: all; v4's Disfl-QA recall dropped 60.8 → 56.1).
VARIED_SHARE = 0.5
MEAN_NEGATIVE_KEEP = 0.5
GENERATOR_SEED = 7
SPLIT_SEED = "hushy-ft-v1"


def run_eval(binary: Path, *args: str) -> None:
    command = [str(binary), "finetune", *args]
    print("$", " ".join(command[1:]), flush=True)
    subprocess.run(command, cwd=ROOT, check=True)


def stable_fraction(key: str) -> float:
    return int(hashlib.sha256(f"{SPLIT_SEED}|{key}".encode()).hexdigest()[:8], 16) / 0xFFFFFFFF


# -- stage 2: content ----------------------------------------------------------------------------


def generate_content(args: argparse.Namespace, manifest: Manifest) -> list[dict[str, Any]]:
    prompts_path = args.out / "llm-prompts.jsonl"
    responses_path = args.out / "llm-responses.jsonl"
    rows = llm_prompts.build_prompts(LLM_PLAN)
    manifest.write_jsonl(prompts_path, rows)
    manifest.sections["llm"] = {
        "backend": args.llm, "model": args.llm_model, "plannedCalls": sum(LLM_PLAN.values()), "plan": LLM_PLAN,
        "promptsSHA256": {row["id"]: hashlib.sha256(row["prompt"].encode()).hexdigest()[:16] for row in rows},
    }
    # Earlier builds' answers are reused by prompt id (prompts are deterministic per id); only
    # missing prompts go to the CLI. The CLI's own cache lives in a worktree's .build and doesn't
    # survive it, so the responses files are the durable record.
    have: dict[str, dict[str, Any]] = {}
    for path in args.prior_llm or []:
        for row in manifest.read_jsonl(path):
            if row.get("text"):
                have[row["id"]] = row
    if responses_path.exists() and not args.refresh_llm:
        for row in manifest.read_jsonl(responses_path):
            if row.get("text"):
                have[row["id"]] = row
    missing = [row for row in rows if row["id"] not in have]
    if missing:
        pending_in, pending_out = args.out / "work/llm-pending.jsonl", args.out / "work/llm-pending-out.jsonl"
        manifest.write_jsonl(pending_in, missing)
        run_eval(args.eval_bin, "llm", "--in", str(pending_in), "--out", str(pending_out),
                 "--llm", args.llm, "--model", args.llm_model, "--max-calls", str(args.llm_calls))
        for row in manifest.read_jsonl(pending_out):
            if row.get("text"):
                have[row["id"]] = row
    manifest.sections["llm"]["newCalls"] = len(missing)
    responses = [have[row["id"]] for row in rows if row["id"] in have]
    manifest.write_jsonl(responses_path, responses)
    return responses


def parse_seeds(responses: list[dict[str, Any]]) -> dict[str, list[dict[str, Any]]]:
    seeds: dict[str, list[dict[str, Any]]] = collections.defaultdict(list)
    seen: set[str] = set()
    failed = 0
    for response in responses:
        kind = response.get("kind") or response["id"].split("-")[0]
        items = llm_prompts.extract_json_array(response.get("text") or "")
        if not items:
            failed += 1
        for index, item in enumerate(items):
            if not isinstance(item, dict):
                continue
            key = shapes.normalized(json.dumps(item, sort_keys=True))
            if key in seen:
                continue
            seen.add(key)
            item["id"] = f"{response['id']}#{index}"
            item["domain"] = response.get("domain", "")
            if response.get("shape"):
                item["shape"] = response["shape"]
            seeds[kind].append(item)
    seeds["_failedResponses"] = [{"count": failed}]
    return seeds


# -- stage 3: templates --------------------------------------------------------------------------


def make_pairs(seeds: dict[str, list[dict[str, Any]]]) -> list[templates.Pair]:
    gen = templates.Generator(GENERATOR_SEED)
    rng = random.Random(GENERATOR_SEED)
    pairs: list[templates.Pair] = []
    sentences = [s for s in seeds.get("sentences", []) if isinstance(s.get("s"), str) and 4 <= len(s["s"].split()) <= 40]
    by_batch: dict[str, list[dict[str, Any]]] = collections.defaultdict(list)
    for seed in sentences:
        by_batch[seed["id"].split("#")[0]].append(seed)
        ops = [gen.correction(seed) if rng.random() < 0.7 else None, gen.disfluent(seed)]
        roll = rng.random()
        if roll < 0.18:
            ops.append(gen.grammar_slip(seed))
        elif roll < 0.26:
            ops.append(gen.hedge_move(seed))
        elif roll < 0.34:
            ops.append(gen.restart_swap(seed))
        elif roll < 0.42:
            ops.append(gen.question_tail(seed))
        if rng.random() < 0.3:
            ops.append(gen.negative(seed["s"], "bank-sentence", seed["id"]))
        pairs.extend(p for p in ops if p is not None)
    for batch in by_batch.values():
        for _ in range(max(1, len(batch) // 6)):
            pair = gen.run_on(batch)
            if pair:
                pairs.append(pair)
    for seed in seeds.get("lists", []):
        for op in (gen.list_format, gen.list_retraction):
            pair = op(seed)
            if pair:
                pairs.append(pair)
    # v4: an inline series stays prose at every length (2–8 items); only signalled lists are lists.
    pairs.extend(gen.inline_series_bank())
    for item in seeds.get("grammar", []):
        pairs.extend(gen.llm_pair(item, "grammar"))
    for item in seeds.get("corrections", []):
        pairs.extend(gen.llm_pair(item, "corrections"))
    for item in seeds.get("negatives", []):
        if isinstance(item.get("s"), str) and 2 <= len(item["s"].split()) <= 40:
            pairs.append(gen.negative(item["s"], item.get("kind", "llm") or "llm", item["id"], source="llm"))
    for item in seeds.get("frames", []):
        pair = gen.frame(item)
        if pair:
            pairs.append(pair)
    for seed in seeds.get("long", []):
        if not isinstance(seed.get("s"), str) or not 22 <= len(seed["s"].split()) <= 50:
            continue
        ops = [gen.long_disfluent(seed)]
        roll = rng.random()
        ops.append(gen.long_runon(seed) if roll < 0.35 else gen.long_correction(seed) if roll < 0.75 else gen.long_grammar(seed))
        if rng.random() < 0.25:
            ops.append(gen.negative(seed["s"], "long-passage", seed["id"]))
        pairs.extend(p for p in ops if p is not None)
    for item in seeds.get("polishedneg", []):
        if isinstance(item.get("s"), str) and 2 <= len(item["s"].split()) <= 40:
            pairs.append(gen.negative(item["s"], "polished-" + (item.get("kind") or "llm"), item["id"], source="llm", levels=("polished",)))
    for item in seeds.get("grammar", []):
        fixed = item.get("fixed")
        if isinstance(fixed, str) and rng.random() < 0.5:
            # The corrected sentence is already grammatical: Polished must leave it alone.
            pairs.append(gen.negative(fixed, "polished-fixed", item.get("id", ""), source="llm", levels=("polished",)))
    for item in seeds.get("frameneg", []):
        if isinstance(item.get("s"), str) and 4 <= len(item["s"].split()) <= 35:
            pairs.append(gen.negative(item["s"], "frame-" + (item.get("shape") or "llm")[:24], item["id"], source="llm"))
    for kind, op in (("agreement", gen.agreement), ("tense", gen.tense)):
        for item in seeds.get(kind, []):
            pair = op(item)
            if pair is None:
                continue
            pairs.append(pair)
            if rng.random() < 0.4:
                # Clean never fixes grammar: the same slip is a leave-unchanged example there.
                pairs.append(templates.Pair(kind=f"clean-keeps-grammar:{kind}", raw=pair.raw, target=pair.raw,
                                            levels=("clean",), seed_id=pair.seed_id, negative=True))
    # v4b: varied correction cues on a quarter of the sentence seeds, with their own RNG so the
    # v1–v3 rows above keep the same random draws (and their cached Jev audits).
    varied_rng = random.Random(GENERATOR_SEED + 11)
    for seed in sentences:
        if varied_rng.random() < VARIED_SHARE:
            pair = gen.varied_correction(seed, varied_rng)
            if pair:
                pairs.append(pair)
    for index, item in enumerate(seeds.get("meanneg", [])):
        if index % round(1 / MEAN_NEGATIVE_KEEP) == 0 and isinstance(item.get("s"), str) and 3 <= len(item["s"].split()) <= 30:
            pairs.append(gen.negative(item["s"], "mean-content", item["id"], source="llm"))
    # v5: acknowledgements kept, casual "like" kept, indefinite articles, existential agreement,
    # double negatives — each with its own RNG so earlier rows keep their draws.
    v5_rng = random.Random(GENERATOR_SEED + 13)
    for seed in sentences:
        if v5_rng.random() < 0.08:
            pair = gen.ack_negative(seed, v5_rng)
            if pair:
                pairs.append(pair)
    # Indefinite articles are rare in the short sentence bank (90 of 1,765), so every correct
    # text we have is a candidate: sentences, long passages and the leave-unchanged banks.
    # (Not the casual or "I mean" banks: an article restored into "gonna be here while" or after a
    # kept "I mean," reads as over-editing — Jev failed those in the v5 audit.)
    article_texts = [x for kind in ("sentences", "long") for x in seeds.get(kind, [])
                     if isinstance(x.get("s"), str) and 5 <= len(x["s"].split()) <= 45]
    article_pairs = [p for p in (gen.article(x, v5_rng) for x in article_texts) if p is not None]
    v5_rng.shuffle(article_pairs)
    pairs.extend(article_pairs[:300])
    # v5.1: bare-noun series kept exactly as spoken (the founder's "banana, orange and grape" shape).
    # ~180 rows: enough to teach the shape without crowding out the other negatives.
    for seed in seeds.get("lists", []):
        if v5_rng.random() < 0.6:
            pair = gen.bare_series(seed, v5_rng)
            if pair:
                pairs.append(pair)
    for item in seeds.get("casualneg", []):
        if isinstance(item.get("s"), str) and 3 <= len(item["s"].split()) <= 30 and re.search(r"\blike\b", item["s"], re.I):
            pairs.append(gen.negative(item["s"], "casual-like", item["id"], source="llm"))
    # Double negatives are left out: Jev failed 11 of 11 audited "won't eat nothing" → "won't eat
    # anything" repairs as changed facts, and the dev convention is the other direction ("There
    # isn't no reason" → "There's no reason"). The seeds stay in llm-responses for a later try.
    for kind, op in (("existential", gen.existential),):
        for item in seeds.get(kind, []):
            pair = op(item, v5_rng)
            if pair is None:
                continue
            pairs.append(pair)
            if v5_rng.random() < 0.4:
                pairs.append(templates.Pair(kind=f"clean-keeps-grammar:{pair.kind}", raw=pair.raw, target=pair.raw,
                                            levels=("clean",), seed_id=pair.seed_id, negative=True))
    # v5.2 templates for the two miss shapes Haiku rarely got past the guards and Jev
    # (dangling negated modal + restart, with or without a mid-clause hedge).
    v52_rng = random.Random(GENERATOR_SEED + 17)
    modal_texts = [x for kind in ("modalseed", "sentences", "polishedneg", "agreement") for x in seeds.get(kind, []) if isinstance(x.get("s"), str)]
    for x in modal_texts:
        for op in (gen.modal_restart, gen.garbled_hedge_restart):
            if v52_rng.random() < (0.9 if x.get("id", "").startswith("modalseed") else 0.6):
                pair = op(x, v52_rng)
                if pair:
                    pairs.append(pair)
    for item in seeds.get("garbledmiss", []):
        pairs.extend(gen.llm_pair(dict(item, type="miss-" + item.get("shape", "garbled")), "grammar"))
    for item in seeds.get("garbled", []):
        pairs.extend(gen.llm_pair(dict(item, type="garbled"), "grammar"))
    for index, text in enumerate(templates.LEGIT_REPEATS):
        pairs.append(gen.negative(text, "legit-repeat", f"legit-{index}"))
    for index, text in enumerate(templates.INSTRUCTION_NEGATIVES):
        pairs.append(gen.negative(text, "instruction", f"instr-{index}"))
    # v5.3 last, so every earlier row keeps its random draws (and its cached Jev answer).
    pairs.extend(hedge_lead_pairs(gen, seeds, sentences))
    pairs.extend(robust_negative_pairs(gen, seeds))
    pairs.extend(v55_pairs(gen, seeds, sentences))
    return pairs


def v55_pairs(gen: templates.Generator, seeds: dict[str, list[dict[str, Any]]],
              sentences: list[dict[str, Any]]) -> list[templates.Pair]:
    """v5.5, after the v5.4 2B (§3.36): filler "actually"/"basically"/"literally" removed, a
    meaningful one kept; corrections inside a frame with a hedge; run-on chains split; more
    technical and code-ish leave-unchanged rows. Own RNG, after every earlier row."""
    rng = random.Random(GENERATOR_SEED + 29)
    out: list[templates.Pair] = []
    for seed in sentences:
        if rng.random() < 0.15:
            pair = gen.discourse_filler(seed, rng)
            if pair:
                out.append(pair)
    for seed in sentences:
        if seed.get("kind") == "name":
            for _ in range(2):
                pair = gen.correction_in_frame(seed, rng)
                if pair:
                    out.append(pair)
    for item in seeds.get("runonchain", []):
        out.extend(gen.llm_pair(dict(item, type="runon-chain"), "grammar"))
    for item in seeds.get("meaningneg", []):
        text = item.get("s")
        if isinstance(text, str) and 5 <= len(text.split()) <= 35:
            out.append(gen.negative(text, "meaning-discourse", item["id"], source="llm"))
    for item in seeds.get("techneg", []):
        text = item.get("s")
        if not isinstance(text, str) or not 3 <= len(text.split()) <= 60:
            continue
        register = item.get("shape") or "technical"
        out.append(gen.negative(text, f"register-{register}", item["id"], source="llm"))
        if register != "code-ish" and rng.random() < PUNCT_ONLY_SHARE:
            raw = templates.asr_style(text, rng, spell_numbers=False)
            if raw != text:
                out.append(templates.Pair(kind=f"punct-only:{register}", raw=raw, target=text, seed_id=item["id"], source="llm"))
    return out


def robust_negative_pairs(gen: templates.Generator, seeds: dict[str, list[dict[str, Any]]]) -> list[templates.Pair]:
    """v5.4: leave-unchanged rows across 15 registers and "tempting" rewrites, plus punctuation-only
    twins (the words stay; only punctuation and casing are added). Own RNG, after every earlier row."""
    rng = random.Random(GENERATOR_SEED + 23)
    out: list[templates.Pair] = []
    for item in seeds.get("registerneg", []):
        text = item.get("s")
        if not isinstance(text, str) or not 3 <= len(text.split()) <= 60:
            continue
        register = item.get("shape") or "llm"
        out.append(gen.negative(text, f"register-{register}", item["id"], source="llm"))
        if register in PUNCT_ONLY_REGISTERS and rng.random() < PUNCT_ONLY_SHARE:
            raw = templates.asr_style(text, rng, spell_numbers=False)
            if raw != text:
                out.append(templates.Pair(kind=f"punct-only:{register}", raw=raw, target=text, seed_id=item["id"], source="llm"))
    for item in seeds.get("temptingneg", []):
        text = item.get("s")
        if not isinstance(text, str) or not 4 <= len(text.split()) <= 45 or TEMPTING_AMBIGUOUS.search(text):
            continue
        levels = ("polished",) if rng.random() < 0.7 else ("clean", "polished")
        out.append(gen.negative(text, "tempting-" + (item.get("kind") or "llm")[:24], item["id"], source="llm", levels=levels))
    return out


HEDGE_LEAD_COUNTS = {"statement": 150, "question": 70, "correction": 80, "resumptive": 40}


def hedge_lead_pairs(gen: templates.Generator, seeds: dict[str, list[dict[str, Any]]],
                     sentences: list[dict[str, Any]]) -> list[templates.Pair]:
    """v5.3 contrast rows: a lead (statement, question, resolved correction, or a resumptive
    "the import it fails…" slip) followed by a hedged sentence; the target keeps the lead. The
    v5.2 2B dropped such leads ("…over two gigs i think we should…" → "I think we should…")."""
    rng = random.Random(GENERATOR_SEED + 19)
    bank = [x for kind in ("sentences", "polishedneg") for x in seeds.get(kind, [])
            if isinstance(x.get("s"), str) and 4 <= len(x["s"].split()) <= 14]
    follows_by_domain: dict[str, list[str]] = collections.defaultdict(list)
    for x in bank:
        if templates.hedge_follow_ok(x["s"]):
            follows_by_domain[x.get("domain") or ""].append(x["s"])
    every_follow = [f for group in follows_by_domain.values() for f in group]

    def pick_follow(item: dict[str, Any]) -> str:
        # Same domain when the seed has one, so the two sentences read as one dictation.
        group = follows_by_domain.get(item.get("domain") or "") or every_follow
        return rng.choice(group)

    statements = [x for x in bank if x["s"].endswith(".")]
    questions = [x for x in bank if x["s"].endswith("?")]
    out: list[templates.Pair] = []

    def add(shape: str, make: Any, pool: list[dict[str, Any]]) -> None:
        pool = pool[:]
        rng.shuffle(pool)
        made = 0
        for item in pool:
            if made >= HEDGE_LEAD_COUNTS[shape]:
                break
            pair = make(item)
            if pair is not None:
                out.append(pair)
                made += 1

    def unrelated(lead: str, follow: str) -> bool:
        # The follow must not restate the lead (a correction lead followed by its own uncorrected
        # sentence reads as a contradiction; Jev failed it 0.93).
        a, b = set(shapes.words(lead)), set(shapes.words(follow))
        return len(a & b - GROUNDING_FREE) < 3

    def plain(item: dict[str, Any]) -> templates.Pair | None:
        follow = pick_follow(item)
        return None if not unrelated(item["s"], follow) else gen.hedge_lead(item["s"], item["s"], follow, rng, "statement" if item["s"].endswith(".") else "question", seed_id=item.get("id", ""))

    def corrected(item: dict[str, Any]) -> templates.Pair | None:
        lead = gen.correction(item)
        if lead is None or "\n" in lead.target or lead.kind.endswith("scratch-that"):
            return None
        follow = pick_follow(item)
        if not unrelated(lead.raw + " " + lead.target, follow):
            return None
        return gen.hedge_lead(lead.raw, lead.target, follow, rng, "correction", lead.levels, item.get("id", ""))

    def resumptive(item: dict[str, Any]) -> templates.Pair | None:
        raw, follow = gen.resumptive(item), pick_follow(item)
        if raw is None or not unrelated(item["s"], follow):
            return None
        return gen.hedge_lead(raw, item["s"], follow, rng, "resumptive", ("polished",), item.get("id", ""))

    add("statement", plain, statements)
    add("question", plain, questions)
    add("correction", corrected, [x for x in sentences if x.get("span")])
    add("resumptive", resumptive, statements)
    return out


def expand_levels(pairs: list[templates.Pair]) -> list[dict[str, Any]]:
    rng = random.Random(GENERATOR_SEED + 1)
    rows = []
    for index, pair in enumerate(pairs):
        levels = list(pair.levels)
        chosen = levels if len(levels) == 1 else [rng.choice(levels)]
        if len(levels) > 1 and rng.random() < 0.2:
            chosen = levels
        for level in chosen:
            rows.append({
                "id": f"p{index:05d}-{level[0]}", "level": level, "kind": pair.kind, "source": pair.source,
                "seedId": pair.seed_id, "raw": pair.raw, "seedTarget": pair.target, "canon": pair.canon,
                "negative": pair.negative, "needsJev": pair.needs_jev,
            })
    return rows


# -- stages 4–7 ----------------------------------------------------------------------------------


def canonicalise(rows: list[dict[str, Any]], args: argparse.Namespace, manifest: Manifest) -> None:
    canon_rows = [{"id": r["id"], "level": r["level"], "raw": r["seedTarget"], "target": r["seedTarget"]} for r in rows if r["canon"] and not r["negative"]]
    path_in, path_out = args.out / "work/canon-in.jsonl", args.out / "work/canon-out.jsonl"
    manifest.write_jsonl(path_in, canon_rows)
    run_eval(args.eval_bin, "prepare", "--in", str(path_in), "--out", str(path_out),
             "--prompt-version", args.prompt_version)
    drafts = {row["id"]: row["draft"] for row in manifest.read_jsonl(path_out)}
    for row in rows:
        row["target"] = drafts.get(row["id"], row["seedTarget"]) if row["canon"] and not row["negative"] else row["seedTarget"]


def guard(rows: list[dict[str, Any]], args: argparse.Namespace, manifest: Manifest, name: str) -> list[dict[str, Any]]:
    path_in, path_out = args.out / f"work/{name}-in.jsonl", args.out / f"work/{name}-out.jsonl"
    manifest.write_jsonl(path_in, rows)
    run_eval(args.eval_bin, "prepare", "--in", str(path_in), "--out", str(path_out),
             "--prompt-version", args.prompt_version)
    return manifest.read_jsonl(path_out)


def export_training_data(args: argparse.Namespace, manifest: Manifest) -> None:
    run_eval(args.eval_bin, "export", "--in", str(args.out / "pairs.jsonl"), "--out-dir",
             str(args.out / "mlx"), "--prompt-version", args.prompt_version)
    for name in ("train.jsonl", "valid.jsonl", "export.json"):
        manifest.record_write(args.out / "mlx" / name)


def content_key(row: dict[str, Any]) -> str:
    return hashlib.sha256(f"{row['level']}|{row['raw']}|{row['target']}".encode()).hexdigest()


def jev_filter(rows: list[dict[str, Any]], args: argparse.Namespace, manifest: Manifest) -> dict[str, Any]:
    """Chooses what Jev sees: every LLM label judged before (answers are cached, free), then new
    LLM labels, plus an audit of the template kinds new in this version. Selection is by content
    hash, so reruns pick the same rows and hit the cache."""
    # Earlier builds' Jev answers, by content (level, raw, target — Jev never sees the draft, so a
    # rules change doesn't invalidate them). Reused directly: the on-disk Jev cache lives in a
    # worktree's .build and doesn't survive the worktree.
    prior_answers: dict[str, dict[str, Any]] = {}
    for path in args.prior_jev or []:
        for r in manifest.read_jsonl(path):
            if r.get("jevNow") and r.get("pBad") is not None:
                prior_answers[content_key(r)] = {k: r[k] for k in ("pBad", "jevBand", "jevMeaning", "jevFaults") if k in r}
    prior = set(prior_answers)
    llm_rows = sorted((r for r in rows if r["needsJev"]), key=content_key)
    # Anything judged before (LLM labels and audited template rows) is re-asked from the cache.
    seen = [r for r in rows if content_key(r) in prior]
    # New LLM labels of the kinds the last runs were weakest on go first (v4: garbled repairs).
    fresh = sorted((r for r in llm_rows if content_key(r) not in prior), key=lambda r: not r["kind"].startswith(PRIORITY_CHANGED))
    audit_pool = sorted((r for r in rows if not r["needsJev"] and not r["unchanged"] and r["kind"].startswith(AUDIT_KINDS)
                         and content_key(r) not in prior), key=content_key)
    audit = audit_pool[: args.jev_audit]
    # v5.4: a sample of the new leave-unchanged rows at Polished (would Jev fix anything?).
    neg_pool = sorted((r for r in rows if r["unchanged"] and r["level"] == "polished" and r["kind"].startswith(NEG_AUDIT_KINDS)
                       and content_key(r) not in prior), key=lambda r: stable_fraction("neg|" + content_key(r)))
    audit += neg_pool[: args.jev_neg_audit]
    chosen = seen + audit + fresh[: max(0, args.jev_calls - len(audit))]
    chosen_ids = {r["id"] for r in chosen}
    for row in rows:
        row["jevNow"] = row["id"] in chosen_ids
        row["jevAsk"] = row["jevNow"] and content_key(row) not in prior
    path_in, path_out = args.out / "work/jev-in.jsonl", args.out / "work/jev-out.jsonl"
    manifest.write_jsonl(path_in, rows)
    run_eval(args.eval_bin, "jev", "--in", str(path_in), "--out", str(path_out), "--only", "jevAsk",
             "--max-calls", str(args.jev_calls), "--ledger", str(args.ledger), "--cap", str(args.jev_cap),
             "--label", "synthetic-data-filter")
    judged = manifest.read_jsonl(path_out)
    for row in judged:
        if row["jevNow"] and not row["jevAsk"]:
            row.update(prior_answers[content_key(row)])
    rows[:] = judged
    stats: dict[str, Any] = {"llmCandidates": len(llm_rows), "llmJudged": 0, "llmKept": 0, "auditJudged": 0, "auditFailed": 0, "auditFailedKinds": collections.Counter()}
    for row in rows:
        if not row.get("jevNow"):
            continue
        p_bad = row.get("pBad")
        if row["needsJev"]:
            stats["llmJudged"] += p_bad is not None
            stats["llmKept"] += p_bad is not None and p_bad < 0.3
        elif p_bad is not None:
            stats["auditJudged"] += 1
            if p_bad >= 0.3:
                stats["auditFailed"] += 1
                stats["auditFailedKinds"][row["kind"].rsplit(":", 1)[0] if row["kind"].count(":") > 1 else row["kind"]] += 1
    stats["auditFailedKinds"] = dict(stats["auditFailedKinds"])
    return stats


# Words a target may add that the draft doesn't contain (closed class; mirrors the spirit of
# OutputGuard.freeFunctionWords plus the "keep/leave" of a kept-value correction).
GROUNDING_FREE = set("a an the is are was were am be been being has have and or but so if that this these those it its "
                     "i we he she they you to of in on at too also not keep leave then".split())
# A double-negative repair swaps the negative word for its polarity partner ("don't have no
# chargers" → "don't have any chargers"); the partner counts as grounded when the draft has it.
POLARITY = {"any": "no", "anything": "nothing", "anyone": "one", "anybody": "nobody", "anywhere": "nowhere", "ever": "never"}


def ungrounded_words(row: dict[str, Any]) -> list[str]:
    """Content words in the target that the draft (all the model sees) doesn't contain. The
    runtime guard tolerates up to two; training data tolerates none, or the model learns to
    invent: the rules sometimes resolve a correction and drop the frame ("Reach out to Raj,
    scratch that, just text him…" → draft "Just text him…"), and a target that still says "Raj"
    teaches the model to make names up."""
    draft = set(shapes.words(row["draft"]))
    out = []
    for word in shapes.words(row["target"]):
        if word in draft or word in GROUNDING_FREE or POLARITY.get(word) in draft:
            continue
        if any(word.rstrip("s") == d.rstrip("s") or word.removesuffix("ed") == d.removesuffix("ed") for d in draft):
            continue
        out.append(word)
    return out


NUMBER_WORDS = set("zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen "
                   "sixteen seventeen eighteen nineteen twenty thirty forty fifty sixty seventy eighty ninety hundred "
                   "thousand million billion and point percent dollars dollar cents a p m".split())


def rules_dropped_words(row: dict[str, Any]) -> list[str]:
    """Words of a leave-unchanged row's raw text that the rules draft lost (number words that
    became digits excepted). A negative's target is its draft, so if the rules mangled it
    ("Elena, sorry I'm late…" → "I'm late…") the row would teach the model to keep the damage."""
    # Digits are stripped so ITN's "10:00am" still grounds a spoken "ten AM".
    draft = set(shapes.words(row["draft"])) | {w.lstrip("0123456789") for w in shapes.words(row["draft"])}
    return [w for w in shapes.words(row["raw"]) if w not in draft and w not in NUMBER_WORDS]


ARTICLES = ("a", "an", "the")
SERIES_SPLIT = re.compile(r"\s*,\s*(?:and\s+|or\s+)?|\s+(?:and|or)\s+")


def adds_article_to_series(row: dict[str, Any]) -> list[str]:
    """Bare series items in the draft that the target gives an article ("banana" → "a banana").
    The regression check for the v5 article-template bug: such a row must never be trained on."""
    draft, target = row["draft"], row["target"]
    added = []
    for clause in re.split(r"[.?!;:]", draft):
        pieces = [p for p in SERIES_SPLIT.split(clause.strip()) if p]
        if len(pieces) < 2:
            continue
        # The first item is the last word of the lead-in ("I need to get banana"); the others start their piece.
        heads = [pieces[0].split()[-1]] + [p.split()[0] for p in pieces[1:]]
        for piece, head in zip(pieces, heads):
            words = piece.split()
            index = len(words) - 1 if piece is pieces[0] else 0
            if head.lower() in ARTICLES or (index > 0 and words[index - 1].lower() in ARTICLES):
                continue
            pattern = rf"\b(?:a|an|the) {re.escape(head)}\b"
            if re.search(pattern, target, re.I) and not re.search(pattern, draft, re.I):
                added.append(head.lower())
    return added


HEDGE = re.compile(r"\b(?:i think|i feel|i guess|i believe|i suppose)\b", re.I)
# Fillers and correction cues a correct target may drop from before a hedge.
HEDGE_SPAN_SKIP = set("um uh er erm hmm like you know basically so okay ok well no wait sorry actually "
                      "scratch that mean meant just make".split())
HEDGE_SPAN = 3
HEDGE_WINDOW = 12


def lost_span_before_hedge(source: str, target: str, span: int = HEDGE_SPAN) -> str | None:
    """Words the speaker said just before a hedge ("I think", "I feel"…) in `source` that `target`
    lost, or None. A hit is either a run of `span`+ consecutive missing words, or `span`+ missing
    content words among the last HEDGE_WINDOW words before the hedge (a lost clause whose small
    words happen to recur elsewhere). Fillers, correction cues and number words (ITN turns them
    into digits) are skipped. The v5.2 2B learned "drop what comes before a hedge" ("the import
    fails on big files i think we should stream it" → "I think we should stream it"); no training
    target may teach that, and the eval scan uses the same test on model outputs."""
    present = set(shapes.words(target))
    stems = {w.rstrip("s") for w in present}

    def missing(word: str) -> bool:
        return word not in present and word.rstrip("s") not in stems

    for match in HEDGE.finditer(source):
        words = [w for w in shapes.words(source[: match.start()]) if w not in HEDGE_SPAN_SKIP and w not in NUMBER_WORDS and not w[:1].isdigit()]
        run: list[str] = []
        for word in words:
            run = run + [word] if missing(word) else []
            if len(run) >= span:
                return " ".join(run)
        lost = [w for w in words[-HEDGE_WINDOW:] if w not in GROUNDING_FREE and missing(w)]
        if len(lost) >= span:
            return " ".join(lost)
    return None


# v5.5: a discourse word in filler position (sentence-initial, after So/And/But/Well, or said
# twice) is removed at both levels; a leave-unchanged row that keeps one teaches the opposite.
FILLER_DISCOURSE = re.compile(r"(?:^|[.!?]\s+)(?:(?:so|and|but|well|okay|ok),?\s+)?(?:actually|honestly|basically|literally|sort of|kind of)\b", re.I)
DISCOURSE_WORDS = ("actually", "honestly", "basically", "literally", "sort of", "kind of")


def filler_discourse_kept(row: dict[str, Any]) -> bool:
    """A leave-unchanged row whose text keeps a discourse word in filler position."""
    # Frame negatives ("Actually, the new layout is faster") are the frame set's contract: exempt.
    if not row["negative"] or row.get("kind", "").startswith("negative:frame-"):
        return False
    text = row["draft"]
    if FILLER_DISCOURSE.search(text):
        return True
    lower = text.lower()
    return any(len(re.findall(rf"\b{word}\b", lower)) >= 2 for word in DISCOURSE_WORDS)


CORRECTION_CUE = r"(?:no wait|wait no|no|wait|sorry|i mean|i meant|actually)"
VALUE_WORDS = set("monday tuesday wednesday thursday friday saturday sunday january february march april may june "
                  "july august september october november december".split())


def corrected_value_survives(row: dict[str, Any]) -> str | None:
    """The corrected-away value of an "X, no, Y" correction that is still in the target, or None.
    Values are names (capitalised in the target), numbers, weekdays or months. v5.4 turned "Assign
    it to Mia, no, Jordan" into "Assign Jordan to Mia, no, Jordan"."""
    if row["negative"]:
        return None
    raw, target = row["raw"], row["target"]
    target_words = shapes.words(target)
    capitalised = {w.lower() for w in re.findall(r"\b[A-Z][a-z]+\b", target)}

    def kind(word: str) -> str | None:
        if word.isdigit():
            return "number"
        if word in VALUE_WORDS:
            return "date"
        return "name" if word in capitalised else None

    pattern = re.compile(rf"\b([a-z]+|\d+),?\s+{CORRECTION_CUE},?\s+([a-z]+|\d+)\b", re.I)
    raw_words = shapes.words(raw)
    for match in pattern.finditer(raw):
        old, new = match.group(1).lower(), match.group(2).lower()
        # Same kind of value on both sides ("Mia, no, Jordan"; "40, no, 45"): "Thursday at 3, sorry,
        # Friday" corrects the day, and the 3 rightly stays.
        if old == new or kind(new) is None or kind(old) != kind(new) or new not in target_words:
            continue
        if old in target_words and raw_words.count(old) == 1:
            return old
        if re.search(rf"\b{re.escape(old)},?\s+{CORRECTION_CUE},?\s+{re.escape(new)}\b", target, re.I):
            return old
    return None


def keep(row: dict[str, Any]) -> bool:
    if row.get("rejection"):
        return False
    if ungrounded_words(row):
        return False
    if lost_span_before_hedge(row["draft"], row["target"]):
        return False
    if row["negative"] and rules_dropped_words(row):
        return False
    if adds_article_to_series(row):
        return False
    if filler_discourse_kept(row) or corrected_value_survives(row):
        return False
    if row["needsJev"]:
        return row.get("pBad") is not None and row["pBad"] < 0.3
    if row.get("jevNow") and row.get("pBad") is not None and row["pBad"] >= 0.3:
        return False
    return True


def balance(rows: list[dict[str, Any]], total: int, negative_share: float) -> list[dict[str, Any]]:
    """`total` rows with `negative_share` leave-unchanged; the v3 shapes (frame switches, long
    groups) and Polished negatives are always taken first, the rest drawn at random."""
    rng = random.Random(GENERATOR_SEED + 3)
    unchanged = [r for r in rows if r["unchanged"]]
    changed = [r for r in rows if not r["unchanged"]]
    rng.shuffle(unchanged)
    rng.shuffle(changed)
    changed.sort(key=lambda r: not r["kind"].startswith(PRIORITY_CHANGED))
    # Polished negatives first, then negatives the Clean gate would actually send to the model.
    unchanged.sort(key=lambda r: (not r["kind"].startswith(PRIORITY_UNCHANGED),
                                  not (r["level"] == "polished" and r["kind"].startswith("negative:")),
                                  not r.get("modelAsked"), r["kind"].startswith("negative:bank")))
    want_changed = min(len(changed), int(total * (1 - negative_share)))
    want_unchanged = min(len(unchanged), max(int(want_changed * negative_share / (1 - negative_share)) + 1, total - want_changed))
    # v5.4: leave-unchanged rows per level in the same proportion as the changed rows. The priority
    # sort above put every Polished negative first, so with more of them the Clean negatives fell
    # from 628 (v5.3) to 193 — and the held-out Clean negatives were 28/30, not 30/30.
    chosen_changed = changed[:want_changed]
    clean_share = sum(r["level"] == "clean" for r in chosen_changed) / max(1, len(chosen_changed))
    by_level = {level: [r for r in unchanged if r["level"] == level] for level in ("clean", "polished")}
    want_clean = min(len(by_level["clean"]), round(want_unchanged * clean_share))
    want_polished = min(len(by_level["polished"]), want_unchanged - want_clean)
    want_clean = min(len(by_level["clean"]), want_unchanged - want_polished)
    chosen = chosen_changed + by_level["clean"][:want_clean] + by_level["polished"][:want_polished]
    rng.shuffle(chosen)
    return chosen


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--eval-bin", type=Path, default=ROOT / ".build/release/murmur-eval")
    parser.add_argument("--prompt-version", choices=("compact-v2", "compact-v3"), default="compact-v2",
                        help="compact cleanup prompt contract used for canonicalization, guards, and export")
    parser.add_argument("--llm", default="claude")
    parser.add_argument("--llm-model", default="haiku")
    parser.add_argument("--llm-calls", type=int, default=120)
    parser.add_argument("--refresh-llm", action="store_true")
    parser.add_argument("--prior-llm", type=Path, nargs="*", default=None,
                        help="earlier builds' llm-responses.jsonl (answers reused by prompt id)")
    parser.add_argument("--jev-calls", type=int, default=200, help="uncached Jev calls for this build")
    parser.add_argument("--jev-cap", type=int, default=200, help="cap on the ledger's running total")
    parser.add_argument("--jev-audit", type=int, default=90, help="template rows of the new kinds to audit")
    parser.add_argument("--jev-neg-audit", type=int, default=0, help="v5.4: new leave-unchanged rows to audit at Polished")
    parser.add_argument("--prior-jev", type=Path, nargs="*", default=None,
                        help="earlier builds' work/jev-out.jsonl files (their Jev answers are reused)")
    parser.add_argument("--ledger", type=Path, default=None)
    parser.add_argument("--total", type=int, default=6500)
    parser.add_argument("--negative-share", type=float, default=0.33)
    parser.add_argument("--valid-share", type=float, default=0.08)
    args = parser.parse_args(argv)
    args.out = check(args.out.resolve())
    args.ledger = check((args.ledger or args.out / "jev-ledger.json").resolve())
    args.out.mkdir(parents=True, exist_ok=True)
    manifest = Manifest(ROOT)

    dev = shapes.load_dev_sets(ROOT / "Evals", manifest)
    manifest.sections["devShapes"] = shapes.shape_profile(dev)
    index_only = shapes.load_index_only_sets(ROOT / "Evals", manifest)
    manifest.sections["indexOnlyDevSets"] = {name: len(cases) for name, cases in index_only.items()}
    index = shapes.ContaminationIndex(dev | index_only)

    responses = generate_content(args, manifest)
    seeds = parse_seeds(responses)
    manifest.sections["seeds"] = {k: len(v) for k, v in seeds.items() if not k.startswith("_")} | {"failedResponses": seeds["_failedResponses"][0]["count"]}
    manifest.write_jsonl(args.out / "seeds.jsonl", [dict(item, seedKind=kind) for kind, items in seeds.items() if not kind.startswith("_") for item in items])

    rows = expand_levels(make_pairs({k: v for k, v in seeds.items() if not k.startswith("_")}))
    counts: dict[str, Any] = {"candidates": len(rows)}
    before = len(rows)
    rows = [r for r in rows if not index.hits(r["raw"]) and not index.hits(r["seedTarget"])]
    counts["droppedContamination"] = before - len(rows)
    # v5.5: also near-duplicates (trigram overlap with any one dev text), not just shared 8-grams.
    before = len(rows)
    rows = [r for r in rows if not index.near(r["raw"]) and not index.near(r["seedTarget"])]
    counts["droppedNearDuplicate"] = before - len(rows)
    rows = [r for r in rows if r["raw"].strip() and r["seedTarget"].strip()]

    canonicalise(rows, args, manifest)
    rows = guard(rows, args, manifest, "prepare")
    for row in rows:
        if row["negative"]:
            row["target"] = row["draft"]
            row["unchanged"] = True
            row["rejection"] = None
    rejected = collections.Counter((r["rejection"] or "").split(":")[0] for r in rows if r.get("rejection"))
    counts["guardRejected"] = dict(rejected.most_common())
    counts["guardRejectedTotal"] = sum(rejected.values())
    rows = [r for r in rows if not r.get("rejection")]

    counts["jev"] = jev_filter(rows, args, manifest)
    counts["droppedUngrounded"] = sum(1 for r in rows if not r.get("rejection") and ungrounded_words(r))
    counts["droppedArticleAddedToSeries"] = sum(1 for r in rows if not r.get("rejection") and adds_article_to_series(r))
    counts["droppedLostSpanBeforeHedge"] = sum(1 for r in rows if not r.get("rejection") and lost_span_before_hedge(r["draft"], r["target"]))
    counts["droppedFillerDiscourseNegatives"] = sum(1 for r in rows if not r.get("rejection") and filler_discourse_kept(r))
    counts["droppedCorrectedValueSurvives"] = sum(1 for r in rows if not r.get("rejection") and corrected_value_survives(r))
    counts["droppedRulesMangledNegatives"] = sum(1 for r in rows if not r.get("rejection") and r["negative"] and rules_dropped_words(r))
    kept = [r for r in rows if keep(r)]
    # One copy per (level, draft, target).
    unique: dict[tuple[str, str, str], dict[str, Any]] = {}
    for row in kept:
        unique.setdefault((row["level"], row["draft"], row["target"]), row)
    kept = list(unique.values())
    counts["afterFilters"] = len(kept)
    final = balance(kept, args.total, args.negative_share)
    # Regression check (v5 → v5.1): no target may add an article to a bare series item.
    offenders = [r["id"] for r in final if adds_article_to_series(r)]
    if offenders:
        raise SystemExit(f"regression: {len(offenders)} targets add an article to a bare series item: {offenders[:5]}")
    # Regression check (v5.4 → v5.5): no corrected-away value survives next to its correction.
    offenders = [r["id"] for r in final if corrected_value_survives(r)]
    if offenders:
        raise SystemExit(f"regression: {len(offenders)} targets keep a corrected-away value: {offenders[:5]}")
    # Regression check (v5.2 → v5.3): no target may drop a 3+ word span that precedes a hedge.
    offenders = [r["id"] for r in final if lost_span_before_hedge(r["draft"], r["target"])]
    if offenders:
        raise SystemExit(f"regression: {len(offenders)} targets drop the words before a hedge: {offenders[:5]}")
    for row in final:
        row["split"] = "valid" if stable_fraction(row["seedId"] or row["id"]) < args.valid_share else "train"

    manifest.write_jsonl(args.out / "pairs.jsonl", final)
    export_training_data(args, manifest)

    by = lambda key: dict(collections.Counter(key(r) for r in final).most_common())  # noqa: E731
    counts["final"] = {
        "total": len(final), "train": sum(r["split"] == "train" for r in final), "valid": sum(r["split"] == "valid" for r in final),
        "unchangedShare": round(sum(r["unchanged"] for r in final) / max(1, len(final)), 3),
        "byLevel": by(lambda r: r["level"]), "bySource": by(lambda r: r["source"]),
        "byKind": by(lambda r: r["kind"].split(":")[0]), "byKindDetail": by(lambda r: r["kind"]),
        "modelAskedShareClean": round(sum(r.get("modelAsked", False) for r in final if r["level"] == "clean") / max(1, sum(r["level"] == "clean" for r in final)), 3),
        "rawWordsMedian": sorted(len(r["raw"].split()) for r in final)[len(final) // 2] if final else 0,
    }
    manifest.sections["counts"] = counts
    manifest.sections["generator"] = {"seed": GENERATOR_SEED, "splitSeed": SPLIT_SEED,
                                       "templates": "scripts/finetune/templates.py",
                                       "promptVersion": args.prompt_version}
    ledger = json.loads(args.ledger.read_text()) if args.ledger.exists() else {}
    manifest.sections["jevLedgerTotal"] = ledger.get("uncachedCalls")
    manifest.save(args.out / "manifest.json")
    print(json.dumps(counts, indent=2))


if __name__ == "__main__":
    main()
