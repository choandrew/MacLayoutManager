#!/bin/bash
# Builds build/MacLayoutManager.app from the SwiftPM release binary.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
app=build/MacLayoutManager.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp "$(swift build -c release --show-bin-path)/MacLayoutManager" "$app/Contents/MacOS/"
codesign --force --sign - "$app"
echo "$app"
