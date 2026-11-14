#!/bin/bash
# Score every diarizer FluidAudio ships on the public meeting sets, one process per run so peak
# memory is per backend, then print one table. Data and model downloads live in the main checkout's
# .build/public-data (gitignored), shared by every worktree.
#
#   scripts/diarizer-bakeoff.sh [datasets] [backends]
#   e.g. scripts/diarizer-bakeoff.sh "ami-sdm notsofar-sc" "legacy community1 nemotron-fast128"
#
# Runs under a throwaway HOME so nothing touches the real user's Library. Each run queues through
# scripts/mac-heavy.sh; wrap the whole script in one mac-heavy call to hold a single slot for all of
# them. A failed run is reported and the rest continue. Results: .build/public-data/diarizer-bakeoff/<dataset>/<tag>.json.
set -euo pipefail
cd "$(dirname "$0")/.."
DATASETS="${1:-ami-sdm notsofar-sc voxconverse-test}"
BACKENDS="${2:-legacy community1 nemotron-offline nemotron-fast128}"
DATA="${BAKEOFF_DATA:-$(cd "$(git rev-parse --path-format=absolute --git-common-dir)/.." && pwd)/.build/public-data}"
mkdir -p "$DATA"
scripts/mac-heavy.sh bakeoff-build swift build -c release --product murmur-eval
TMP_HOME="$(mktemp -d "${TMPDIR:-/tmp}/bakeoff-home.XXXXXX")"
trap 'rm -rf "$TMP_HOME"' EXIT
for dataset in $DATASETS; do
  for backend in $BACKENDS; do
    echo "== $dataset · $backend"
    HOME="$TMP_HOME" MURMUR_HOME="$TMP_HOME" scripts/mac-heavy.sh "bakeoff-$backend-$dataset" \
      .build/release/murmur-eval diarize-bakeoff --diarizer "$backend" --dataset "$dataset" --data-dir "$DATA" ${BAKEOFF_ARGS:-} \
      || echo "FAILED $dataset · $backend (exit $?)"
  done
done
python3 -I scripts/diarizer_bakeoff_table.py "$DATA/diarizer-bakeoff"
