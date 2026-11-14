#!/bin/bash
# Label the meeting-extract chunks with Codex in the agreed order; safe to rerun (each stage skips done ids).
# Stops at the first quota or rate limit (label_codex.py exits 3) and prints where it stopped.
#   scripts/meeting-extract/run_labels.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
D=${HUSHY_MEETING_DATA:-$REPO/.build/public-data/meeting-extract}
PY=${PY:-$REPO/.build/finetune-venv/bin/python}
V=v2
GOLD="$D/final/gold-human.jsonl $D/final/held-r10d-overlap.jsonl"
run() { # name, then label_codex.py arguments
  local name="$1"; shift
  echo "== $name"
  "$PY" "$HERE/label_codex.py" --out "$D/labels/$name-$V.jsonl" --workers 5 "$@"
  [ $? -eq 3 ] && { echo "stopped on quota during $name"; exit 3; }
}
[ -f "$D/labels/cal-test.ids" ] || "$PY" "$HERE/calibrate.py" split
run cal-test --input $GOLD --ids "$D/labels/cal-test.ids" --tier calibration
"$PY" "$HERE/calibrate.py" score "$D/labels/cal-test-$V.jsonl" 20
run elitr --input "$D/final/input-only.jsonl" --sources elitr --tier input-only
run meetingbank --input "$D/final/input-only.jsonl" --sources meetingbank --tier input-only
run qmsum --input "$D/final/input-only.jsonl" --sources qmsum-committee --tier input-only
run notsofar --input "$D/final/input-only.jsonl" "$D/final/held-r10d-overlap.jsonl" --sources notsofar --tier input-only
echo "all stages done"
