#!/bin/bash
# Mac side of the CUDA path: merged Hugging Face checkpoint (from cuda/merge.py) → MLX model the
# Swift runtime loads (affine, group size 64; text-only — mlx_lm drops Qwen3.5's vision tower).
#
#   scripts/finetune/convert_mlx.sh <merged-hf-dir> <out-mlx-dir> [bits]   (bits: 4 default, or 6)
#
# Recipe (docs/product/INFERENCE-OPTIMIZATION.md §5): 4-bit for the 0.8B and for the 2B on base
# chips; also convert the 2B at 6 bits and compare both in Swift — on the zero-shot 2B, 6-bit was
# +3/+5/+6 points on cleanup-hybrid/Clean/Polished for +45% size. No q3, mixed_3_6, q4g32,
# mixed_4_6, DWQ, GPTQ or KV-cache quantization (measured: worse or no gain).
#
# Then evaluate it through Swift with the compact prompt:
#   scripts/finetune/finetune.sh eval <out-mlx-dir> <label>
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="${1:?usage: convert_mlx.sh <merged-hf-dir> <out-mlx-dir>}"
DST="${2:?usage: convert_mlx.sh <merged-hf-dir> <out-mlx-dir>}"
BITS="${3:-4}"
case "$BITS" in 4|5|6|8) ;; *) echo "bits must be 4, 5, 6 or 8" >&2; exit 2 ;; esac
PY="$("$HERE/venv.sh")"
# transformers 5 saves Qwen3's rope settings as `rope_parameters: {rope_theta, …}`; mlx_lm's
# qwen3 loader wants a top-level `rope_theta` (without it: "missing … 'rope_theta'").
"$PY" - "$SRC/config.json" <<'PYCONFIG'
import json, sys
path = sys.argv[1]
config = json.load(open(path))
for section in (config, config.get("text_config") or {}):
    rope = section.get("rope_parameters") or {}
    if "rope_theta" not in section and "rope_theta" in rope:
        section["rope_theta"] = rope["rope_theta"]
json.dump(config, open(path, "w"), indent=2)
PYCONFIG
"$PY" -m mlx_lm convert --hf-path "$SRC" --mlx-path "$DST" -q --q-bits "$BITS" --q-group-size 64
# The Swift loader wants the chat template next to the weights.
for f in chat_template.jinja tokenizer_config.json; do
    [ -f "$SRC/$f" ] && [ ! -f "$DST/$f" ] && cp "$SRC/$f" "$DST/$f"
done
( cd "$DST" && shasum -a 256 *.safetensors > SHA256SUMS )
du -sh "$DST"
