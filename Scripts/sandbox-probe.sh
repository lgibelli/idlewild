#!/bin/bash
#
# SPDX-FileCopyrightText: 2026 Luca Gibelli
# SPDX-License-Identifier: GPL-3.0-or-later
# Reproduces the App Sandbox findings in docs/APP-STORE.md.
# Builds one probe binary and runs it twice: unsandboxed, then inside a real
# signed .app bundle carrying the sandbox entitlement.
set -euo pipefail
TARGET="${1:-1}"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/probe.swift" <<'EOF'
import Foundation
import Darwin
var buf = [pid_t](repeating: 0, count: 4096)
let bytes = buf.withUnsafeMutableBufferPointer {
    proc_listpids(UInt32(PROC_ALL_PIDS), 0, $0.baseAddress, Int32($0.count * MemoryLayout<pid_t>.size))
}
let n = bytes > 0 ? Int(bytes)/MemoryLayout<pid_t>.size : 0
print("  proc_listpids   : \(n > 0 ? "OK (\(n) pids)" : "BLOCKED errno \(errno)")")
let target = Int32(CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "1") ?? 1
var info = rusage_info_v4()
let rc = withUnsafeMutablePointer(to: &info) { p in p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(target, RUSAGE_INFO_V4, $0) } }
print("  proc_pid_rusage : \(rc == 0 ? "OK" : "BLOCKED errno \(errno)")")
var pb = [CChar](repeating: 0, count: 4096)
print("  proc_pidpath    : \(proc_pidpath(target, &pb, UInt32(pb.count)) > 0 ? "OK" : "BLOCKED errno \(errno)")")
print("  kill(pid, 0)    : \(kill(target, 0) == 0 ? "OK" : "BLOCKED errno \(errno)")")
EOF

swiftc -O -o "$WORK/probe" "$WORK/probe.swift"
echo "=== UNSANDBOXED (Developer ID model) ==="
"$WORK/probe" "$TARGET"

mkdir -p "$WORK/P.app/Contents/MacOS"
cat > "$WORK/P.app/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>P</string>
<key>CFBundleIdentifier</key><string>it.salamacchine.sandboxprobe</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
EOF
cat > "$WORK/sb.entitlements" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>com.apple.security.app-sandbox</key><true/>
</dict></plist>
EOF
cp "$WORK/probe" "$WORK/P.app/Contents/MacOS/P"
codesign -f -s - --entitlements "$WORK/sb.entitlements" "$WORK/P.app" 2>/dev/null
echo
echo "=== SANDBOXED (Mac App Store conditions) ==="
"$WORK/P.app/Contents/MacOS/P" "$TARGET"
