#!/bin/bash
# Copies the release murmur-eval with its metallib and bundles to .build/meetings-hillclimb/bin/<label>,
# so a queued scorecard run keeps the binary it was started with while the next attempt builds.
#   MURMUR_EVAL=$(scripts/meeting-eval/snapshot-eval.sh <label> [build dir]) scripts/meeting-eval/scorecard.sh ...
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DEST="$ROOT/.build/meetings-hillclimb/bin/${1:?label}"
BUILD="${2:-$ROOT/.build}"
rm -rf "$DEST" && mkdir -p "$DEST"
cp -c "$BUILD/release/murmur-eval" "$BUILD/release/mlx.metallib" "$DEST/"
cp -c -R "$BUILD"/release/*.bundle "$DEST/"
echo "$DEST/murmur-eval"
