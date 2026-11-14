#!/usr/bin/env bash
# The project gate: one command that says whether the project is safe to merge.
# Runs every step, prints a pass/fail table, exits non-zero if any step failed.
#
# Usage:
#   scripts/gate.sh            run every step (same as --full)
#   scripts/gate.sh --full     run every step, including the cleanup gate
#   scripts/gate.sh --quick    run only steps marked quick
#   scripts/gate.sh --only NAME   run one step by name
#   scripts/gate.sh --list     list the steps
#
# Edit the STEPS section below. Keep this file committed. Never edit it to make a failing
# step pass; fix the code, or change the step and say why in .claude/DECISIONS.md.

set -u

NAMES=()
KINDS=()
CMDS=()

add_step() {
  NAMES+=("$1")
  KINDS+=("$2")
  CMDS+=("$3")
}

# ---------------------------------------------------------------- STEPS
# Each step: add_step "<name>" "<quick|full>" "<shell command>"
# quick = also runs with --quick. full = runs only in the full gate.
# The command runs through bash -c from the repo root. Exit 0 means pass.
#
# Examples (delete the ones you do not need, then add your own):
#   add_step build      quick "npm run build"
#   add_step unit       quick "npm test -- --silent"
#   add_step lint       quick "npm run lint"
#   add_step types      quick "npx tsc --noEmit"
#   add_step evals      full  "scripts/run-evals.sh"
#   add_step e2e        full  "npx playwright test"
#   add_step build      quick "cargo build --all-targets"
#   add_step unit       quick "cargo test"
#   add_step build      quick "swift build"
#   add_step unit       quick "swift test"
#   add_step unit       quick "python -m pytest -q"
#   add_step build      quick "go build ./..."
#   add_step unit       quick "go test ./..."
#
# A project eval step should exit non-zero when the score is below the bar written in
# .claude/RESULTS.md, so a regression turns the gate red.

add_step build   quick "scripts/mac-heavy.sh gate-build swift build -j 4"
add_step unit    quick "scripts/gate-swift-test.sh"
# Full gate only (about an hour): base versus working tree on the cleanup path. Exits 1 if public 300
# exact drops, a set's used-model count drops, or a long dictation goes from cleaned to raw.
add_step cleanup full  "scripts/gate-cleanup.sh --fail-on-regression --out .gate-logs/cleanup-report"
# Full gate only (about 8 minutes): on the 4B, the Default (Refined) may not trail Professional or Casual on names,
# numbers, negations or misheard words (founder, 2026-11-07; scripts/tone-parity.sh).
add_step tone-parity full "scripts/tone-parity.sh --out .gate-logs/tone-parity"
# ---------------------------------------------------------------- END STEPS

LOG_DIR="${GATE_LOG_DIR:-.gate-logs}"
MODE=full
ONLY=""

while [ $# -gt 0 ]; do
  case "$1" in
    --quick) MODE=quick ;;
    --full) MODE=full ;;
    --only) ONLY="${2:-}"; shift ;;
    --list)
      i=0
      while [ "$i" -lt "${#NAMES[@]}" ]; do
        printf '%-16s %-6s %s\n' "${NAMES[$i]}" "${KINDS[$i]}" "${CMDS[$i]}"
        i=$((i + 1))
      done
      exit 0
      ;;
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
    *) echo "gate: unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

if [ "${#NAMES[@]}" -eq 0 ]; then
  echo "gate: RED: no steps are configured. Edit the STEPS section of scripts/gate.sh." >&2
  exit 2
fi

cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)" || exit 2
mkdir -p "$LOG_DIR"

RESULT_NAMES=()
RESULT_STATES=()
RESULT_SECS=()
RESULT_LOGS=()
failed=0
ran=0

i=0
while [ "$i" -lt "${#NAMES[@]}" ]; do
  name="${NAMES[$i]}"
  kind="${KINDS[$i]}"
  cmd="${CMDS[$i]}"
  i=$((i + 1))
  if [ -n "$ONLY" ] && [ "$name" != "$ONLY" ]; then continue; fi
  if [ "$MODE" = quick ] && [ "$kind" != quick ]; then continue; fi
  log="$LOG_DIR/$name.log"
  echo "gate: running $name ..." >&2
  start=$SECONDS
  bash -c "$cmd" >"$log" 2>&1
  code=$?
  secs=$((SECONDS - start))
  ran=$((ran + 1))
  if [ "$code" -eq 0 ]; then state=PASS; else state="FAIL($code)"; failed=$((failed + 1)); fi
  RESULT_NAMES+=("$name")
  RESULT_STATES+=("$state")
  RESULT_SECS+=("$secs")
  RESULT_LOGS+=("$log")
done

if [ "$ran" -eq 0 ]; then
  echo "gate: RED: no step matched (mode=$MODE only=${ONLY:-none})." >&2
  exit 2
fi

echo
printf '%-16s %-10s %6s  %s\n' STEP RESULT SECS LOG
printf '%-16s %-10s %6s  %s\n' ---- ------ ---- ---
i=0
while [ "$i" -lt "${#RESULT_NAMES[@]}" ]; do
  printf '%-16s %-10s %6s  %s\n' "${RESULT_NAMES[$i]}" "${RESULT_STATES[$i]}" "${RESULT_SECS[$i]}" "${RESULT_LOGS[$i]}"
  i=$((i + 1))
done
echo
if [ "$failed" -eq 0 ]; then
  echo "gate: GREEN ($ran steps passed, mode=$MODE, commit $(git rev-parse --short HEAD 2>/dev/null || echo unknown))"
  exit 0
fi
echo "gate: RED ($failed of $ran steps failed). Last lines of each failing log:"
i=0
while [ "$i" -lt "${#RESULT_NAMES[@]}" ]; do
  case "${RESULT_STATES[$i]}" in
    FAIL*) echo "--- ${RESULT_NAMES[$i]}"; tail -n 15 "${RESULT_LOGS[$i]}" ;;
  esac
  i=$((i + 1))
done
exit 1
