#!/usr/bin/env bash
# One merged bf16 HF checkpoint -> text-only MLX affine variants. No downloads.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="${1:?usage: make_variants.sh <merged-hf-dir> <out-root>}"
OUT="${2:?usage: make_variants.sh <merged-hf-dir> <out-root>}"
PY="${FINETUNE_VENV:-$ROOT/.build/finetune-venv}/bin/python"
[ -x "$PY" ] || { echo "Existing finetune venv required: $PY" >&2; exit 2; }
[ -f "$SRC/config.json" ] || { echo "Missing merged HF config" >&2; exit 2; }
mkdir -p "$OUT"
# Mirrors convert_mlx.sh's Qwen rope compatibility patch. The source is a disposable merged model.
"$PY" "$ROOT/scripts/quant/prepare.py" patch-rope "$SRC"
for bits in 4 5 6 8; do
  name="q$bits"; dst="$OUT/$name"
  if [ -f "$dst/variant.json" ]; then
    echo "Reusing completed $dst" >&2
    continue
  fi
  [ ! -e "$dst" ] || { echo "Incomplete variant exists: $dst" >&2; exit 2; }
  cmd=("$PY" -m mlx_lm convert --hf-path "$SRC" --mlx-path "$dst" -q --q-bits "$bits" --q-group-size 64)
  "$ROOT/scripts/mac-heavy.sh" "quant-$name" "${cmd[@]}"
  "$PY" "$ROOT/scripts/quant/prepare.py" finish "$SRC" "$dst" "$name" "$bits" "${cmd[@]}"
done
dst="$OUT/mixed"
if [ -f "$dst/variant.json" ]; then
  echo "Reusing completed $dst" >&2
else
  [ ! -e "$dst" ] || { echo "Incomplete variant exists: $dst" >&2; exit 2; }
  cmd=("$PY" "$ROOT/scripts/quant/mixed_convert.py" "$SRC" "$dst")
  "$ROOT/scripts/mac-heavy.sh" quant-mixed "${cmd[@]}"
  "$PY" "$ROOT/scripts/quant/prepare.py" finish "$SRC" "$dst" mixed \
    '{"default":4,"v_proj":6,"down_proj":6,"embed_tokens":8,"lm_head":8}' "${cmd[@]}"
fi

# mlx_lm 0.31.3 DWQ imports `datasets`, which is absent from the pinned finetune venv.
# We refuse to install packages or reach the network. Other variants remain usable.
if ! "$PY" -c 'import datasets' >/dev/null 2>&1; then
  echo "DWQ unavailable: the existing venv lacks the datasets package; no package was installed." >&2
  exit 3
fi
TRAIN="${HUSHY_DWQ_TRAIN_DIR:-$ROOT/Evals/runs/retrain/round7/data-p1-r7}"
"$PY" "$ROOT/scripts/quant/prepare.py" check-training "$TRAIN"
dst="$OUT/dwq"
[ ! -e "$dst" ] || { echo "Already exists: $dst" >&2; exit 2; }
cmd=("$PY" -m mlx_lm dwq --model "$OUT/q8" --quantized-model "$OUT/q4" \
  --mlx-path "$dst" --bits 4 --group-size 64 --data-path "$TRAIN" \
  --num-samples 128 --batch-size 1 --max-seq-length 128 --grad-checkpoint)
HUSHY_HEAVY_MAX_SECONDS=0 "$ROOT/scripts/mac-heavy.sh" quant-dwq "${cmd[@]}"
"$PY" "$ROOT/scripts/quant/prepare.py" finish "$SRC" "$dst" dwq 4 "${cmd[@]}"
