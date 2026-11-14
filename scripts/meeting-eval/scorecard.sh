#!/bin/bash
# The meeting-notes scorecard: runs public AMI meetings through the app's summary path
# (`murmur-eval meeting`, NoteSummarizer) on the local 4B and on Apple FM, then scores both with
# score_public.py. Every model run goes through scripts/mac-heavy.sh, with a scratch HOME.
#
#   scripts/meeting-eval/scorecard.sh <label> [dev|test|long] [4b|apple|both]
#
# Writes .build/meetings-hillclimb/runs/<label>-<set>-<backend>.json and prints the table.
# Needs: a release murmur-eval (swift build -c release --product murmur-eval), the 4B at
# $HUSHY_4B_DIR, and the sets from build_public_ami.py.
set -euo pipefail
LABEL="${1:?usage: scorecard.sh <label> [dev|test|long] [4b|apple|both]}"
SET="${2:-dev}"
WHICH="${3:-both}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$ROOT/.build/meetings-hillclimb"
GOLD="$OUT/sets/ami-$SET.json"
MODEL_DIR="${HUSHY_4B_DIR:-$ROOT/../../../.build/hosted-models/hushy-cleanup-4b-r10d-6bit}"
EVAL="${MURMUR_EVAL:-$ROOT/.build/release/murmur-eval}"
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/meeting-scorecard.XXXXXX")"
mkdir -p "$OUT/runs"
[ -f "$GOLD" ] || { echo "missing $GOLD (run build_public_ami.py)"; exit 1; }
[ -x "$EVAL" ] || { echo "missing $EVAL"; exit 1; }

run() {
  local backend="$1" out="$OUT/runs/$LABEL-$SET-$1.json"
  local -a flags
  if [ "$backend" = 4b ]; then
    flags=(--backend local --local-model hushy-cleanup-4b-r10d-6bit --mlx-model "$MODEL_DIR")
  else
    flags=(--backend apple)
  fi
  (cd "$ROOT" && HOME="$SCRATCH" HUSHY_HOME="$SCRATCH" MURMUR_HOME="$SCRATCH" MURMUR_EVAL_HOME="$SCRATCH" \
    "$ROOT/scripts/mac-heavy.sh" "meeting-scorecard-$LABEL-$backend" \
    "$EVAL" meeting --golden "$GOLD" "${flags[@]}" --out "$out" --label "$LABEL $backend" \
    > "$OUT/runs/$LABEL-$SET-$backend.log" 2>&1)
  RUNS+=(--run "$LABEL-$backend=$out")
}

RUNS=()
case "$WHICH" in
  4b) run 4b ;;
  apple) run apple ;;
  both) run 4b; run apple ;;
esac
python3 "$ROOT/scripts/meeting-eval/score_public.py" --gold "$GOLD" "${RUNS[@]}" --json "$OUT/runs/$LABEL-$SET-score.json"
grep -h 'peak\|memory' "$OUT/runs/$LABEL-$SET-"*.log 2>/dev/null | head -4 || true
rm -rf "$SCRATCH"
