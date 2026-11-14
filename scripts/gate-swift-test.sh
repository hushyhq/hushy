#!/usr/bin/env bash
# Runs the full Swift test suite for the gate with a throwaway app home, queued behind other
# heavy Mac jobs. The tests never see the real app data folder.
#
#   scripts/gate-swift-test.sh [extra swift test arguments]
set -euo pipefail
cd "$(dirname "$0")/.."
HOME_DIR="$(mktemp -d "${TMPDIR:-/tmp}/hushy-gate-home.XXXXXX")"
trap 'rm -rf -- "${HOME_DIR:?}"' EXIT
status=0
HUSHY_HOME="$HOME_DIR" MURMUR_HOME="$HOME_DIR" scripts/mac-heavy.sh gate-swift-test swift test -j 4 "$@" || status=$?
exit "$status"
