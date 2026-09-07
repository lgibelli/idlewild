#!/bin/bash
# Package the notarized app into a distributable DMG.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Idlewild.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
DMG="build/Idlewild-$VERSION.dmg"
STAGE="build/dmg"

[ -d "$APP" ] || { echo "build first: ./Scripts/build.sh"; exit 1; }

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"     # the familiar drag-to-install layout

hdiutil create -volname "Idlewild" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"

# The DMG itself should be signed and stapled too, or Gatekeeper warns on the
# container even when the app inside is fine.
if [ -n "${CODESIGN_IDENTITY:-}" ] && [ "${CODESIGN_IDENTITY}" != "-" ]; then
    codesign --force --sign "$CODESIGN_IDENTITY" --timestamp "$DMG"
    if [ -n "${NOTARY_PROFILE:-}" ]; then
        xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
        xcrun stapler staple "$DMG"
    fi
fi

echo "packaged: $DMG"
ls -lh "$DMG"
