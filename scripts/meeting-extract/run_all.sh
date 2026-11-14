#!/bin/sh
# Rebuilds every staged and final file. Needs numpy (the finetune venv has it).
set -eu
cd "$(dirname "$0")"
PY=${PY:-$(cd ../.. && pwd)/.build/finetune-venv/bin/python}
for s in ami icsi; do "$PY" build_nxt.py "$s"; done
for s in elitr qmsum meetingbank notsofar; do "$PY" build_other.py "$s"; done
"$PY" assemble.py
