#!/bin/bash
# Creates the "MacLayoutManager Dev" self-signed code-signing identity in the login keychain.
#
# macOS ties an Accessibility grant to the app's designated requirement. An ad-hoc signature makes
# that requirement the code hash, so every rebuild loses the grant; a stable certificate keeps one
# requirement across builds. This identity is local only: it can't be notarized or distributed.
#
# Undo: security delete-certificate -c "MacLayoutManager Dev" ~/Library/Keychains/login.keychain-db
set -euo pipefail

IDENTITY="MacLayoutManager Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "\"$IDENTITY\""; then
    echo "Identity '$IDENTITY' already exists."
    exit 0
fi

# The system LibreSSL has no `req -addext`, so the extensions live in a config file.
cat > "$WORK/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions    = ext
prompt             = no

[dn]
CN = $IDENTITY

[ext]
basicConstraints     = critical,CA:FALSE
keyUsage             = critical,digitalSignature
extendedKeyUsage     = critical,codeSigning
subjectKeyIdentifier = hash
CNF

# Homebrew's OpenSSL 3 writes PKCS#12 algorithms Security.framework rejects, so pin LibreSSL.
OPENSSL=/usr/bin/openssl
"$OPENSSL" req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -config "$WORK/cert.cnf" 2>/dev/null

# `security import` is unreliable with an empty PKCS#12 password, so use a throwaway one.
P12_PASSWORD="$(uuidgen)"
"$OPENSSL" pkcs12 -export -out "$WORK/identity.p12" -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -name "$IDENTITY" -passout "pass:$P12_PASSWORD"
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$P12_PASSWORD" \
    -T /usr/bin/codesign -T /usr/bin/security

# Lets codesign use the key without a keychain dialog on every build.
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -l "$IDENTITY" "$KEYCHAIN" >/dev/null 2>&1 \
    || echo "  set-key-partition-list skipped; codesign may ask for the keychain once"

# Trust for code signing in the user domain only.
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem" \
    || echo "  add-trusted-cert skipped; signing usually still works untrusted"

if security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "\"$IDENTITY\""; then
    echo "Identity '$IDENTITY' is ready."
else
    echo "Identity not visible to codesign; inspect with: security find-identity -v -p codesigning" >&2
    exit 1
fi
