#!/bin/bash
# One command on the CUDA box: LoRA/QLoRA fine-tune, then merge the adapter into the bf16 base.
#
#   ./train.sh configs/qwen3.5-2b.yaml
#
# Expects the dataset directory from the Mac (train.jsonl, valid.jsonl, export.json,
# manifest.json) at the config's data_dir. Output: <output_dir>/adapter, <output_dir>/merged,
# <output_dir>/train_summary.json. Copy <output_dir>/merged (and train_summary.json) back to the
# Mac and run scripts/finetune/convert_mlx.sh there. See scripts/finetune/README.md.
set -euo pipefail
cd "$(dirname "$0")"
# One GPU job at a time: queue behind the eval inference server or another run
# (~/hushy-train/gpu-lock.sh, from scripts/gpu/; .claude/GPU-TRAINING.md). A server left idle
# stops itself after 30 min; to free the GPU now: ~/hushy-train/serve/stop.sh.
if [ -z "${HUSHY_GPU_LOCK_HELD:-}" ] && [ -x ../gpu-lock.sh ]; then
    exec ../gpu-lock.sh "train:$(basename "${1:-?}" .yaml)" "$PWD/$(basename "$0")" "$@"
fi
export PATH="/usr/lib/wsl/lib:$PATH"                  # WSL2: nvidia-smi + libcuda live here
export LD_LIBRARY_PATH="/usr/lib/wsl/lib:${LD_LIBRARY_PATH:-}"
# Variable-length batches fragment the CUDA caching allocator until it reserves the whole 12 GB;
# under WSL2 the overflow spills into shared system memory and a step slows 3–5× (measured on the
# first 0.8B run: 1.2 → 6.4 s/step). Expandable segments keep the reservation near the real peak.
export PYTORCH_CUDA_ALLOC_CONF="${PYTORCH_CUDA_ALLOC_CONF:-expandable_segments:True}"
CONFIG="${1:?usage: train.sh <config.yaml>}"
# Use the box's venv (~/hushy-train/.venv) unless one is already active.
if [ -z "${VIRTUAL_ENV:-}" ] && [ -f ../.venv/bin/activate ]; then . ../.venv/bin/activate; fi
python - "$CONFIG" <<'PY'
import json, sys, yaml, pathlib
config = yaml.safe_load(open(sys.argv[1]))
data = pathlib.Path(config["data_dir"])
for name in ("train.jsonl", "valid.jsonl", "manifest.json"):
    if not (data / name).exists():
        sys.exit(f"missing {data / name} — copy the whole dataset directory from the Mac")
proof = json.load(open(data / "manifest.json")).get("heldoutProof", {})
if proof.get("forbiddenPathsTouched") != 0:
    sys.exit("manifest has no clean held-out proof; refusing to train")
print(f"dataset ok: {data} (held-out proof: {proof.get('pathsChecked')} paths checked, 0 forbidden)")
PY
nvidia-smi --query-gpu=name,memory.total --format=csv,noheader || true
python train_cuda.py --config "$CONFIG"
python merge.py --config "$CONFIG"
