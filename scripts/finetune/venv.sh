#!/bin/bash
# Prints the python of the fine-tune venv, creating it on first use (mlx-lm pinned).
# FINETUNE_VENV overrides the location (default: .build/finetune-venv, gitignored).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
VENV="${FINETUNE_VENV:-$ROOT/.build/finetune-venv}"
if [ ! -x "$VENV/bin/python" ]; then
    uv venv --python 3.12 "$VENV" >&2
    VIRTUAL_ENV="$VENV" uv pip install -r "$(dirname "$0")/requirements-mlx.txt" >&2
fi
echo "$VENV/bin/python"
