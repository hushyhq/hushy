#!/usr/bin/env python3
"""Combine existing p1 MLX rows with independently labelled public speech rows.

`assemble` writes train.jsonl, valid.jsonl and manifest.json (with the held-out proof the training
script demands); `benchmark-index` writes the hash list that `assemble --exclude-index` reads.

Rows of one recording are held out together: each case names its group in the `--group-key` field
(default `meeting`; `series` keeps a run of meetings with the same speakers together; `id` holds
out single rows). Which groups are held is a stable hash of (seed, source, group), listed in the
manifest under `held_groups`, so it does not move when filters or labels change."""

import argparse
import json
from pathlib import Path
import random
import shutil
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parent / "finetune"))
from pathguard import Manifest, check  # noqa: E402
import retrain_holdout as holdout  # noqa: E402
import retrain_public_index as index  # noqa: E402
import retrain_public_screen as screening  # noqa: E402


DEFAULT_BASE = Path("Evals/runs/retrain/p1-trainset/mlx")
BASE_NAME = "p1"
WHOLE_PREFIX = "Transcript:"
VALID_NOTES = {
    "base": "valid.jsonl is the base's valid.jsonl copied byte for byte, so its loss compares across "
            "runs; held public groups are in valid-public.jsonl and are never trained on",
    "base_whole_only": "valid.jsonl is the base's valid rows with only the whole-transcript rows kept (rewritten, "
                       "not a byte copy), so its loss compares only with other whole-only runs on this base; "
                       "held public groups are in valid-public.jsonl and are never trained on",
    "mixed": "valid.jsonl mixes the base's valid rows with held public groups (never trained on); "
             "its loss does not compare with a base-only run",
}


def write_rows(path, rows):
    path = check(path)
    path.write_text("".join(json.dumps(row, ensure_ascii=False, separators=(",", ":")) + "\n"
                            for row in rows), encoding="utf-8")


def messages(system, spoken, label):
    return {"messages": [{"role": "system", "content": system},
                         {"role": "user", "content": f"{WHOLE_PREFIX} {spoken}\nOutput:"},
                         {"role": "assistant", "content": json.dumps({"text": label}, ensure_ascii=False,
                                                                        separators=(",", ":"))}]}


def base_proof(manifest, base):
    """The base folder's own held-out proof. Fails if it is missing: this tool never invents one."""
    for path in (base / "manifest.json", base.parent / "manifest.json"):
        if not path.exists():
            continue
        loaded = manifest.read_json(path)
        proof = loaded.get("heldoutProof") if isinstance(loaded, dict) else None
        if (isinstance(proof, dict) and proof.get("forbiddenPathsTouched") == 0
                and isinstance(proof.get("pathsChecked"), int)):
            return {"manifest": str(path), "pathsChecked": proof["pathsChecked"], "forbiddenPathsTouched": 0}
        raise ValueError(f"{path} has no clean held-out proof (heldoutProof with pathsChecked and "
                         "forbiddenPathsTouched 0); rebuild the base with its own tool")
    raise ValueError(f"no manifest.json in {base} or {base.parent}: the base has no held-out proof to carry over")


def _chat_row(path, number, row):
    """(system text, is a whole-transcript row, the row's messages) for one base row."""
    try:
        turns = row["messages"]
        system, user = turns[0]["content"], turns[1]["content"]
    except (KeyError, IndexError, TypeError):
        system = user = None
    if not isinstance(system, str) or not isinstance(user, str):
        raise ValueError(f"{path} row {number} is not a chat row (messages with a system turn and a user turn, "
                         "each with text content)")
    return system, user.startswith(WHOLE_PREFIX), {"messages": turns}


def load_base(manifest, base, whole_only=False):
    """The base's train and valid rows, the system message of its whole-transcript rows, and how many
    rows `whole_only` dropped from each part.

    A base may mix tasks (grouped cleanup, paragraph marking, whole-transcript rewrite). Added rows are
    whole-transcript rows, so they take the instruction of the base rows whose user turn starts "Transcript:".
    """
    parts, dropped, systems = {}, {}, set()
    for part in ("train", "valid"):
        path = base / f"{part}.jsonl"
        loaded = [_chat_row(path, number, row) for number, row in enumerate(manifest.read_jsonl(path), 1)]
        systems.update(system for system, whole, _ in loaded if whole)
        parts[part] = [row for _, whole, row in loaded if whole or not whole_only]
        dropped[part] = len(loaded) - len(parts[part])
    if not systems:
        raise ValueError(f"{base} has no whole-transcript rows (a user turn starting {WHOLE_PREFIX!r}), so added "
                         "rows have no instruction to take")
    if len(systems) != 1:
        raise ValueError("the base's whole-transcript rows must share one system message")
    return parts["train"], parts["valid"], systems.pop(), dropped


