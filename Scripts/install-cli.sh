#!/bin/bash
# Install idlewild as a LaunchAgent.
set -euo pipefail
cd "$(dirname "$0")"

LABEL=it.salamacchine.idlewild
PLIST=~/Library/LaunchAgents/$LABEL.plist

echo "building..."
swiftc -O -swift-version 5 -o idlewild Sources/main.swift

echo "verifying cost budget..."
./idlewild selftest | tail -3

mkdir -p ~/Library/LaunchAgents
cp "$LABEL.plist" "$PLIST"

launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$UID" "$PLIST"
echo "installed. log: ~/Library/Logs/idlewild.log"
echo "uninstall:  launchctl bootout gui/$UID/$LABEL && rm $PLIST"
