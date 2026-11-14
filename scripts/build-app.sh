#!/usr/bin/env bash
# Builds Hushy.app into ./build from the Swift package.
#
# The app was renamed Murmur -> Hushy (see .claude/DECISIONS.md); the Swift package/module
# names (Murmur, MurmurCore, murmur-mcp) are unchanged on purpose, so this script builds the
# same targets it always did and renames the assembled app bundle, its main executable, and
# the bundled MCP helper binary (murmur-mcp target -> hushy-mcp on disk, since that binary's
# name is what AI clients and macOS TCC prompts show the user).
#
# Usage: scripts/build-app.sh [--debug] [--meetings-preview] [--open]
#   --debug             faster, unoptimized build
#   --meetings-preview  optimized build with meetings switched on (FeatureFlags.meetings) for a
#                       founder test; built in its own .build/meetings-preview folder so the
#                       release objects stay untouched. release.sh never passes it.
#   --open              launch the app when done
#
# A preview or test build (--meetings-preview, or HUSHY_TEST_FEATURES set) is assembled as
# build/Hushy-Preview.app with HushyPreviewBuild = true in its Info.plist, so it never takes the
# release bundle's place and scripts/publish-update.sh refuses it.
#
# Signing: uses $MURMUR_SIGN_IDENTITY if set (e.g. "Developer ID Application: …"), otherwise
# the Developer ID Application identity of team RY2CM3XV32 from the keychain, signed exactly as a
# release build is (hardened runtime, same entitlements), so macOS keeps the Microphone and
# Accessibility grants across rebuilds and between dev and release builds. Dev builds are not
# notarized. With no such identity it falls back to the local dev certificate, and then macOS
# asks for the permissions again after each rebuild.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CONFIG=release
OPEN=0
PREVIEW=0
for arg in "$@"; do
  case "$arg" in
    --debug) CONFIG=debug ;;
    --meetings-preview) PREVIEW=1 ;;
    --open) OPEN=1 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

PREVIEW_BUILD=0
if [ "$PREVIEW" = 1 ] || [ -n "${HUSHY_TEST_FEATURES:-}" ]; then PREVIEW_BUILD=1; fi
if [ "$PREVIEW_BUILD" = 1 ]; then APP="$ROOT/build/Hushy-Preview.app"; else APP="$ROOT/build/Hushy.app"; fi
CONTENTS="$APP/Contents"
VERSION="$(cat VERSION 2>/dev/null || echo 1.0.0)"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

SWIFT_FLAGS=()
if [ "$PREVIEW" = 1 ]; then
  SWIFT_FLAGS=(--scratch-path "$ROOT/.build/meetings-preview" -Xswiftc -DHUSHY_MEETINGS_PREVIEW)
  if [ ! -d "$ROOT/.build/meetings-preview/checkouts" ] && [ -d "$ROOT/.build/checkouts" ]; then
    mkdir -p "$ROOT/.build/meetings-preview"
    for d in checkouts repositories artifacts; do
      [ -d "$ROOT/.build/$d" ] && cp -c -R "$ROOT/.build/$d" "$ROOT/.build/meetings-preview/$d"
    done
    sed "s#$ROOT/.build/#$ROOT/.build/meetings-preview/#g" "$ROOT/.build/workspace-state.json" \
      > "$ROOT/.build/meetings-preview/workspace-state.json"
  fi
fi

echo "==> Building ($CONFIG$([ "$PREVIEW" = 1 ] && echo ", meetings preview"))"
swift build -j 4 -c "$CONFIG" ${SWIFT_FLAGS[@]+"${SWIFT_FLAGS[@]}"} --product Murmur
swift build -j 4 -c "$CONFIG" ${SWIFT_FLAGS[@]+"${SWIFT_FLAGS[@]}"} --product murmur-mcp
BIN_DIR="$(swift build -j 4 -c "$CONFIG" ${SWIFT_FLAGS[@]+"${SWIFT_FLAGS[@]}"} --show-bin-path)"

