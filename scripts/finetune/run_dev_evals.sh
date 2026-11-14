#!/bin/bash
# Runs the cleanup dev sets for one backend and keeps every per-case output as JSON, so the
# outputs can be judged pointwise with Jev afterwards (scripts/finetune/jev_rows.py).
#
#   scripts/finetune/run_dev_evals.sh <out-dir> <sets> <murmur-eval backend args...>
#     sets: comma list of hybrid,reformat-clean,reformat-polished,overdeletion,grammar,long,
#           frame-clean,frame-polished,list-clean,list-polished (list-consistency-dev.json, main ≥ 7dbbe23),
#           negfresh-clean,negfresh-polished (negatives-fresh-dev.json: separate author, v5.4)
#   e.g. run_dev_evals.sh runs/apple hybrid,reformat-clean apple
#        run_dev_evals.sh runs/ft mlx --mlx-model <dir> --mlx-prompt compact   (backend first)
#        run_dev_evals.sh runs/gpu hybrid remote --remote-url http://<box>:8008 --mlx-prompt compact
#   Wall time per set goes to <out-dir>/wall-seconds.tsv.
#   DEV_EVAL_JOBS=N runs up to N sets at once — remote backend only (the model runs on the GPU box,
#   which batches concurrent requests; on the Mac, MLX/Apple FM runs must stay one at a time).
#
# Dev sets only. Blind held-out v2, the actions held-out set and Voice Lab are never passed in
# (and murmur-eval's finetune path guard would refuse them). Results go to a scratch
# MURMUR_EVAL_HOME so Evals/results.md is only edited by hand; HUSHY_HOME/MURMUR_HOME point at a
# fresh temp dir, never ~/Library/Application Support/Hushy.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SPLIT_REPORT=0
if [ "${1:-}" = "--split-report" ]; then SPLIT_REPORT=1; shift; fi
OUT="$1"; SETS="$2"; shift 2
BACKEND=("$@")
EVAL="${MURMUR_EVAL_BIN:-$ROOT/.build/release/murmur-eval}"
mkdir -p "$OUT"
export MURMUR_EVAL_HOME="${MURMUR_EVAL_HOME:-$OUT/evalhome}"
mkdir -p "$MURMUR_EVAL_HOME"
MURMUR_HOME="$(mktemp -d)"; export MURMUR_HOME; export HUSHY_HOME="$MURMUR_HOME"

JOBS="${DEV_EVAL_JOBS:-1}"
if [ "$JOBS" -gt 1 ] && [ "${BACKEND[0]}" != "remote" ]; then
    echo "DEV_EVAL_JOBS > 1 is for --backend remote only (Mac backends run one set at a time)" >&2; exit 2
fi

run() {
    if [ "$JOBS" -gt 1 ]; then
        while [ "$(jobs -rp | wc -l)" -ge "$JOBS" ]; do sleep 1; done
        run_one "$@" &
    else
        run_one "$@"
    fi
}

run_one() {
    local name="$1"; shift
    echo "=== $name ${BACKEND[*]} (load $(sysctl -n vm.loadavg))"
    local start=$SECONDS
    "$EVAL" "$@" --backend "${BACKEND[@]}" --report "$OUT/$name.json" > "$OUT/$name.txt" 2>&1 || echo "  exit $? (see $OUT/$name.txt)"
    printf '%s\t%s\n' "$name" "$((SECONDS - start))" >> "$OUT/wall-seconds.tsv"
    if [ "$SPLIT_REPORT" -eq 1 ]; then
        local split_name="$name"
        case "$name" in
            cleanup-hybrid) split_name="dictation-golden" ;;
            reformat-*) split_name="reformat-golden" ;;
            long-hybrid) split_name="long-golden" ;;
            frame-*) split_name="frame-golden" ;;
            list-*) split_name="list-consistency-dev" ;;
            *) split_name="${name}-golden" ;;
        esac
        python3 "$ROOT/scripts/finetune/split_report.py" "$OUT/$name.json" "$ROOT/Evals/splits/$split_name.json" "$OUT"
        rm -f "$OUT/$name.json" "$OUT/$name.txt"
    else
        grep -m1 -E "Pass|pass:" "$OUT/$name.txt" || true
    fi
}

IFS=',' read -ra WANT <<< "$SETS"
for set in "${WANT[@]}"; do
    case "$set" in
        hybrid) run cleanup-hybrid cleanup --strategy hybrid --golden "$ROOT/Evals/dictation-golden.json" ;;
        reformat-clean) run reformat-clean reformat --level clean --prewarm --golden "$ROOT/Evals/reformat-golden.json" ;;
        reformat-polished) run reformat-polished reformat --level polished --prewarm --golden "$ROOT/Evals/reformat-golden.json" ;;
        overdeletion) run overdeletion cleanup --strategy hybrid --golden "$ROOT/Evals/overdeletion-golden.json" ;;
        grammar) run grammar grammar --golden "$ROOT/Evals/grammar-golden.json" ;;
        long) run long-hybrid cleanup --strategy hybrid --golden "$ROOT/Evals/long-golden.json" ;;
        frame-clean) run frame-clean reformat --level clean --prewarm --golden "$ROOT/Evals/frame-golden.json" ;;
        frame-polished) run frame-polished reformat --level polished --prewarm --golden "$ROOT/Evals/frame-golden.json" ;;
        list-clean) run list-clean reformat --level clean --prewarm --golden "$ROOT/Evals/list-consistency-dev.json" ;;
        list-polished) run list-polished reformat --level polished --prewarm --golden "$ROOT/Evals/list-consistency-dev.json" ;;
        spoken-urls-clean) run spoken-urls-clean reformat --level clean --prewarm --golden "$ROOT/Evals/spoken-urls-dev.json" ;;
        spoken-urls-polished) run spoken-urls-polished reformat --level polished --prewarm --golden "$ROOT/Evals/spoken-urls-dev.json" ;;
        negfresh-clean) run negfresh-clean reformat --level clean --prewarm --golden "$ROOT/Evals/negatives-fresh-dev.json" ;;
        negfresh-polished) run negfresh-polished reformat --level polished --prewarm --golden "$ROOT/Evals/negatives-fresh-dev.json" ;;
        *) echo "unknown set $set" >&2; exit 2 ;;
    esac
done
wait
rm -rf "$MURMUR_HOME"
