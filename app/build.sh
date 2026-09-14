#!/bin/bash
# Builds app/build/MacLayoutManager.app: a size-optimized Objective-C host that stays running and a
# Swift helper it spawns per command. Runs both test suites first. The bundle stays unsigned: setup.sh
# signs it at install with the identity that holds the Accessibility grant. app/build/MacLayoutManager.zip
# holds the bundle as a release publishes it.
set -euo pipefail

APP_NAME="MacLayoutManager"
APP_PATH="build/$APP_NAME.app"
ZIP_PATH="build/$APP_NAME.zip"
EXECUTABLE="$APP_PATH/Contents/MacOS/$APP_NAME"
HELPER="$APP_PATH/Contents/Helpers/MacLayoutHelper"
PROTOCOL_FIXTURE="tests/protocol-output.txt"

# Tests compile with the release target and warnings, so a warning can't hide in either build.
CLANG_FLAGS=(-arch arm64 -mmacosx-version-min=15.0 -fobjc-arc -Oz -Wall -Wextra -Werror)
# The header is plain C, so importing it shares the protocol limits and verbs at no runtime cost.
SWIFT_FLAGS=(-swift-version 6 -parse-as-library -target arm64-apple-macos15.0 -warnings-as-errors
    -import-objc-header HelperProtocol.h)
CORE_SOURCES=(HelperProtocol.swift Layout.swift LayoutLibrary.swift Placement.swift)

cd "$(dirname "$0")"
rm -rf build
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Helpers" build/tests

xcrun swiftc "${SWIFT_FLAGS[@]}" -o build/tests/LayoutCoreTests \
    tests/LayoutCoreTests.swift "${CORE_SOURCES[@]}"
build/tests/LayoutCoreTests "$PROTOCOL_FIXTURE"

xcrun clang "${CLANG_FLAGS[@]}" -o build/tests/ProtocolTests tests/ProtocolTests.m HelperProtocol.m
build/tests/ProtocolTests "$PROTOCOL_FIXTURE"

xcrun clang "${CLANG_FLAGS[@]}" \
    -flto \
    -fvisibility=hidden \
    -framework AppKit \
    -framework ApplicationServices \
    -Wl,-dead_strip \
    -Wl,-x \
    -o "$EXECUTABLE" \
    MacLayoutManager.m \
    HelperProtocol.m

xcrun swiftc "${SWIFT_FLAGS[@]}" \
    -Osize \
    -whole-module-optimization \
    -lto=llvm-full \
    -Xfrontend -disable-reflection-metadata \
    -Xfrontend -disable-reflection-names \
    -Xlinker -dead_strip \
    -Xlinker -x \
    -o "$HELPER" \
    HelperMain.swift \
    AccessibilityWindows.swift \
    "${CORE_SOURCES[@]}"

cp Info.plist "$APP_PATH/Contents/Info.plist"
printf 'APPL????' > "$APP_PATH/Contents/PkgInfo"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

echo "Built $APP_PATH and $ZIP_PATH for Apple silicon"
