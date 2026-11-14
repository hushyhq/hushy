#!/usr/bin/env bash
# Run each ready variant through the same intent-app path as the cleanup gate.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${1:?usage: score_variants.sh <out-root>}"
BIN="${MURMUR_EVAL_BIN:-$ROOT/.build/release/murmur-eval}"
[ -x "$BIN" ] || { echo "Build murmur-eval first: $BIN" >&2; exit 2; }
PUB="${HUSHY_PUBLIC_300:-$ROOT/Evals/runs/retrain/public-inputs/handy-eval300.jsonl}"
[ -f "$PUB" ] || { echo "Public 300 missing: set HUSHY_PUBLIC_300" >&2; exit 2; }
mkdir -p "$OUT/scores"
HOME_TMP="$(mktemp -d "${TMPDIR:-/tmp}/hushy-quant-home.XXXXXX")"
trap 'rm -rf "$HOME_TMP"' EXIT
for name in q4 q5 q6 q8 mixed dwq; do
  dir="$OUT/$name"
  [ -f "$dir/variant.json" ] || continue
  for set in pub number_guard number prompt misheard; do
    case "$set" in
      pub) cases="$PUB" ;;
      number_guard) cases="$ROOT/Evals/number-guard-probe.jsonl" ;;
      number) cases="$ROOT/Evals/number-probe.jsonl" ;;
      prompt) cases="$ROOT/Evals/prompt-probe.jsonl" ;;
      misheard) cases="$ROOT/Evals/misheard-probe.jsonl" ;;
    esac
    env HUSHY_HOME="$HOME_TMP" MURMUR_HOME="$HOME_TMP" \
      "$ROOT/scripts/mac-heavy.sh" "quant-score-$name-$set" /usr/bin/time -l "$BIN" intent-app \
      --local-model hushy-cleanup-2b-r5d2blr2-4bit --mlx-model "$dir" \
      --cases "$cases" --out "$OUT/scores/$name-$set.jsonl" --level polished --strategy model \
      >"$OUT/scores/$name-$set.log" 2>&1
  done
done
python3 "$ROOT/scripts/quant/score_table.py" "$OUT" "$PUB" >"$OUT/scores/table.md"
cat "$OUT/scores/table.md"
