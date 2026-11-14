#!/usr/bin/env python3
"""Folds the trained LoRA adapter into the bf16 base and saves a plain Hugging Face checkpoint.

    python merge.py --config configs/qwen3.5-2b.yaml

Writes `<output_dir>/merged/`: safetensors weights with the base model's own structure and
config, the tokenizer and chat template, and every other non-weight file from the base snapshot
(processor/generation configs, license). Copy that directory back to the Mac and run
`scripts/finetune/convert_mlx.sh` to get the 4-bit MLX model the Swift runtime loads.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
from pathlib import Path

import torch
from huggingface_hub import snapshot_download
from peft import PeftModel
from transformers import AutoTokenizer

from train_cuda import load_config, model_class


def file_sha256(path: Path) -> str:
    """Hashes a shard in pieces, so a 5 GB file is never held in memory whole."""
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1 << 24), b""):
            digest.update(block)
    return digest.hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", required=True)
    parser.add_argument("--cpu-dry-run", action="store_true")
    args = parser.parse_args()
    config = load_config(args.config)
    out = Path(config["output_dir"]).expanduser()
    merged = out / "merged"
    base = str(Path(config["base_model"]).expanduser())

    # On the card when there is one: on the CPU the base, the merged copy and the shards being
    # written all sit in system memory at once, and the 16 GB training box stopped at this step.
    on_gpu = torch.cuda.is_available() and not args.cpu_dry_run
    placement = {"device_map": {"": "cuda"}} if on_gpu else {}
    model = model_class(base).from_pretrained(base, dtype=torch.bfloat16, low_cpu_mem_usage=True, **placement)
    model = PeftModel.from_pretrained(model, str(out / "adapter"))
    model = model.merge_and_unload()
    model.save_pretrained(str(merged), safe_serialization=True, max_shard_size="5GB")
    AutoTokenizer.from_pretrained(base).save_pretrained(str(merged))

    # Carry over the base snapshot's non-weight files (chat template, processor config, LICENSE)
    # without overwriting what save_pretrained wrote.
    snapshot = Path(base) if Path(base).is_dir() else Path(snapshot_download(base, allow_patterns=["*.json", "*.jinja", "*.txt", "LICENSE*", "*.md"]))
    for item in snapshot.iterdir():
        weights = item.name.endswith((".safetensors", ".bin", ".pt", ".index.json"))  # the index names the base's shards
        if item.is_file() and not weights and not (merged / item.name).exists():
            shutil.copy2(item, merged / item.name)

    digests = {path.name: file_sha256(path) for path in sorted(merged.glob("*.safetensors"))}
    (merged / "hushy-finetune.json").write_text(json.dumps({
        "base_model": base, "adapter": str(out / "adapter"), "config": config, "safetensors_sha256": digests,
    }, indent=2, default=str))
    print(f"merged model → {merged}")


if __name__ == "__main__":
    main()
