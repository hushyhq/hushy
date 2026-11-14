#!/bin/bash
# Headless mock-microphone test: Hushy's own capture, dictation, note recording and remembered-voice
# code, fed from BlackHole 2ch by a player. Synthetic `say` voices by default.
#
#   scripts/mock-mic.sh [--report <dir>] [--clips <dir>] [--keep]
#
#   --report <dir>   where mock-mic.json goes (default: .build/mock-mic-report)
#   --clips <dir>    use your own clips.json + WAVs instead of synthesising with `say`
#                    (see docs/guide/MOCK-MIC.md; thresholds are reported, not enforced)
#   --keep           keep the temp work folder (clips) and the throwaway home
#
# Exit codes: 0 pass, 1 a scenario failed, 2 usage, 3 refused (unsafe home), 4 blocked (capture was
# all zeros: microphone permission), 77 skipped (no BlackHole device, or a model is not on disk).
#
# Safe by construction: needs a throwaway HUSHY_HOME (created here), opens only the virtual
# "BlackHole 2ch" input, never changes a system audio default, downloads nothing. Needs the real
# time of the clips (about five to six minutes for the built-in set). Standalone: not part of
# run-evals.sh or `swift test`. The whole run holds the shared heavy-job lock once (no nesting).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPORT="$ROOT/.build/mock-mic-report"; CLIPS=""; KEEP=0
while [ $# -gt 0 ]; do
    case "$1" in
        --report) REPORT="${2:?--report needs a folder}"; shift 2 ;;
        --clips) CLIPS="${2:?--clips needs a folder}"; shift 2 ;;
        --keep) KEEP=1; shift ;;
        -h|--help) sed -n 2,19p "$0"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

# Take the shared lock once, then run the rest of this script inside it.
if [ -z "${HUSHY_MOCK_MIC_INNER:-}" ]; then
    export HUSHY_MOCK_MIC_INNER=1
    args=(--report "$REPORT"); [ -n "$CLIPS" ] && args+=(--clips "$CLIPS"); [ "$KEEP" = 1 ] && args+=(--keep)
    exec "$ROOT/scripts/mac-heavy.sh" mock-mic bash "$0" "${args[@]}"
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/hushy-mock-mic.XXXXXX")"
export HUSHY_HOME="$WORK/home" MURMUR_HOME="$WORK/home"
mkdir -p "$HUSHY_HOME" "$REPORT"
cleanup() { [ "$KEEP" = 1 ] && echo "kept: $WORK" || rm -rf "$WORK"; }
trap cleanup EXIT

echo "== build"
cd "$ROOT"
swift build -j 4 --product Murmur 2>&1 | tail -3
mkdir -p "$WORK/bin"
swiftc -O tools/audio-loopback/main.swift -o "$WORK/bin/play"
APP="$ROOT/.build/debug/Murmur"

if [ -z "$CLIPS" ]; then
    CLIPS="$WORK/clips"
    echo "== synthesise"
    "$APP" --mock-mic-jobs "$CLIPS"
    while IFS=$'\t' read -r voice path text; do
        [ -n "$voice" ] || continue
        say -v "$voice" -o "$CLIPS/$path" --data-format=LEI16@48000 "$text"
    done < "$CLIPS/jobs.tsv"
    "$APP" --mock-mic-assemble "$CLIPS"
fi

echo "== run"
set +e
"$APP" --mock-mic "$REPORT" --clips "$CLIPS" --player "$WORK/bin/play"
STATUS=$?
set -e
echo "report: $REPORT/mock-mic.json (exit $STATUS)"
exit $STATUS
