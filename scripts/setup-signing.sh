#!/usr/bin/env bash
# Creates a local code-signing identity once, in the login keychain ("Duv Rec Local" by default).
#
# Why: an ad-hoc signature (`codesign --sign -`) changes with every build, so macOS treats each
# build as a new app and asks again for Screen Recording, Camera and Microphone. A signature from
# one stable certificate gives every build the same identity, so the grants survive rebuilds.
# Free, self-signed, never leaves this Mac. Safe to run again: it does nothing if the identity exists.
set -euo pipefail

NAME="${DUVREC_SIGN_IDENTITY:-Duv Rec Local}"

if security find-identity -p codesigning | grep -q "\"$NAME\""; then
  echo "Signing identity \"$NAME\" already exists."
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PASS="duvrec-$(date +%s)"

cat > "$WORK/openssl.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF

/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -config "$WORK/openssl.cnf" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -name "$NAME" -passout "pass:$PASS" -out "$WORK/id.p12" 2>/dev/null

security import "$WORK/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
  -P "$PASS" -T /usr/bin/codesign >/dev/null

# Trusted for code signing (macOS asks for your password once).
security add-trusted-cert -r trustRoot -p codeSign -k "$HOME/Library/Keychains/login.keychain-db" "$WORK/cert.pem"

echo "Created signing identity \"$NAME\"."