# MLX's Metal kernels (the optional on-device cleanup model, HushyModelsMLX). SwiftPM can't
# compile .metal files, so scripts/build-mlx-metallib.sh builds mlx.metallib once per mlx-swift
# version (needs `xcodebuild -downloadComponent MetalToolchain`) and drops it in $BIN_DIR.
echo "==> MLX Metal kernels"
"$ROOT/scripts/build-mlx-metallib.sh" "$CONFIG"
if [ "$PREVIEW" = 1 ] && [ ! -f "$BIN_DIR/mlx.metallib" ]; then
  LIB="$(ls -t "$ROOT"/.build/mlx-metallib/*/mlx.metallib 2>/dev/null | head -1)"
  [ -n "$LIB" ] && cp "$LIB" "$BIN_DIR/mlx.metallib"
fi
if [ ! -f "$BIN_DIR/mlx.metallib" ]; then
  echo "mlx.metallib missing from $BIN_DIR" >&2
  exit 1
fi

echo "==> Assembling $APP"
rm -rf "$APP" "$ROOT/build/Murmur.app"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources" "$CONTENTS/Frameworks"
# The Swift executable target is still named "Murmur" (see .claude/DECISIONS.md); the app
# bundle's binary is renamed to match CFBundleExecutable ("Hushy") in Info.plist.
cp "$BIN_DIR/Murmur" "$CONTENTS/MacOS/Hushy"
# The Swift target is still named murmur-mcp (see .claude/DECISIONS.md), but the shipped
# binary is renamed to hushy-mcp here: this is the file AI clients (Claude Desktop/Code,
# Codex, Cursor) launch as a subprocess and the one macOS attributes TCC/permission prompts
# to, so its on-disk name is user-visible even though the Swift target name is not.
# MCPInstaller.serverPath resolves this path relative to Bundle.main.executableURL, so no
# separate path fix is needed there beyond the name below matching what it looks for.
cp "$BIN_DIR/murmur-mcp" "$CONTENTS/MacOS/hushy-mcp"

# SwiftPM resource bundles (e.g. from FluidAudio) live next to the binary.
shopt -s nullglob
for bundle in "$BIN_DIR"/*.bundle; do
  cp -R "$bundle" "$CONTENTS/Resources/"
done
# MLX finds its kernels as default.metallib inside an `mlx-swift_Cmlx` resource bundle in any
# loaded bundle's resources (mlx/backend/metal/device.cpp) — here, the app's Contents/Resources.
# A flat bundle, like the SwiftPM ones above, so the app signature seals it as a resource.
mkdir -p "$CONTENTS/Resources/mlx-swift_Cmlx.bundle"
cp "$BIN_DIR/mlx.metallib" "$CONTENTS/Resources/mlx-swift_Cmlx.bundle/default.metallib"
# Licence texts for downloadable models (Apache-2.0 requires the text to travel with the weights).
mkdir -p "$CONTENTS/Resources/Licenses"
cp "$ROOT"/Resources/Licenses/*.txt "$CONTENTS/Resources/Licenses/"
# Any dynamic frameworks the binary links against.
for framework in "$BIN_DIR"/*.framework; do
  cp -R "$framework" "$CONTENTS/Frameworks/"
done
# Swift's back-deployment library for Span. The binary weak-links it by @rpath; macOS 26+ has
# it in /usr/lib/swift and a Mac with Xcode finds the toolchain's copy, but a plain macOS 15
# install has neither, so the first use of a Span type would crash there. Xcode embeds it for
# app targets; SwiftPM does not, so do it here. /usr/lib/swift stays first in the rpath, so
# newer systems keep using their own.
if otool -L "$CONTENTS/MacOS/Hushy" | grep -q "@rpath/libswiftCompatibilitySpan.dylib"; then
  SPAN_COMPAT=""
  for candidate in "$(dirname "$(xcrun --find swiftc)")"/../lib/swift-*/macosx/libswiftCompatibilitySpan.dylib; do
    SPAN_COMPAT="$candidate"
  done
  if [ -z "$SPAN_COMPAT" ]; then
    echo "error: Hushy links libswiftCompatibilitySpan.dylib but the toolchain has no copy to embed" >&2
    exit 1
  fi
  cp "$SPAN_COMPAT" "$CONTENTS/Frameworks/"
