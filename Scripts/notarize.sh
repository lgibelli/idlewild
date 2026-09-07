#!/bin/bash
# Sign, notarize and staple Idlewild for distribution outside the App Store.
#
# Prerequisites (one time):
#   1. Apple Developer Program membership.
#   2. A "Developer ID Application" certificate in your login keychain.
#        security find-identity -v -p codesigning
#   3. An app-specific password stored as a notarytool profile:
#        xcrun notarytool store-credentials idlewild-notary \
#            --apple-id you@example.com --team-id TEAMID --password APP-SPECIFIC-PW
#
# Usage:
#   CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
#   NOTARY_PROFILE=idlewild-notary ./Scripts/notarize.sh
set -euo pipefail
cd "$(dirname "$0")/.."

: "${CODESIGN_IDENTITY:?set CODESIGN_IDENTITY to your Developer ID Application identity}"
: "${NOTARY_PROFILE:=idlewild-notary}"

APP="build/Idlewild.app"
ZIP="build/Idlewild.zip"

./Scripts/build.sh

echo "==> verifying hardened runtime"
codesign -d --entitlements - "$APP" 2>/dev/null | head -20
codesign -dv --verbose=4 "$APP" 2>&1 | grep -E "Authority|flags" || true
# Notarization is rejected without the runtime flag.
codesign -dv "$APP" 2>&1 | grep -q "flags=.*runtime" \
    || { echo "ERROR: hardened runtime missing"; exit 1; }

echo "==> submitting to Apple"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait

echo "==> stapling"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

echo "==> gatekeeper assessment (what a user's Mac will do)"
spctl -a -vvv -t install "$APP"

echo "notarized: $APP"
