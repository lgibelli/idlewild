#!/bin/bash
#
# SPDX-FileCopyrightText: 2026 Luca Gibelli
# SPDX-License-Identifier: GPL-3.0-or-later
#
# install-cli.sh — build the headless CLI and install it as a LaunchAgent.
#
# This is the no-UI option: no menu bar, no notifications, just a background
# watcher that logs runaway processes. Most people want the app instead.
#
set -euo pipefail
source "$(dirname "$0")/build-common.sh"
cd "$PROJECT_ROOT"

LABEL="$BUNDLE_ID"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
BIN="$PROJECT_ROOT/build/idlewild"

say "Building the CLI"
mkdir -p build
swiftc -O -swift-version 5 -o "$BIN" cli/main.swift

say "Verifying the cost budget"
"$BIN" selftest | tail -4

say "Installing the LaunchAgent"
mkdir -p "$HOME/Library/LaunchAgents"
# The committed plist carries __HOME__ placeholders rather than absolute paths,
# so the repository does not embed anyone's home directory.
sed -e "s|__HOME__|$HOME|g" \
    -e "s|__BIN__|$BIN|g" \
    "$LABEL.plist" > "$PLIST"

launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$UID" "$PLIST"

say "Installed"
echo "  log:       $HOME/Library/Logs/idlewild.log"
echo "  uninstall: launchctl bootout gui/$UID/$LABEL && rm $PLIST"