fi
shopt -u nullglob
if [ -n "$(ls -A "$CONTENTS/Frameworks")" ]; then
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$CONTENTS/MacOS/Hushy" 2>/dev/null || true
else
  rmdir "$CONTENTS/Frameworks"
fi

# Sparkle feed/key: substituted from the environment for release builds (see
# docs/guide/RELEASE.md); left empty otherwise, which the app treats as "not configured".
APPCAST_URL="${HUSHY_APPCAST_URL:-}"
SPARKLE_PUBLIC_KEY="${HUSHY_SPARKLE_PUBLIC_KEY:-}"
# Invite-code verification key (public only; docs/guide/INVITES.md). Empty → invites disabled.
INVITE_PUBLIC_KEY="${HUSHY_INVITE_PUBLIC_KEY:-$(cat "$HOME/.config/hushy/invite_public_key" 2>/dev/null | tr -d '[:space:]')}"
# Direct calendar connectors (docs/product/CONNECTORS.md §6.8). Empty → provider hidden.
# Google's Desktop-client "secret" is not confidential (Google's words) but is still kept out of
# the repo and never echoed. Values are restricted to [A-Za-z0-9._-]; anything else is dropped
# (with a warning that names only the variable) rather than risk corrupting Info.plist.
connector_value() {
  local name="$1" value="${!1:-}"
  if [ -n "$value" ] && ! [[ "$value" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "warning: $name has unexpected characters; calendar connector left unconfigured" >&2
    value=""
  fi
  printf '%s' "$value"
}
# Hosted services (HushyServices in Info.plist; Sources/MurmurCore/Accounts/HushyServices.swift).
# The maintainers' checkout carries scripts/official-services.env, which sets HUSHY_SERVICES=official
# and the account service's address. Without it (a copy built from source) the default is none:
# no account, no sign-in gate, nothing sent to the Hushy site. HUSHY_SERVICES=none forces that.
if [ "${HUSHY_SERVICES:-}" != none ] && [ -f "$ROOT/scripts/official-services.env" ]; then
  # shellcheck source=/dev/null
  . "$ROOT/scripts/official-services.env"
fi
SERVICES="${HUSHY_SERVICES:-none}"
case "$SERVICES" in
  official|none) ;;
  *) echo "error: HUSHY_SERVICES must be 'official' or 'none'" >&2; exit 1;;
esac
if [ "$SERVICES" = official ]; then
  SUPABASE_URL="${HUSHY_SUPABASE_URL:-}"
  SUPABASE_ANON_KEY="${HUSHY_SUPABASE_ANON_KEY:-}"
  if [ -z "$SUPABASE_URL" ] || [ -z "$SUPABASE_ANON_KEY" ]; then
    echo "error: HUSHY_SERVICES=official needs HUSHY_SUPABASE_URL and HUSHY_SUPABASE_ANON_KEY" >&2; exit 1
  fi
else
  SUPABASE_URL=""
  SUPABASE_ANON_KEY=""
fi
echo "==> Services: $SERVICES"
PADDLE_PORTAL_URL="${HUSHY_PADDLE_PORTAL_URL:-}"
# Usage-numbers endpoint (https only). Unset → empty → the app never contacts anything for them.
USAGE_METRICS_ENDPOINT="${HUSHY_USAGE_METRICS_ENDPOINT:-}"
# Features switched on for a founder test build (FeatureFlags reads HushyTestFeatures), e.g.
# HUSHY_TEST_FEATURES=voice-edit or voice-edit,meeting-ask (cross-meeting Ask, People, prep brief). Letters, digits, "-" and "," only; anything else leaves it empty.
TEST_FEATURES="${HUSHY_TEST_FEATURES:-}"
if [ -n "$TEST_FEATURES" ] && ! [[ "$TEST_FEATURES" =~ ^[a-z0-9,-]+$ ]]; then
  echo "warning: HUSHY_TEST_FEATURES has unexpected characters; no test features" >&2
  TEST_FEATURES=""
