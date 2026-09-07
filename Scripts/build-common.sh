#!/bin/bash
#
# build-common.sh — shared configuration and helpers for the Idlewild build
# and release scripts. Source this file, don't run it.
#
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Idlewild"
BUNDLE_ID="it.salamacchine.idlewild"

# Account-specific values live in a local, gitignored release.env so the repo
# carries no account identifiers. Copy release.env.example and fill it in.
[ -f "$PROJECT_ROOT/release.env" ] && source "$PROJECT_ROOT/release.env"
TEAM_ID="${TEAM_ID:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"

say() { printf "\n\033[1;34m==>\033[0m %s\n" "$*"; }
die() { printf "\n\033[1;31mERROR:\033[0m %s\n" "$*" >&2; exit 1; }

require_team_id() {
  [ -n "$TEAM_ID" ] || die "TEAM_ID is not set.
       Export it, or copy release.env.example to release.env and fill it in."
}

require_notary_profile() {
  [ -n "$NOTARY_PROFILE" ] || die "NOTARY_PROFILE is not set.
       Export it, or set it in release.env."
  xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" \
      --output-format json >/dev/null 2>&1 || \
    die "notarytool keychain profile '$NOTARY_PROFILE' is missing or invalid.
       Create one with:
         xcrun notarytool store-credentials '$NOTARY_PROFILE' \\
           --apple-id 'you@example.com' --team-id '$TEAM_ID' \\
           --password '<app-specific-password>'"
}

# Resolves the Developer ID Application identity for TEAM_ID, falling back to
# adhoc ("-") for local development builds.
#
# Note that an adhoc signature makes the designated requirement a cdhash of the
# binary, so every rebuild looks like a different app to macOS and notification
# authorization can never persist. See docs/DEVELOPMENT.md.
signing_identity() {
  if [ -n "${CODESIGN_IDENTITY:-}" ]; then echo "$CODESIGN_IDENTITY"; return; fi
  if [ -n "$TEAM_ID" ]; then
    local found
    found=$(security find-identity -v -p codesigning 2>/dev/null \
            | grep "Developer ID Application: .*($TEAM_ID)" \
            | head -1 | sed 's/.*"\(.*\)"/\1/')
    if [ -n "$found" ]; then echo "$found"; return; fi
  fi
  echo "-"
}
