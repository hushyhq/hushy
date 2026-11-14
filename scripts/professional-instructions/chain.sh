#!/usr/bin/env bash
# chain.sh <set> <batch label> <variant>...  : one mac-heavy slot for the batch
HERE="$(cd "$(dirname "$0")" && pwd)"
SET="$1"; L="$2"; shift 2
HUSHY_HEAVY_SLOTS=1 "$HERE/../mac-heavy.sh" "pro-instr-$L" caffeinate -i "$HERE/inner.sh" "$SET" "$@"
echo "BATCH $L DONE"