fi
if [ -n "$TEST_FEATURES" ]; then echo "==> Test features: $TEST_FEATURES"; fi
PADDLE_MONTHLY_PRICE_ID="$(connector_value HUSHY_PADDLE_MONTHLY_PRICE_ID)"
PADDLE_YEARLY_PRICE_ID="$(connector_value HUSHY_PADDLE_YEARLY_PRICE_ID)"
GOOGLE_OAUTH_CLIENT_ID="$(connector_value HUSHY_GOOGLE_OAUTH_CLIENT_ID)"
GOOGLE_OAUTH_CLIENT_SECRET="$(connector_value HUSHY_GOOGLE_OAUTH_CLIENT_SECRET)"
MICROSOFT_OAUTH_CLIENT_ID="$(connector_value HUSHY_MICROSOFT_OAUTH_CLIENT_ID)"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUMBER/" \
  -e "s|__APPCAST_URL__|$APPCAST_URL|" -e "s|__SPARKLE_ED_PUBLIC_KEY__|$SPARKLE_PUBLIC_KEY|" \
  -e "s|__INVITE_PUBLIC_KEY__|$INVITE_PUBLIC_KEY|" \
  -e "s|__GOOGLE_OAUTH_CLIENT_ID__|$GOOGLE_OAUTH_CLIENT_ID|" \
  -e "s|__GOOGLE_OAUTH_CLIENT_SECRET__|$GOOGLE_OAUTH_CLIENT_SECRET|" \
  -e "s|__MICROSOFT_OAUTH_CLIENT_ID__|$MICROSOFT_OAUTH_CLIENT_ID|" \
  -e "s|__HUSHY_SERVICES__|$SERVICES|" \
  -e "s|__SUPABASE_URL__|$SUPABASE_URL|" \
  -e "s|__SUPABASE_ANON_KEY__|$SUPABASE_ANON_KEY|" \
  -e "s|__PADDLE_PORTAL_URL__|$PADDLE_PORTAL_URL|" \
  -e "s|__USAGE_METRICS_ENDPOINT__|$USAGE_METRICS_ENDPOINT|" \
  -e "s|__TEST_FEATURES__|$TEST_FEATURES|" \
  -e "s|__PADDLE_MONTHLY_PRICE_ID__|$PADDLE_MONTHLY_PRICE_ID|" \
  -e "s|__PADDLE_YEARLY_PRICE_ID__|$PADDLE_YEARLY_PRICE_ID|" \
  "$ROOT/Resources/Info.plist" > "$CONTENTS/Info.plist"
if [ "$PREVIEW_BUILD" = 1 ]; then
  /usr/libexec/PlistBuddy -c "Add :HushyPreviewBuild bool true" "$CONTENTS/Info.plist"
fi
printf 'APPL????' > "$CONTENTS/PkgInfo"

echo "==> Icon"
if [ ! -f "$ROOT/build/AppIcon.icns" ] || [ "$ROOT/scripts/make-icon.swift" -nt "$ROOT/build/AppIcon.icns" ]; then
  swift "$ROOT/scripts/make-icon.swift" "$ROOT/build/AppIcon.iconset"
  iconutil -c icns "$ROOT/build/AppIcon.iconset" -o "$ROOT/build/AppIcon.icns"
fi
cp "$ROOT/build/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"

echo "==> Signing"
# Prefers a "Hushy Dev" identity if one exists in the keychain; otherwise falls back to the
# legacy "Murmur Dev" identity (created if missing) so existing checkouts keep working without
# manual setup. We do NOT generate a "Hushy Dev" certificate automatically: creating one is a
# one-time opt-in (see scripts/create-dev-cert.sh --name "Hushy Dev") because switching signing
# identities changes the code signature's designated requirement, which makes macOS treat the
# app as "different" and re-ask for Microphone and Accessibility once, even though the bundle
# id didn't change. $MURMUR_SIGN_IDENTITY still overrides both (e.g. a real "Developer ID
# Application: …" identity for notarized builds). See .claude/DECISIONS.md.
IDENTITY="${MURMUR_SIGN_IDENTITY:-}"
# shellcheck source=lib/developer-id.sh
. "$ROOT/scripts/lib/developer-id.sh"
if [ -z "$IDENTITY" ]; then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | developer_id_identity "$HUSHY_TEAM_ID" || true)"
  if [ -n "$IDENTITY" ]; then
    echo "    (signing with the Developer ID Application identity of team $HUSHY_TEAM_ID, like a release build; permissions carry over between rebuilds. Not notarized.)"
  else
    echo "    (no Developer ID Application identity for team $HUSHY_TEAM_ID in the keychain: signing with a local dev certificate, so Microphone and Accessibility permissions will not carry over between rebuilds)"
  fi
