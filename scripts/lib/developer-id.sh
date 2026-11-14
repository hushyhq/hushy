# Sourced by scripts/build-app.sh and scripts/test-developer-id.sh.
#
# Hushy's Developer ID team. macOS keys the Microphone and Accessibility grants on the bundle id
# plus the signing requirement, which for a Developer ID build names this team, so every build
# signed with it (release or dev) counts as the same app.
HUSHY_TEAM_ID="RY2CM3XV32"

# Reads `security find-identity -v -p codesigning` on stdin and prints the SHA-1 hash of the
# first valid "Developer ID Application" identity of team $1 (a hash stays unambiguous even if
# the keychain holds two certificates with the same name). Prints nothing when there is none.
developer_id_identity() {
  grep -F '"Developer ID Application: ' | grep -F "($1)\"" | head -n 1 | awk '{ print $2 }'
}
