#!/bin/bash
# Builds app/build/MacLayoutManager.app: a size-optimized Objective-C host that stays running and a
# Swift helper it spawns per command. Runs both test suites before signing.
set -euo pipefail

APP_NAME="MacLayoutManager"
BUNDLE_ID="com.choandrew.MacLayoutManager"
APP_PATH="build/$APP_NAME.app"
EXECUTABLE="$APP_PATH/Contents/MacOS/$APP_NAME"
HELPER="$APP_PATH/Contents/Helpers/MacLayoutHelper"
LOCAL_SIGNING_IDENTITY="MacLayoutManager Dev"
PROTOCOL_FIXTURE="tests/protocol-output.txt"

# Tests compile with the release target and warnings, so a warning can't hide in either build.
CLANG_FLAGS=(-arch arm64 -mmacosx-version-min=15.0 -fobjc-arc -Oz -Wall -Wextra -Werror)
# The header is plain C, so importing it shares the protocol limits and verbs at no runtime cost.
SWIFT_FLAGS=(-swift-version 6 -parse-as-library -target arm64-apple-macos15.0 -warnings-as-errors
    -import-objc-header HelperProtocol.h)
CORE_SOURCES=(HelperProtocol.swift Layout.swift LayoutLibrary.swift Placement.swift)

# A stable identity keeps the Accessibility grant across rebuilds; an ad-hoc signature is a new app
# to macOS every time.
if [ -z "${CODESIGN_IDENTITY+x}" ]; then
    case "$(security find-identity -v -p codesigning 2>/dev/null || true)" in
        *\"$LOCAL_SIGNING_IDENTITY\"*) CODESIGN_IDENTITY="$LOCAL_SIGNING_IDENTITY" ;;
        *) CODESIGN_IDENTITY="-" ;;
    esac
fi

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

xattr -cr "$APP_PATH"
codesign --force --options runtime --identifier "$BUNDLE_ID.helper" \
    --sign "$CODESIGN_IDENTITY" "$HELPER"
codesign --force --options runtime --sign "$CODESIGN_IDENTITY" "$APP_PATH"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

echo "Built $APP_PATH for Apple silicon, signed by $CODESIGN_IDENTITY"
