#!/bin/bash
#
# notarize.sh — build, sign, notarize, staple and verify Idlewild for
# Developer ID distribution (outside the Mac App Store).
#
# Idlewild cannot ship on the Mac App Store: under the App Sandbox,
# proc_listpids, proc_pid_rusage and kill() all return EPERM, so it can neither
# find, measure, nor stop a runaway process. See docs/APP-STORE.md, and
# reproduce with Scripts/sandbox-probe.sh.
#
# Prereqs (one-time):
#   1. Developer ID Application certificate in the login keychain.
#   2. TEAM_ID set, plus either NOTARY_PROFILE (a notarytool keychain profile)
#      or APPLE_API_KEY_PATH / APPLE_API_KEY_ID / APPLE_API_ISSUER for CI.
#      See release.env.example.
#
# Usage:
#   ./Scripts/notarize.sh
#
set -euo pipefail
source "$(dirname "$0")/build-common.sh"
cd "$PROJECT_ROOT"

require_team_id
require_notary_credentials

IDENTITY="$(signing_identity)"
[ "$IDENTITY" != "-" ] || die "No Developer ID Application identity for team $TEAM_ID.
       Notarization requires a real certificate; adhoc will not do."

APP="build/$APP_NAME.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" App/Resources/Info.plist)
ZIP="build/$APP_NAME-$VERSION.zip"

say "1/5  Build and sign"
./Scripts/build.sh

# Notarization is rejected outright without the hardened runtime flag.
#
# Capture first rather than piping into `grep -q`: under `set -o pipefail`,
# grep -q exits on first match, codesign takes SIGPIPE, and the pipeline reports
# failure exactly when the check succeeds.
CS_FLAGS=$(codesign -d --verbose=2 "$APP" 2>&1 | grep -o 'flags=0x[0-9a-f]*([^)]*)' || true)
case "$CS_FLAGS" in
    *runtime*) say "Hardened runtime confirmed: $CS_FLAGS" ;;
    *) die "hardened runtime missing (got '${CS_FLAGS:-none}') — check codesign --options runtime" ;;
esac

say "2/5  Zip for submission"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

say "3/5  Submit to Apple (typically 1-5 minutes)"
notary_submit "$ZIP"

say "4/5  Staple the ticket"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

say "5/5  Gatekeeper assessment (what a user's Mac will actually do)"
spctl -a -vvv -t execute "$APP" 2>&1 | head -4

# Re-zip so the distributed archive carries the stapled ticket.
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

printf "\n\033[1;32mDONE\033[0m\n"
echo "   Stapled app: $APP"
echo "   Zip:         $ZIP"
echo "   Next:        ./Scripts/make-dmg.sh"
