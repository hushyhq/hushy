#!/usr/bin/env python3
"""Small, standard-library helpers for quant variant creation."""
import argparse
import hashlib
import json
from pathlib import Path
import shlex
import shutil


def patch_rope(source):
    path = Path(source) / "config.json"
    config = json.loads(path.read_text())
    changed = False
    for section in (config, config.get("text_config") or {}):
        rope = section.get("rope_parameters") or {}
        if "rope_theta" not in section and "rope_theta" in rope:
            section["rope_theta"] = rope["rope_theta"]
            changed = True
    if changed:
        path.write_text(json.dumps(config, indent=2) + "\n")


def check_training(path):
    path = Path(path).resolve()
    if not (path / "train.jsonl").is_file():
        raise ValueError(f"training rows missing: {path / 'train.jsonl'}")
    banned = ("heldout", "actions-heldout", "meeting-heldout", "voicelab-", "ab-", "eval-long64-b", "longb", "public-inputs")
    if any(term in part.lower() for part in path.parts for term in banned):
        raise ValueError("DWQ data path must contain training rows only")
    with (path / "train.jsonl").open() as source:
        first = json.loads(next(source))
    if "messages" not in first:
        raise ValueError("DWQ training rows need messages")


def finish(source, destination, name, bits, command):
    source, destination = Path(source), Path(destination)
    for filename in ("chat_template.jinja", "tokenizer_config.json"):
        if (source / filename).is_file() and not (destination / filename).exists():
            shutil.copy2(source / filename, destination / filename)
    weights = sorted(destination.glob("*.safetensors"))
    if not weights:
        raise ValueError(f"no weights in {destination}")
    with (destination / "SHA256SUMS").open("w") as sums:
        for path in weights:
            with path.open("rb") as handle:
                digest = hashlib.file_digest(handle, "sha256").hexdigest()
            sums.write(f"{digest}  {path.name}\n")
    size = sum(p.stat().st_size for p in destination.rglob("*") if p.is_file())
    record = {"variant": name, "bits_per_weight": bits, "model_files_bytes": size,
              "command": shlex.join(command)}
    (destination / "variant.json").write_text(json.dumps(record, indent=2) + "\n")


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="action", required=True)
    sub.add_parser("patch-rope").add_argument("source")
    sub.add_parser("check-training").add_argument("path")
    final = sub.add_parser("finish")
    final.add_argument("source")
    final.add_argument("destination")
    final.add_argument("name")
    final.add_argument("bits")
    final.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if args.action == "patch-rope":
        patch_rope(args.source)
    elif args.action == "check-training":
        check_training(args.path)
    else:
        bits = json.loads(args.bits)
        finish(args.source, args.destination, args.name, bits, args.command)


if __name__ == "__main__":
    main()