fi
if [ -z "$IDENTITY" ]; then
  if security find-certificate -c "Hushy Dev" >/dev/null 2>&1; then
    IDENTITY="Hushy Dev"
  else
    "$ROOT/scripts/create-dev-cert.sh" >/dev/null
    IDENTITY="Murmur Dev"
    echo "    (using legacy \"Murmur Dev\" signing identity; run scripts/create-dev-cert.sh --name \"Hushy Dev\" to switch — this will cost one re-grant of Microphone/Accessibility)"
  fi
fi
SIGN_FLAGS=(--force --timestamp=none --sign "$IDENTITY")
if [ "$IDENTITY" != "-" ] && [ "$IDENTITY" != "Murmur Dev" ] && [ "$IDENTITY" != "Hushy Dev" ]; then
  # A secure timestamp needs Apple's server and is only required for notarization, so only an
  # explicitly chosen identity (release.sh sets MURMUR_SIGN_IDENTITY) asks for one. A dev build
  # that picked the Developer ID itself signs offline; the timestamp does not change the
  # designated requirement, so permissions still carry over.
  if [ -n "${MURMUR_SIGN_IDENTITY:-}" ]; then
    SIGN_FLAGS=(--force --timestamp --options runtime --sign "$IDENTITY")
  else
    SIGN_FLAGS=(--force --timestamp=none --options runtime --sign "$IDENTITY")
  fi
fi
# Sparkle.framework ships pre-signed by the Sparkle project. For a Developer ID build every
# nested executable must carry *our* signature (notarization rejects mixed teams), so sign
# the XPC services, Autoupdate and Updater.app inside-out before the framework itself —
# Sparkle's documented order for non-"--deep" signing. Dev identities skip this: the
# framework's own signature stays valid and Gatekeeper isn't involved.
sign_sparkle_nested() {
  local fw="$1" versions="$1/Versions/B"
  [ -d "$versions" ] || return 0
  for xpc in "$versions/XPCServices"/*.xpc; do
    [ -e "$xpc" ] || continue
    codesign "${SIGN_FLAGS[@]}" --preserve-metadata=entitlements "$xpc"
  done
  [ -e "$versions/Autoupdate" ] && codesign "${SIGN_FLAGS[@]}" "$versions/Autoupdate"
  [ -e "$versions/Updater.app" ] && codesign "${SIGN_FLAGS[@]}" "$versions/Updater.app"
  return 0
}
if [ -d "$CONTENTS/Frameworks" ]; then
  for framework in "$CONTENTS/Frameworks"/*; do
    if [ "$IDENTITY" != "-" ] && [ "$IDENTITY" != "Murmur Dev" ] && [ "$IDENTITY" != "Hushy Dev" ] \
       && [ "$(basename "$framework")" = "Sparkle.framework" ]; then
      sign_sparkle_nested "$framework"
    fi
    codesign "${SIGN_FLAGS[@]}" "$framework"
  done
fi
codesign "${SIGN_FLAGS[@]}" --identifier app.hushy.mcp "$CONTENTS/MacOS/hushy-mcp"
codesign "${SIGN_FLAGS[@]}" --entitlements "$ROOT/Resources/Murmur.entitlements" "$APP"
codesign --verify --strict "$APP"

echo "==> Done: $APP ($(du -sh "$APP" | cut -f1))"
if [ "$OPEN" = 1 ]; then
  pkill -x Hushy 2>/dev/null || true
  open "$APP"
fi
