#!/bin/bash
# Build Idlewild.app. No Xcode project - swiftc assembles the bundle directly,
# which keeps the whole build reproducible from a shell.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Idlewild.app"
CONTENTS="$APP/Contents"
IDENTITY="${CODESIGN_IDENTITY:--}"     # "-" = adhoc, for local runs

rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

echo "compiling..."
swiftc -O -swift-version 5 \
    -target arm64-apple-macos14.0 \
    -framework SwiftUI -framework AppKit -framework UserNotifications \
    -framework ServiceManagement \
    -o "$CONTENTS/MacOS/Idlewild" \
    App/IdlewildApp.swift \
    App/Engine/*.swift \
    App/UI/*.swift \
    App/Support/*.swift

cp App/Resources/Info.plist "$CONTENTS/Info.plist"
[ -f App/Resources/Idlewild.icns ] && cp App/Resources/Idlewild.icns "$CONTENTS/Resources/"

echo "signing (identity: $IDENTITY)..."
codesign --force --options runtime --timestamp \
    --entitlements App/Resources/Idlewild.entitlements \
    --sign "$IDENTITY" "$APP" 2>&1 | grep -v "^$" || true

codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | tail -2
echo "built: $APP"
