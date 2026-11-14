#!/bin/bash
# Plays the pill's states and motion with invented text, in a small application of its own:
# no microphone, no model, no history, nothing copied or pasted. For feeling how the pill moves.
#
#   scripts/pill-preview.sh [--app <Hushy.app or binary>] [--scene <name>] [--speed 1|0.5|0.25] [--loop]
#
# It uses a build that already exists (it never builds): build/Hushy.app from scripts/build-app.sh,
# else .build/release/Murmur, else .build/debug/Murmur. The data folder is a new temporary one,
# removed on exit. It can run beside the real Hushy, in either order: it registers no hotkey, opens
# no microphone, shows no Dock icon or menu bar item, and the real app does not count it as a
# second Hushy. Close its window (or press Quit in it) to end it.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET=""
ARGS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --app) TARGET="${2:?--app needs a path}"; shift 2 ;;
        *) ARGS+=("$1"); shift ;;
    esac
done

if [ -z "$TARGET" ]; then
    for candidate in "$ROOT/build/Hushy.app" "$ROOT/.build/release/Murmur" "$ROOT/.build/debug/Murmur"; do
        if [ -e "$candidate" ]; then TARGET="$candidate"; break; fi
    done
fi
if [ -z "$TARGET" ] || [ ! -e "$TARGET" ]; then
    echo "pill-preview: no build found. Build one first, for example:" >&2
    echo "  scripts/mac-heavy.sh preview-build scripts/build-app.sh --debug" >&2
    exit 1
fi
case "$TARGET" in
    *.app) BINARY="$TARGET/Contents/MacOS/Hushy" ;;
    *) BINARY="$TARGET" ;;
esac
if [ ! -x "$BINARY" ]; then
    echo "pill-preview: $BINARY is not runnable" >&2
    exit 1
fi

HOME_DIR="$(mktemp -d "${TMPDIR:-/tmp}/hushy-pill-preview.XXXXXX")"
trap 'rm -rf "$HOME_DIR"' EXIT
echo "pill-preview: $BINARY (data folder $HOME_DIR)"
HUSHY_HOME="$HOME_DIR" MURMUR_HOME="$HOME_DIR" "$BINARY" --pill-preview ${ARGS[@]+"${ARGS[@]}"}