def add_source(manifest, addition, system, excluded, split):
    """Screens one added source and splits its kept rows by held group."""
    name, cases_path, labels_path = addition
    cases, labels = manifest.read_jsonl(cases_path), manifest.read_jsonl(labels_path)
    screened = screening.screen(name, cases, labels, excluded, split["group_key"])
    held = holdout.held_groups(screened["groups"], split["seed"], name, split["fraction"])
    train = [messages(system, spoken, label) for group, spoken, label in screened["kept"] if group not in held]
    valid = [messages(system, spoken, label) for group, spoken, label in screened["kept"] if group in held]
    counts = {"input": len(cases), "labels": len(labels), "train": len(train), "valid": len(valid),
              "rejected": dict(sorted(screened["rejected"].items())),
              "unmatched_labels": screened["unmatched_labels"], "groups": len(screened["groups"])}
    return {"name": name, "train": train, "valid": valid, "held": sorted(held), "counts": counts,
            "licence": sorted(screened["licences"]) or ["not checked"]}


def write_parts(manifest, base, out, parts, seed, valid_mode, whole_only):
    """Writes the row files and records each in the manifest. Returns the row count of valid.jsonl."""
    train, valid, public_valid = parts
    held = valid + public_valid if valid_mode == "mixed" else list(public_valid)
    random.Random(seed).shuffle(train)
    random.Random(seed + 1).shuffle(held)
    out.mkdir(parents=True, exist_ok=True)
    write_rows(out / "train.jsonl", train)
    if valid_mode == "mixed":
        write_rows(out / "valid.jsonl", held)
    else:
        if whole_only:  # a byte copy would keep the rows the manifest says were dropped
            write_rows(out / "valid.jsonl", valid)
        else:
            shutil.copyfile(check(base / "valid.jsonl"), check(out / "valid.jsonl"))
        write_rows(out / "valid-public.jsonl", held)
        manifest.record_write(out / "valid-public.jsonl")
    for name in ("train.jsonl", "valid.jsonl"):
        manifest.record_write(out / name)
    return len(held) if valid_mode == "mixed" else len(valid)


def save_manifest(manifest, out, proof):
    """manifest.json: the run's own guard record plus the base's proof carried over."""
    payload = manifest.to_dict()  # raises if any recorded path is forbidden
    run = payload["heldoutProof"]["pathsChecked"]
    payload["heldoutProof"].update(pathsChecked=run + proof["pathsChecked"], thisRun=run, base=proof)
    check(out / "manifest.json").write_text(json.dumps(payload, indent=2, ensure_ascii=False) + "\n",
                                            encoding="utf-8")
    return payload


def check_request(base, out, validation_fraction, valid_mode):
    check(base)
    check(out)
    if not 0 < validation_fraction < 1:
        raise ValueError("validation fraction must be between zero and one")
    if valid_mode not in ("base", "mixed"):
        raise ValueError("valid mode must be base or mixed")
    if out.exists() and not out.is_dir():
        raise ValueError(f"--out {out} is not a folder: assemble writes train.jsonl, valid.jsonl and manifest.json "
                         "into an empty or new folder")
    if out.exists() and any(out.iterdir()):
        raise ValueError("output directory must be empty")


def sections(base_rows, added, public_valid, valid_rows, indexes):
    """The manifest's counts: per source, per part, and each source's share."""
    train, valid, dropped = base_rows
    dropped_rows = sum(dropped.values())
    base_counts = {"input": len(train) + len(valid) + dropped_rows, "train": len(train), "valid": len(valid),
                   "rejected": {"not_whole_transcript": dropped_rows} if dropped_rows else {}}
    sources = [{"name": BASE_NAME, "licence": "own invented rows", "train": len(train), "valid": len(valid)}]
    sources += [{"name": item["name"], "licence": item["licence"], "train": len(item["train"]),
                 "valid": len(item["valid"])} for item in added]
    train_total = sum(source["train"] for source in sources)
    total = train_total + len(valid) + len(public_valid)
    return {"sources": sources, "train": train_total, "valid": valid_rows,
            "counts": {BASE_NAME: base_counts, **{item["name"]: item["counts"] for item in added}},
            "held_groups": {item["name"]: item["held"] for item in added},
            "exclude_indexes": [{"path": str(path), "hashes": len(loaded.whole), "shingles": len(loaded.shingles)}
                                for path, loaded in indexes],
            "train_share": {source["name"]: source["train"] / train_total if train_total else 0 for source in sources},
            "total_share": {source["name"]: (source["train"] + source["valid"]) / total if total else 0
                            for source in sources}}


