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
SPARKLE="$(fetch_sparkle)"

rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources" "$CONTENTS/Frameworks"

say "Compiling"
swiftc -O -swift-version 5 \
    -target arm64-apple-macos14.0 \
    -F "$SPARKLE" -framework Sparkle \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    -framework SwiftUI -framework AppKit -framework UserNotifications \
    -framework ServiceManagement \
    -o "$CONTENTS/MacOS/$APP_NAME" \
    App/IdlewildApp.swift \
    App/Engine/*.swift \
    App/UI/*.swift \
    App/Support/*.swift

cp App/Resources/Info.plist "$CONTENTS/Info.plist"
[ -f "App/Resources/$APP_NAME.icns" ] && cp "App/Resources/$APP_NAME.icns" "$CONTENTS/Resources/"

# ditto, not cp -R: Sparkle.framework is a versioned bundle whose symlinks have
# to survive the copy, or the loader will not find it.
ditto "$SPARKLE/Sparkle.framework" "$CONTENTS/Frameworks/Sparkle.framework"

ENTITLEMENTS="App/Resources/$APP_NAME.entitlements"
if [ "$IDENTITY" = "-" ]; then
    # Library validation is part of the hardened runtime and refuses to load a
    # framework signed by anybody else. With a Developer ID signature that is
    # exactly what we want; with an adhoc one there is no team to compare, so
    # Sparkle would never load. Development builds drop it.
    ENTITLEMENTS="$(mktemp -t idlewild-adhoc-entitlements)"
    cat > "$ENTITLEMENTS" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.cs.disable-library-validation</key>
    <true/>
</dict>
</plist>
PLIST
fi

say "Signing as: $IDENTITY"
sign_sparkle_framework "$CONTENTS/Frameworks/Sparkle.framework" "$IDENTITY"
codesign --force --options runtime --timestamp \
    --entitlements "$ENTITLEMENTS" \
    --sign "$IDENTITY" "$APP"

if [ "$IDENTITY" = "-" ]; then
    rm -f "$ENTITLEMENTS"
fi

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
