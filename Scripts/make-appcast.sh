#!/bin/bash
#
# SPDX-FileCopyrightText: 2026 Luca Gibelli
# SPDX-License-Identifier: GPL-3.0-or-later
#
# make-appcast.sh — turn a built disk image into the appcast Sparkle reads.
#
# Every item in the appcast carries the Ed25519 signature of its archive, made
# with the private key. That signature is the whole security model: an attacker
# who takes over the web server can serve a different feed, but Sparkle will
# refuse anything in it that does not verify against the public key baked into
# the app, and will refuse any app not signed by our team on top of that.
#
# The private key is read from the login keychain, or from
# $SPARKLE_PRIVATE_KEY_FILE when there is no keychain to read (CI).
#
# Usage:
#   ./Scripts/make-appcast.sh [path/to/Idlewild-X.Y.Z.dmg]
#
set -euo pipefail
source "$(dirname "$0")/build-common.sh"
cd "$PROJECT_ROOT"

REPO_URL="https://github.com/lgibelli/idlewild"
SITE_URL="https://www.salamacchine.it/apps/idlewild/"

SPARKLE="$(fetch_sparkle)"

DMG="${1:-}"
if [ -z "$DMG" ]; then
  V=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" App/Resources/Info.plist)
  DMG="build/$APP_NAME-$V.dmg"
fi
[ -f "$DMG" ] || die "no disk image at $DMG — run ./Scripts/make-dmg.sh first"

VERSION="$(basename "$DMG" .dmg)"
VERSION="${VERSION#"$APP_NAME"-}"

STAGE="build/appcast"

say "Staging $DMG as $APP_NAME-$VERSION.dmg"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp "$DMG" "$STAGE/$APP_NAME-$VERSION.dmg"

# The update alert shows release notes, and there is exactly one place where
# they are written: docs/RELEASE-NOTES.md. Take this version's section from it.
NOTES="$STAGE/$APP_NAME-$VERSION.md"
awk -v want="# Idlewild $VERSION" '
  $0 == want { inside = 1; next }
  inside && /^# / { exit }
  inside { print }
' docs/RELEASE-NOTES.md > "$NOTES"
if [ ! -s "$NOTES" ]; then
  rm -f "$NOTES"
  echo "   (no section for $VERSION in docs/RELEASE-NOTES.md; shipping without notes)"
fi

KEY_ARGS=()
if [ -n "${SPARKLE_PRIVATE_KEY_FILE:-}" ]; then
  KEY_ARGS=(--ed-key-file "$SPARKLE_PRIVATE_KEY_FILE")
fi

say "Generating and signing the appcast"
"$SPARKLE/bin/generate_appcast" \
  --download-url-prefix "$REPO_URL/releases/download/v$VERSION/" \
  --link "$SITE_URL" \
  --embed-release-notes \
  --maximum-deltas 0 \
  -o "$STAGE/appcast.xml" \
  "${KEY_ARGS[@]+"${KEY_ARGS[@]}"}" \
  "$STAGE"

say "Appcast written to $STAGE/appcast.xml"
echo "   Publish it at https://www.salamacchine.it/apps/idlewild/appcast.xml"
echo "   (copy it into www/public/apps/idlewild/ in the site repository and deploy)"
