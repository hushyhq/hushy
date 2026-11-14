#!/usr/bin/env bash
# Writes a store fixture with an old build's own code, for the upgrade tests (StoreUpgradeTests).
#
#   scripts/fixtures/make-store-fixture.sh <git-ref> <out.sqlite> [--meetings]
#
# Checks <git-ref> out into a temporary worktree, adds a throwaway `fixture-writer` executable target there
# (scripts/fixtures/StoreFixtureWriter.swift; never committed to that ref), builds it with that ref's Store,
# and writes the synthetic corpus to <out.sqlite>. --meetings compiles the attendee, jot and consent rows in
# (refs from main after integ/nov7). The built binary is kept at .build/store-fixtures/<ref>/fixture-writer:
# its `list` mode is the rollback check (test 12). No real user data is read or written.
#
# Fixtures in the repo:
#   scripts/fixtures/make-store-fixture.sh v1.0.0-build3005 Tests/MurmurCoreTests/Fixtures/store-build3005.sqlite
#   scripts/fixtures/make-store-fixture.sh bdf01317 Tests/MurmurCoreTests/Fixtures/store-main-bdf01317.sqlite --meetings
set -euo pipefail
REF="${1:?usage: make-store-fixture.sh <git-ref> <out.sqlite> [--meetings]}"
OUT="${2:?usage: make-store-fixture.sh <git-ref> <out.sqlite> [--meetings]}"
DEFINE=()
[ "${3:-}" = "--meetings" ] && DEFINE=(-Xswiftc -DHAS_MEETINGS)

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
case "$OUT" in /*) ;; *) OUT="$ROOT/$OUT" ;; esac
SAFE_REF="$(printf '%s' "$REF" | tr '/' '_')"
KEEP="$ROOT/.build/store-fixtures/$SAFE_REF"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/hushy-store-fixture.XXXXXX")"
WT="$TMP/wt"
cleanup() {
    git -C "$ROOT" worktree remove --force "$WT" >/dev/null 2>&1 || true
    rm -rf -- "${TMP:?}"
}
trap cleanup EXIT

git -C "$ROOT" worktree add --detach "$WT" "$REF" >/dev/null
mkdir -p "$WT/Sources/fixture-writer"
cp "$ROOT/scripts/fixtures/StoreFixtureWriter.swift" "$WT/Sources/fixture-writer/main.swift"
python3 - "$WT/Package.swift" <<'PY'
import sys
path = sys.argv[1]
text = open(path).read()
anchor = "    targets: ["
assert anchor in text, "Package.swift has no targets list"
target = '\n        .executableTarget(name: "fixture-writer", dependencies: ["MurmurCore", .product(name: "GRDB", package: "GRDB.swift")]),'
open(path, "w").write(text.replace(anchor, anchor + target, 1))
PY
# Reuse the main checkout's package checkouts (an APFS clone, not a copy) so the old ref builds without a fetch.
MAIN_CHECKOUT="$(cd "$(git -C "$ROOT" rev-parse --git-common-dir)/.." && pwd)"
if [ -d "$MAIN_CHECKOUT/.build/checkouts" ]; then
    mkdir -p "$WT/.build" && cp -Rc "$MAIN_CHECKOUT/.build/checkouts" "$WT/.build/" 2>/dev/null || true
fi
(cd "$WT" && swift build --product fixture-writer ${DEFINE[@]+"${DEFINE[@]}"} >"$TMP/build.log" 2>&1) || {
    tail -40 "$TMP/build.log" >&2
    exit 1
}
BIN="$(cd "$WT" && swift build --product fixture-writer --show-bin-path ${DEFINE[@]+"${DEFINE[@]}"})/fixture-writer"
mkdir -p "$KEEP" "$(dirname "$OUT")"
cp "$BIN" "$KEEP/fixture-writer"
HOME_DIR="$TMP/home"
mkdir -p "$HOME_DIR"
HUSHY_HOME="$HOME_DIR" MURMUR_HOME="$HOME_DIR" "$KEEP/fixture-writer" write "$TMP/store.sqlite"
rm -f "$TMP/store.sqlite-wal" "$TMP/store.sqlite-shm"
cp "$TMP/store.sqlite" "$OUT"
echo "wrote $OUT from $REF ($(git -C "$ROOT" rev-parse --short "$REF^{commit}")); reader kept at $KEEP/fixture-writer"
