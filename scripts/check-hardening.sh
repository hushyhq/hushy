#!/bin/bash
# Hardening checks for the shipped app (sealed models, docs/engineering/SEALED-MODELS.md): the weights are only ever
# plaintext inside Hushy's own process, so no other process may be able to attach to it, inject code into it or
# load code that is not signed alike.
#
#   scripts/check-hardening.sh                       checks the repository: Resources/Murmur.entitlements and the signing flags
#   scripts/check-hardening.sh --app build/Hushy.app checks a signed bundle too: its entitlements, and that the
#                                                    hardened runtime flag is set (release builds; a dev-signed build is not hardened)
#   scripts/check-hardening.sh --entitlements <plist>   checks one entitlements file only
#
# Fails (exit 1) when the entitlements hold any of these set to true:
#   com.apple.security.get-task-allow                         lets any process of the same user attach a debugger and read memory
#   com.apple.security.cs.disable-library-validation          lets the process load libraries signed by someone else
#   com.apple.security.cs.allow-dyld-environment-variables    lets DYLD_INSERT_LIBRARIES put code into the process
# and, for --app, when the code signature has no `runtime` flag.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FORBIDDEN=(
  com.apple.security.get-task-allow
  com.apple.security.cs.disable-library-validation
  com.apple.security.cs.allow-dyld-environment-variables
)
APP=""; ENTITLEMENTS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --app) APP="${2:?--app needs a bundle path}"; shift 2 ;;
    --entitlements) ENTITLEMENTS="${2:?--entitlements needs a plist path}"; shift 2 ;;
    *) echo "usage: check-hardening.sh [--app <bundle>] [--entitlements <plist>]" >&2; exit 2 ;;
  esac
done

failed=0
fail() { echo "FAIL: $*" >&2; failed=1; }

check_plist() {
  local plist="$1" label="$2" key value
  [ -s "$plist" ] || { echo "ok:   $label has no entitlements"; return 0; }
  plutil -lint "$plist" >/dev/null 2>&1 || { fail "$label: not a valid property list"; return 0; }
  for key in "${FORBIDDEN[@]}"; do
    # PlistBuddy takes the key as one path segment; plutil would read the dots in it as nesting.
    value="$(/usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null || true)"
    if [ "$value" = "true" ]; then fail "$label sets $key"; else echo "ok:   $label does not set $key"; fi
  done
}

if [ -n "$ENTITLEMENTS" ]; then
  check_plist "$ENTITLEMENTS" "$ENTITLEMENTS"
else
  check_plist "$ROOT/Resources/Murmur.entitlements" "Resources/Murmur.entitlements"
  # Release signing must ask for the hardened runtime: build-app.sh passes --options runtime for any
  # Developer ID / explicit identity, and release.sh builds through it.
  if grep -q -- '--options runtime' "$ROOT/scripts/build-app.sh"; then
    echo "ok:   scripts/build-app.sh signs with --options runtime"
  else
    fail "scripts/build-app.sh does not sign with --options runtime"
  fi
fi

if [ -n "$APP" ]; then
  [ -d "$APP" ] || { echo "no such bundle: $APP" >&2; exit 2; }
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  # The entitlements are public (they are in every signed app); nothing secret is written here.
  codesign -d --entitlements :- "$APP" >"$tmp/entitlements.plist" 2>/dev/null || true
  check_plist "$tmp/entitlements.plist" "$(basename "$APP") (signed)"
  if codesign -d --verbose=2 "$APP" 2>&1 | grep -E 'flags=0x[0-9a-f]+\(' | grep -q 'runtime'; then
    echo "ok:   $(basename "$APP") has the hardened runtime flag"
  else
    fail "$(basename "$APP") has no hardened runtime flag (dev-signed builds do not; release builds must)"
  fi
fi

[ "$failed" = 0 ] && echo "hardening checks passed" || { echo "hardening checks FAILED" >&2; exit 1; }
