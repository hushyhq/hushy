#!/usr/bin/env python3
"""Build group-contract CUDA training data from invented retrain batches."""

import argparse
from collections import Counter, defaultdict
import hashlib
import json
from pathlib import Path
import random
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
RETRAIN = ROOT / "Evals/runs/retrain"
PROMPT = ROOT / "Evals/finetune-prompts/group-call-system.txt"
sys.path.insert(0, str(ROOT / "scripts"))
sys.path.insert(0, str(ROOT / "scripts/finetune"))
from pathguard import violation  # noqa: E402
import retrain_groups  # noqa: E402


def guarded(path, base, label):
    path = Path(path)
    if violation(path) or not path.resolve().is_relative_to(base.resolve()):
        raise ValueError(f"{label} must be a permitted path under {base.relative_to(ROOT)}")
    return path


def read_jsonl(path):
    with path.open(encoding="utf-8") as handle:
        return [json.loads(line) for line in handle if line.strip()]


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def compact(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


def validate_group(row, system):
    messages = row.get("messages")
    if row.get("arm") != "group" or not isinstance(messages, list) or len(messages) != 3:
        raise ValueError("expected one three-turn group row")
    if [m.get("role") for m in messages] != ["system", "user", "assistant"]:
        raise ValueError("group row has wrong message roles")
    if messages[0].get("content") != system:
        raise ValueError("group row system differs from group-call-system.txt")
    user = messages[1].get("content")
    if not isinstance(user, str) or not re.fullmatch(r"Left context: [^\n]*\nTranscript: [^\n]+\nOutput:", user):
        raise ValueError("group row user is not the group contract")
    answer = json.loads(messages[2]["content"])
    if set(answer) != {"text", "new_paragraph"} or type(answer["text"]) is not str or type(answer["new_paragraph"]) is not bool:
        raise ValueError("group answer has the wrong schema")
    return user, compact(answer)


def split_passages(rows, metadata, seed):
    families = defaultdict(list)
    for passage in {r["passage"] for r in rows}:
        families[metadata[passage]["family"]].append(passage)
    total = sum(map(len, families.values()))
    if total < 2:
        raise ValueError("need at least two passages for train and validation")
    target = max(1, round(total * 0.08))
    rng = random.Random(seed)
    for family in sorted(families):
        rng.shuffle(families[family])
    counts = {family: 0 for family in families}
    for _ in range(min(target, total - 1)):
        choices = [f for f in families if counts[f] < len(families[f]) and
                   (total - sum(counts.values()) > 1)]
        family = max(choices, key=lambda f: (len(families[f]) * 0.08 - counts[f], len(families[f]), f))
        counts[family] += 1
    valid = {p for family in families for p in families[family][:counts[family]]}
    train = {p for family in families for p in families[family][counts[family]:]}
    assert train.isdisjoint(valid)
    return train, valid


def counts(rows, metadata):
    passages = {r["passage"] for r in rows}
    def family(row):
        return row["source"] if row.get("source") else metadata[row["passage"]]["family"]
    def band(row):
        return row["source"] if row.get("source") else metadata[row["passage"]]["length_band"]
    by_passage = defaultdict(set)
    for row in rows:
        by_passage[row["passage"]].add(json.loads(row["messages"][2]["content"]).get("new_paragraph"))
    return {"passages": {"total": len(passages),
                         "family": dict(sorted(Counter(family(next(r for r in rows if r["passage"] == p)) for p in passages).items())),
                         "length_band": dict(sorted(Counter(band(next(r for r in rows if r["passage"] == p)) for p in passages).items())),
                         "new_paragraph": {str(v).lower(): sum(v in flags for flags in by_passage.values()) for v in (False, True)}},
            "rows": {"total": len(rows),
                     "family": dict(sorted(Counter(family(r) for r in rows).items())),
                     "length_band": dict(sorted(Counter(band(r) for r in rows).items())),
                     "new_paragraph": {str(v).lower(): sum(json.loads(r["messages"][2]["content"]).get("new_paragraph") is v for r in rows) for v in (False, True)}},
            "empty_left_context_share": (sum(r["messages"][1]["content"].split("\n", 1)[0].split(":", 1)[1].strip().lower() in ("", "none") for r in rows) / len(rows) if rows else 0)}


def build(batches, out, seed=11, replay=None, replay_share=0.3, replay_level="Polished", extra=()):
    out = guarded(out, RETRAIN, "output")
    if out == RETRAIN or out.exists() and any(out.iterdir()):
        raise ValueError("output must be a new, empty directory below Evals/runs/retrain")
    if not 0 <= replay_share < 1:
        raise ValueError("replay share must be in [0, 1)")
    prompt_text = PROMPT.read_text(encoding="utf-8")
    system = retrain_groups.prompt_sections(PROMPT)
    version = re.search(r"Version label: ([\w.-]+)\. For", prompt_text)
    if not version:
        raise ValueError("group prompt has no version label")
    metadata, rows, seen, inputs = {}, [], set(), []
    for folder in batches:
        folder = guarded(folder, RETRAIN, "batch")
        if folder == out:
            raise ValueError("output cannot be an input batch")
        sources_path = guarded(folder / "sources.jsonl", folder, "passage metadata")
        rows_path = guarded(folder / "batch.group_rows.jsonl", folder, "group rows")
        inputs.append(str(folder.resolve().relative_to(ROOT)))
        sources = read_jsonl(sources_path)
        local = {}
        for source in sources:
            ident = source["id"]
            if ident in metadata or ident in local:
                raise ValueError(f"duplicate passage id: {ident}")
            band = source["band"]
            local[ident] = {"family": source["family"], "length_band": "-".join(map(str, band))}
        metadata.update(local)
        for row in read_jsonl(rows_path):
            passage = row.get("passage")
            if passage not in local:
                raise ValueError(f"group row has no passage metadata: {passage}")
            user, answer = validate_group(row, system)
            key = (user, answer)
            if key in seen:
                continue
            seen.add(key)
            rows.append({**row, "messages": [{"role": "system", "content": system},
                                            {"role": "user", "content": user},
                                            {"role": "assistant", "content": answer}]})
    train_ids, valid_ids = split_passages(rows, metadata, seed)
    train = [r for r in rows if r["passage"] in train_ids]
    valid = [r for r in rows if r["passage"] in valid_ids]
    replay_count = 0
    if replay is not None:
        replay = guarded(replay, ROOT, "replay")
        candidates = []
        skipped = Counter()
        for old in read_jsonl(replay):
            messages = old.get("messages", [])
            if len(messages) != 3 or [m.get("role") for m in messages] != ["system", "user", "assistant"]:
                raise ValueError("replay row must have system, user, assistant turns")
            # Only the older Polished rows: their labels repair grammar as the group policy does.
            # The Clean level left grammar alone by design, which the group format must not learn.
            if replay_level and f"Level: {replay_level}." not in messages[0]["content"]:
                skipped["other_level"] += 1
                continue
            body = re.fullmatch(r"Transcript: (.+)\nOutput:", messages[1]["content"], re.S)
            answer = json.loads(messages[2]["content"])
            if not body or set(answer) != {"text"} or type(answer["text"]) is not str:
                raise ValueError("replay row is not a v5.4 compact chat row")
            # A group is one stretch of prose: rows with a line break on either side are left out.
            if re.search(r"[\n\r]", body[1]) or re.search(r"[\n\r]", answer["text"]):
                skipped["multiline"] += 1
                continue
            match = body
            user = f"Left context: {retrain_groups.left_context('')}\nTranscript: {match[1]}\nOutput:"
            converted = compact({"text": answer["text"], "new_paragraph": False})
            key = (user, converted)
            if key in seen:
                continue
            seen.add(key)
            candidates.append({"id": old["id"], "passage": f"replay:{old['id']}", "source": "legacy_replay",
                               "messages": [{"role": "system", "content": system},
                                            {"role": "user", "content": user},
                                            {"role": "assistant", "content": converted}]})
        rng = random.Random(seed)
        rng.shuffle(candidates)
        replay_count = min(len(candidates), round(len(rows) * replay_share / (1 - replay_share)))
        train.extend(candidates[:replay_count])
    # Rows of another task (their own system text) are passed through; a row follows its passage into validation.
    extra_counts = Counter()
    for path in extra:
        for other in read_jsonl(guarded(path, RETRAIN, "extra rows")):
            messages = other.get("messages", [])
            if [m.get("role") for m in messages] != ["system", "user", "assistant"] or not other.get("source"):
                raise ValueError("an extra row needs system, user, assistant turns and a source")
            json.loads(messages[2]["content"])
            (valid if other["passage"] in valid_ids else train).append(other)
            extra_counts[other["source"]] += 1
    assert {r["passage"] for r in train}.isdisjoint({r["passage"] for r in valid})
    rng = random.Random(seed)
    rng.shuffle(train)
    rng.shuffle(valid)
    out.joinpath("mlx").mkdir(parents=True)
    for name, part in (("train", train), ("valid", valid)):
        (out / "mlx" / f"{name}.jsonl").write_text("".join(compact(r) + "\n" for r in part), encoding="utf-8")
    export = {"promptVersion": version[1], "systemSHA256": hashlib.sha256(system.encode()).hexdigest(),
              "answerSchema": {"type": "object", "properties": {"text": {"type": "string"},
                      "new_paragraph": {"type": "boolean"}}, "required": ["text", "new_paragraph"],
                      "additionalProperties": False}}
    (out / "export.json").write_text(json.dumps(export, indent=2) + "\n", encoding="utf-8")
    all_rows = train + valid
    manifest = {"inputs": inputs, "seed": seed, "validation_fraction_target": 0.08,
                "train": counts(train, metadata), "valid": counts(valid, metadata),
                **counts(all_rows, metadata),
                "replay": {"included": replay_count, "requested_share": replay_share if replay else 0,
                           "label_policy": "older v5.4 short-dictation policy; not relabelled under group v4.1" if replay else None,
                           "level": replay_level if replay else None,
                           "skipped": dict(skipped) if replay else None,
                           "input": str(replay.resolve().relative_to(ROOT)) if replay else None},
                "extra": dict(extra_counts),
                "max_row_chars": max(len(compact(r["messages"])) for r in all_rows),
                "rough_max_tokens": max((len(compact(r["messages"])) + 3) // 4 for r in all_rows),
                "token_estimate_assumption": "4 characters per token on serialized messages; chat-template overhead excluded",
                "heldoutProof": {"pathsChecked": len(batches) * 2 + bool(replay) + 1,
                                 "forbiddenPathsTouched": 0},
                "files": {name: sha256(out / name) for name in ("mlx/train.jsonl", "mlx/valid.jsonl", "export.json")}}
    (out / "manifest.json").write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    return manifest


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--batch", action="append", required=True, help="batch folder; repeat for more batches")
    parser.add_argument("--out", required=True)
    parser.add_argument("--seed", type=int, default=11)
    parser.add_argument("--replay")
    parser.add_argument("--replay-share", type=float, default=0.3)
    parser.add_argument("--replay-level", default="Polished",
                        help="replay only rows whose old system prompt names this level; empty for all")
    parser.add_argument("--extra", action="append", default=[],
                        help="rows of another task (jsonl with messages, passage, source); repeat for more")
    args = parser.parse_args(argv)
    result = build(args.batch, args.out, args.seed, args.replay, args.replay_share, args.replay_level, args.extra)
    print(json.dumps({"train": result["train"]["rows"]["total"],
                      "valid": result["valid"]["rows"]["total"],
                      "rough_max_tokens": result["rough_max_tokens"]}))


if __name__ == "__main__":
    main()
