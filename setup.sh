#!/bin/bash
# Installs MacLayoutManager: downloads the latest release build, signs it with a stable local
# identity, replaces the copy in /Applications, and launches it. Only --build, which builds this
# checkout instead, needs the Xcode command line tools. Re-running updates the install; layouts live
# in ~/Library/Application Support/MacLayoutManager, outside the bundle.
#
#   curl -fsSL https://github.com/choandrew/MacLayoutManager/releases/latest/download/setup.sh | bash
#   ./setup.sh --build
set -euo pipefail

APP_NAME="MacLayoutManager"
RELEASE_URL="https://github.com/choandrew/MacLayoutManager/releases/latest/download/$APP_NAME.zip"
INSTALLED_APP="/Applications/$APP_NAME.app"
LOCAL_IDENTITY="MacLayoutManager Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# macOS ties an Accessibility grant to the app's designated requirement. An ad-hoc signature makes
# that requirement the code hash, so every update would lose the grant; a self-signed certificate
# keeps one requirement across builds. It is local only: it can't be notarized or distributed.
#
# Undo: security delete-certificate -c "MacLayoutManager Dev" ~/Library/Keychains/login.keychain-db
create_local_identity() {
    # The system LibreSSL has no `req -addext`, so the extensions live in a config file.
    cat > "$WORK/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions    = ext
prompt             = no

[dn]
CN = $LOCAL_IDENTITY

[ext]
basicConstraints     = critical,CA:FALSE
keyUsage             = critical,digitalSignature
extendedKeyUsage     = critical,codeSigning
subjectKeyIdentifier = hash
CNF

    # Homebrew's OpenSSL 3 writes PKCS#12 algorithms Security.framework rejects, so pin LibreSSL.
    /usr/bin/openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
        -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -config "$WORK/cert.cnf" 2>/dev/null

    # `security import` is unreliable with an empty PKCS#12 password, so use a throwaway one.
    local p12_password
    p12_password="$(uuidgen)"
    /usr/bin/openssl pkcs12 -export -out "$WORK/identity.p12" -inkey "$WORK/key.pem" \
        -in "$WORK/cert.pem" -name "$LOCAL_IDENTITY" -passout "pass:$p12_password"
    security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$p12_password" \
        -T /usr/bin/codesign -T /usr/bin/security

    # Lets codesign use the key without a keychain dialog on every install.
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -l "$LOCAL_IDENTITY" \
        "$KEYCHAIN" >/dev/null 2>&1 \
        || echo "  set-key-partition-list skipped; codesign may ask for the keychain once"

    # Trust for code signing in the user domain only.
    security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem" \
        || echo "  add-trusted-cert skipped; signing usually still works untrusted"
}

# `curl | bash` runs lines as they arrive, so every step lives in main: a download cut short never
# reaches the call and leaves the current install alone.
main() {
    local zip app bundle_id
    # Both paths install from the release zip, so CI's --build run covers the unzip a download goes
    # through.
    case "$*" in
        "")
            zip="$WORK/$APP_NAME.zip"
            curl -fsSL -o "$zip" "$RELEASE_URL"
            ;;
        --build)
            cd "$(dirname "$0")"
            app/build.sh
            zip="app/build/$APP_NAME.zip"
            ;;
        *)
            echo "usage: setup.sh [--build]" >&2
            exit 2
            ;;
    esac
    ditto -x -k "$zip" "$WORK"
    app="$WORK/$APP_NAME.app"

    if [ -z "${CODESIGN_IDENTITY:-}" ]; then
        CODESIGN_IDENTITY="$LOCAL_IDENTITY"
        # Without -v the list includes an identity whose trust step failed, so a rerun reuses it instead
        # of importing a second one that makes the name ambiguous to codesign. grep reads to EOF, so
        # security can't die of SIGPIPE and fail the pipeline.
        security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null \
            | grep -F "\"$LOCAL_IDENTITY\"" >/dev/null \
            || create_local_identity
    fi

    bundle_id="$(plutil -extract CFBundleIdentifier raw "$app/Contents/Info.plist")"
    xattr -cr "$app"
    codesign --force --options runtime --identifier "$bundle_id.helper" \
        --sign "$CODESIGN_IDENTITY" "$app/Contents/Helpers/MacLayoutHelper"
    codesign --force --options runtime --sign "$CODESIGN_IDENTITY" "$app"
    # Verifies before touching /Applications, so a bad signature leaves the current install running.
    codesign --verify --deep --strict "$app"

    pkill -f "$APP_NAME.app/Contents/MacOS/$APP_NAME" 2>/dev/null || true
    for _ in 1 2 3 4 5; do
        pgrep -f "$APP_NAME.app/Contents/MacOS/$APP_NAME" >/dev/null || break
        sleep 1
    done
    rm -rf "$INSTALLED_APP"
    cp -R "$app" /Applications/
    open "$INSTALLED_APP"
    echo "$APP_NAME is in the menu bar, signed by $CODESIGN_IDENTITY"
}

main "$@"
