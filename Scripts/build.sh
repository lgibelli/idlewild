#!/bin/bash
#
# SPDX-FileCopyrightText: 2026 Luca Gibelli
# SPDX-License-Identifier: GPL-3.0-or-later
#
# build.sh — build and sign Idlewild.app.
#
# Signs with the Developer ID Application identity for TEAM_ID when one is
# available (see release.env), otherwise falls back to adhoc for local work.
# There is no Xcode project: swiftc assembles the bundle directly, so the whole
# build is reproducible from a shell.
#
set -euo pipefail
source "$(dirname "$0")/build-common.sh"
cd "$PROJECT_ROOT"

APP="build/$APP_NAME.app"
CONTENTS="$APP/Contents"
IDENTITY="$(signing_identity)"

rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

say "Compiling"
swiftc -O -swift-version 5 \
    -target arm64-apple-macos14.0 \
    -framework SwiftUI -framework AppKit -framework UserNotifications \
    -framework ServiceManagement \
    -o "$CONTENTS/MacOS/$APP_NAME" \
    App/IdlewildApp.swift \
    App/Engine/*.swift \
    App/UI/*.swift \
    App/Support/*.swift

cp App/Resources/Info.plist "$CONTENTS/Info.plist"
[ -f "App/Resources/$APP_NAME.icns" ] && cp "App/Resources/$APP_NAME.icns" "$CONTENTS/Resources/"

say "Signing as: $IDENTITY"
codesign --force --options runtime --timestamp \
    --entitlements "App/Resources/$APP_NAME.entitlements" \
    --sign "$IDENTITY" "$APP"

codesign --verify --deep --strict "$APP"

# The designated requirement is what macOS uses as the app's identity for TCC
# and notification authorization. Adhoc yields a per-build cdhash, which cannot
# persist across rebuilds; a Developer ID signature yields a stable one.
REQ=$(codesign -d -r- "$APP" 2>&1 | grep "designated" || true)
if [ "$IDENTITY" = "-" ]; then
    printf "\n\033[1;33mNOTE:\033[0m adhoc signed — notification authorization will not persist.\n"
    echo "      $REQ"
    echo "      See docs/DEVELOPMENT.md"
else
    say "Designated requirement (stable across rebuilds)"
    echo "  $REQ"
fi

say "Built: $APP"