def assemble(base, additions, out, seed=11, validation_fraction=.2, valid_mode="base", exclude_indexes=(),
             whole_only=False, group_key="meeting"):
    check_request(base, out, validation_fraction, valid_mode)
    if len({name for name, _, _ in additions} | {BASE_NAME}) != len(additions) + 1:
        raise ValueError(f"duplicate source: every --add needs its own name, and not {BASE_NAME}")
    manifest = Manifest(out)
    proof = base_proof(manifest, base)
    train, valid, system, dropped = load_base(manifest, base, whole_only)
    if whole_only and valid_mode == "base" and not valid:
        raise ValueError(f"--whole-only leaves no validation rows: {base / 'valid.jsonl'} has no whole-transcript rows")
    indexes = [(path, index.read(manifest, path)) for path in exclude_indexes]
    excluded = index.combine([loaded for _, loaded in indexes])
    split = {"seed": seed, "fraction": validation_fraction, "group_key": group_key}
    added = [add_source(manifest, addition, system, excluded, split) for addition in additions]
    public_valid = [row for item in added for row in item["valid"]]
    all_train = train + [row for item in added for row in item["train"]]
    valid_rows = write_parts(manifest, base, out, (all_train, valid, public_valid), seed, valid_mode, whole_only)
    note = VALID_NOTES["base_whole_only" if whole_only and valid_mode == "base" else valid_mode]
    manifest.sections.update({
        "seed": seed, "group_key": group_key, "whole_only": whole_only, "whole_only_dropped": dropped,
        "validation": {"mode": valid_mode, "base_rows": len(valid), "public_rows": len(public_valid), "note": note},
        **sections((train, valid, dropped), added, public_valid, valid_rows, indexes)})
    return save_manifest(manifest, out, proof)


def parse(argv):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("command", choices=["assemble", "benchmark-index"])
    parser.add_argument("--base", type=Path, default=DEFAULT_BASE)
    parser.add_argument("--out", type=Path, required=True, help="assemble: empty folder; benchmark-index: index.json")
    parser.add_argument("--add", action="append", default=[], help="name=cases.jsonl,labels.jsonl")
    parser.add_argument("--seed", type=int, default=11)
    parser.add_argument("--validation-fraction", type=float, default=.2)
    parser.add_argument("--valid", choices=["base", "mixed"], default="base",
                        help="base: valid.jsonl is the base's own; mixed: held public groups are added to it")
    parser.add_argument("--exclude-index", action="append", type=Path, default=[],
                        help="assemble: contamination index from benchmark-index; repeatable")
    parser.add_argument("--whole-only", action="store_true",
                        help="assemble: keep only the base's whole-transcript rows (drops grouped and paragraph rows)")
    parser.add_argument("--group-key", default="meeting",
                        help="assemble: the case field whose rows are held out together (meeting, series, id)")
    parser.add_argument("--source", action="append", type=Path, default=[],
                        help="benchmark-index: benchmark text file (Disfl-QA JSON or JSONL); repeatable")
    parser.add_argument("--shingles", action="store_true",
                        help="benchmark-index: also index every 8-word run, so assemble drops rows quoting one")
    args = parser.parse_args(argv)
    additions = []
    for spec in args.add:
        name, sep, paths = spec.partition("=")
        case, comma, label = paths.partition(",")
        if not sep or not comma or not name or not case or not label:
            parser.error("--add must be name=cases.jsonl,labels.jsonl")
        additions.append((name, Path(case), Path(label)))
    return args, additions


def main(argv=None):
    args, additions = parse(argv)
    try:
        if args.command == "benchmark-index":
            result = index.build(args.source, args.out, args.shingles)
        else:
            result = assemble(args.base, additions, args.out, args.seed, args.validation_fraction,
                              args.valid, args.exclude_index, args.whole_only, args.group_key)
    except (ValueError, OSError) as error:
        sys.exit(f"error: {error}")
    print(json.dumps(result, ensure_ascii=False, sort_keys=True))


if __name__ == "__main__":
    main()
