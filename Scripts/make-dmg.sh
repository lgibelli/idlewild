#!/bin/bash
#
# make-dmg.sh — package the notarized app into a distributable DMG.
#
# Run after Scripts/notarize.sh. The DMG is signed and notarized in its own
# right: Gatekeeper assesses the container as well as the app inside it, so a
# bare DMG around a notarized app still warns on first open.
#
set -euo pipefail
source "$(dirname "$0")/build-common.sh"
cd "$PROJECT_ROOT"

APP="build/$APP_NAME.app"
[ -d "$APP" ] || die "build first: ./Scripts/build.sh"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
DMG="build/$APP_NAME-$VERSION.dmg"
STAGE="build/dmg"
IDENTITY="$(signing_identity)"

say "Staging"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"     # the familiar drag-to-install layout

say "Creating $DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null

# Unregister the staged copy before deleting it. LaunchServices indexes any app
# bundle it sees, and a registration pointing at a deleted path makes usernoted
# fail to resolve the bundle (_LSBundleCreateNode ... returned -43), which can
# stop the app appearing in System Settings > Notifications at all.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
[ -x "$LSREGISTER" ] && "$LSREGISTER" -u "$STAGE/$APP_NAME.app" 2>/dev/null || true
rm -rf "$STAGE"

if [ "$IDENTITY" != "-" ]; then
    say "Signing the DMG"
    codesign --force --sign "$IDENTITY" --timestamp "$DMG"

    if [ -n "$NOTARY_PROFILE" ]; then
        say "Notarizing the DMG"
        xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait --timeout 20m
        xcrun stapler staple "$DMG"
        xcrun stapler validate "$DMG"
    fi
else
    printf "\n\033[1;33mNOTE:\033[0m adhoc build — DMG is unsigned and will warn on other Macs.\n"
fi

say "Done"
ls -lh "$DMG"
