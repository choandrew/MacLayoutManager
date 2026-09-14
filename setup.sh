#!/bin/bash
# Builds MacLayoutManager, replaces the copy in /Applications, and launches it. Re-running updates
# the install; layouts live in ~/Library/Application Support/MacLayoutManager, outside the bundle.
set -euo pipefail

APP_NAME="MacLayoutManager"
INSTALLED_APP="/Applications/$APP_NAME.app"
cd "$(dirname "$0")"

xcode-select --print-path >/dev/null 2>&1 \
    || { echo "Xcode command line tools missing: run xcode-select --install" >&2; exit 1; }
app/make_signing_cert.sh
app/build.sh

pkill -f "$APP_NAME.app/Contents/MacOS/$APP_NAME" 2>/dev/null || true
for _ in 1 2 3 4 5; do
    pgrep -f "$APP_NAME.app/Contents/MacOS/$APP_NAME" >/dev/null || break
    sleep 1
done
rm -rf "$INSTALLED_APP"
cp -R "app/build/$APP_NAME.app" /Applications/
codesign --verify --deep --strict "$INSTALLED_APP"
open "$INSTALLED_APP"
echo "$APP_NAME is in the menu bar"
