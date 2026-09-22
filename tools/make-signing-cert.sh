#!/bin/bash
# Creates the self-signed code signing identity that build.sh signs with, once.
#
# Why: ad-hoc signing gives the app a new identity on every build, and macOS ties
# the Bluetooth permission to that identity — so every rebuild made it ask again,
# and a forgotten grant looks exactly like the app being broken. A fixed
# certificate keeps the app's designated requirement stable across rebuilds, so
# the grant sticks.
#
# The private key lives in the login keychain, not in this repo. Safe to re-run:
# it exits if the identity already exists.
set -euo pipefail

NAME="Simple Battery Self Signed"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

# Without -v, because a self-signed certificate is reported as
# CSSMERR_TP_NOT_TRUSTED and left out of the "valid identities" list. codesign
# still signs with it happily, and trust only matters to Gatekeeper, which has
# no say over an app built and run on this machine.
if security find-identity -p codesigning 2>/dev/null | grep -qF "$NAME"; then
  echo "Identity already there:"
  security find-identity -p codesigning | grep -F "$NAME"
  exit 0
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# A config file rather than -addext, which LibreSSL versions disagree about.
cat > "$WORK/cert.cnf" <<CNF
[ req ]
distinguished_name = dn
x509_extensions = v3
prompt = no

[ dn ]
CN = $NAME

[ v3 ]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
CNF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -config "$WORK/cert.cnf" 2>/dev/null

openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -name "$NAME" -out "$WORK/identity.p12" -passout pass:simplebattery 2>/dev/null

# -T lets codesign use the key. macOS may still ask once for keychain access the
# first time it signs: click "Always Allow".
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P simplebattery \
  -f pkcs12 -T /usr/bin/codesign >/dev/null

echo "Created:"
security find-identity -p codesigning | grep -F "$NAME" || {
  echo "Imported, but codesign cannot see it. Sign ad-hoc for now." >&2
  exit 1
}
