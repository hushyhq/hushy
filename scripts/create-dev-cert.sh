#!/usr/bin/env bash
# Creates a local, self-signed code-signing identity ("Murmur Dev" by default) in your login
# keychain. Signing every build with the same identity keeps macOS Accessibility and Microphone
# permissions across rebuilds. Run once; build-app.sh picks it up automatically (it prefers a
# "Hushy Dev" identity if present, else falls back to "Murmur Dev" — see build-app.sh for why
# we don't switch the default automatically: it costs one permission re-grant).
#
# Usage: scripts/create-dev-cert.sh [--name "Hushy Dev"]
set -euo pipefail
NAME="Murmur Dev"
if [ "${1:-}" = "--name" ] && [ -n "${2:-}" ]; then
  NAME="$2"
fi
if security find-certificate -c "$NAME" >/dev/null 2>&1; then
  echo "\"$NAME\" already exists."; exit 0
fi
TMP="$(mktemp -d)"
cat > "$TMP/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
CNF
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cert.cnf" \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" >/dev/null 2>&1
openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
  -out "$TMP/id.p12" -passout pass:murmur >/dev/null 2>&1 || \
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
  -out "$TMP/id.p12" -passout pass:murmur >/dev/null 2>&1
security import "$TMP/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P murmur -T /usr/bin/codesign
rm -rf "$TMP"
echo "Created signing identity \"$NAME\"."
