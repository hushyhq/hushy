#!/bin/bash
# M7 fine-tune pipeline, one command per stage (docs/product/FINETUNE.md, scripts/finetune/README.md).
#
#   scripts/finetune/finetune.sh all                 data + Mac smoke LoRA + fuse + dev eval
#   scripts/finetune/finetune.sh data                synthetic dataset + manifest → $OUT/data
#   scripts/finetune/finetune.sh smoke               short LoRA on Qwen3.5-0.8B (pipeline check) + fuse
#   scripts/finetune/finetune.sh convert <merged> <mlx-out> [bits]   CUDA-merged HF model → MLX (4-bit default)
#   scripts/finetune/finetune.sh eval <mlx-dir> <label>       dev sets through Swift, compact prompt
#
# Env: FINETUNE_OUT (default .build/finetune), FINETUNE_BASE (default mlx-community/Qwen3.5-0.8B-4bit,
# or a local MLX dir), FINETUNE_LLM_CALLS (190), FINETUNE_JEV_CALLS / FINETUNE_JEV_CAP (320),
# FINETUNE_JEV_LEDGER (Jev call ledger; default $OUT/jev-ledger.json).
# Heavy training runs on a CUDA box (scripts/finetune/cuda); on a Mac that also serves live
# dictation, keep to `smoke`.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="$ROOT/scripts/finetune"
OUT="${FINETUNE_OUT:-$ROOT/.build/finetune}"
BASE="${FINETUNE_BASE:-mlx-community/Qwen3.5-0.8B-4bit}"
LEDGER="${FINETUNE_JEV_LEDGER:-$OUT/jev-ledger.json}"
EVAL="$ROOT/.build/release/murmur-eval"
mkdir -p "$OUT"

build() {
    (cd "$ROOT" && swift build -c release --product murmur-eval >/dev/null)
    [ -f "$ROOT/.build/release/mlx.metallib" ] || "$ROOT/scripts/build-mlx-metallib.sh" release
}

data() {
    build
    # From an empty cache, v3 needs ~179 generator calls and ~320 Jev calls (230 LLM labels +
    # 90 template audits); with warm .build caches a rerun costs nothing.
    python3 "$HERE/build_data.py" --out "$OUT/data" --eval-bin "$EVAL" --ledger "$LEDGER" \
        --llm-calls "${FINETUNE_LLM_CALLS:-190}" --jev-calls "${FINETUNE_JEV_CALLS:-320}" \
        --jev-cap "${FINETUNE_JEV_CAP:-320}" --jev-audit 90
    ( cd "$HERE" && python3 -m unittest discover -s tests -q )
}

smoke() {
    local py; py="$("$HERE/venv.sh")"
    local run="$OUT/runs/smoke-$(basename "$BASE")"
    mkdir -p "$run"
    "$py" "$HERE/train_mlx.py" --config "$HERE/configs/mlx-qwen3.5-0.8b-smoke.yaml" \
        --model "$BASE" --data "$OUT/data/mlx" --adapter-path "$run/adapter" 2>&1 | tee "$run/train.log"
    "$py" -m mlx_lm fuse --model "$BASE" --adapter-path "$run/adapter" --save-path "$run/fused"
    ( cd "$run/fused" && shasum -a 256 *.safetensors > SHA256SUMS )
    echo "fused model: $run/fused"
}

evaluate() {
    local model="${1:?eval <mlx-dir> <label>}" label="${2:?eval <mlx-dir> <label>}"
    build
    "$HERE/run_dev_evals.sh" "$OUT/eval/$label" hybrid,reformat-clean,reformat-polished,overdeletion,grammar,long,frame-clean,frame-polished \
        mlx --mlx-model "$model" --mlx-prompt compact
    "$EVAL" model-diag --mlx-probe --backend mlx --mlx-model "$model" --mlx-prompt compact --repeats 15 \
        > "$OUT/eval/$label/latency-probe.txt" 2>&1 || true
    echo "reports: $OUT/eval/$label"
}

case "${1:-all}" in
    data) data ;;
    smoke) smoke ;;
    convert) "$HERE/convert_mlx.sh" "${2:?}" "${3:?}" "${4:-4}" ;;
    eval) evaluate "${2:-}" "${3:-}" ;;
    all) data; smoke; evaluate "$OUT/runs/smoke-$(basename "$BASE")/fused" smoke ;;
    *) sed -n '2,16p' "$0"; exit 2 ;;
esac
