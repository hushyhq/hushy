#!/usr/bin/env bash
# Checks the Developer ID identity choice in scripts/build-app.sh against invented
# `security find-identity` output. Touches no keychain.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/lib/developer-id.sh"

fail=0
expect() { # name expected actual
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected '$2', got '$3'" >&2; fail=1; fi
}

mine='  1) A000000000000000000000000000000000000000 "Developer ID Application: Ada Example (RY2CM3XV32)"'
other='  2) B1111111111111111111111111111111111111111 "Developer ID Application: Someone Else (ABCDE12345)"'
dev='  3) C2222222222222222222222222222222222222222 "Hushy Dev"'
apple='  4) D3333333333333333333333333333333333333333 "Apple Development: Ada (RY2CM3XV32)"'
second='  5) E4444444444444444444444444444444444444444 "Developer ID Application: Ada Example (RY2CM3XV32)"'
tail='     5 valid identities found'

pick() { printf '%s\n' "$@" | developer_id_identity "$HUSHY_TEAM_ID"; }

expect "finds the team's Developer ID" "A000000000000000000000000000000000000000" "$(pick "$other" "$mine" "$dev" "$tail")"
expect "ignores other teams' Developer ID" "" "$(pick "$other" "$dev" "$tail")"
expect "ignores non-Developer-ID certificates of the same team" "" "$(pick "$apple" "$dev" "$tail")"
expect "empty keychain gives nothing" "" "$(pick "     0 valid identities found")"
expect "first match wins" "A000000000000000000000000000000000000000" "$(pick "$mine" "$second" "$tail")"
exit "$fail"
