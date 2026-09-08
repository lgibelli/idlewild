#!/bin/bash
#
# SPDX-FileCopyrightText: 2026 Luca Gibelli
# SPDX-License-Identifier: GPL-3.0-or-later
# End-to-end test against processes we control, rather than whatever happens to
# be misbehaving on the machine. Spawns a deliberate CPU burner and a deliberate
# memory grower, asserts that Idlewild finds each for the right reason, and
# leaves everything else alone.
set -uo pipefail
cd "$(dirname "$0")/.."

WORK=$(mktemp -d)
BURNER=""
GROWER=""
cleanup() {
    [ -n "$BURNER" ] && kill -9 "$BURNER" 2>/dev/null
    [ -n "$GROWER" ] && kill -9 "$GROWER" 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT

pass=0; fail=0
check() { if [ "$1" = "0" ]; then echo "  PASS  $2"; pass=$((pass+1)); else echo "  FAIL  $2"; fail=$((fail+1)); fi; }

echo "building cli..."
swiftc -O -swift-version 5 -o "$WORK/idlewild-cli" cli/main.swift || exit 1

# A named, identifiable spinner so we can assert on it precisely.
cat > "$WORK/spinner.swift" <<'SWIFT'
var x = 0.0
while true { x += 1.0; if x > 1e18 { x = 0 } }
SWIFT
swiftc -O -o "$WORK/idlewild_test_spinner" "$WORK/spinner.swift" || exit 1

# A grower that leaks like a real leak: steadily, touching every page so it
# counts in the physical footprint, and at almost no CPU so the two alarms
# cannot be confused. It stops at 1 GB and holds, so a hung test cannot take
# the machine down with it. 16 MB/s fills any Mac within the fit's horizon
# while leaving the fit a minute of straight line to look at.
cat > "$WORK/grower.swift" <<'SWIFT'
import Foundation
let chunk = 8 << 20
var kept: [UnsafeMutableRawPointer] = []
while kept.count * chunk < (1 << 30) {
    let p = UnsafeMutableRawPointer.allocate(byteCount: chunk, alignment: 16384)
    memset(p, 1, chunk)
    kept.append(p)
    Thread.sleep(forTimeInterval: 0.5)       // 16 MB/s
}
while true { Thread.sleep(forTimeInterval: 60) }
SWIFT
swiftc -O -o "$WORK/idlewild_test_grower" "$WORK/grower.swift" || exit 1

echo "starting burner and grower..."
"$WORK/idlewild_test_spinner" & BURNER=$!
"$WORK/idlewild_test_grower" & GROWER=$!
sleep 3
ps -p $BURNER >/dev/null; check $? "burner is running (pid $BURNER)"
ps -p $GROWER >/dev/null; check $? "grower is running (pid $GROWER)"

echo "watching (threshold 70%, sustain 12s, memory 1% of RAM, scan every 4s)..."
LOG="$WORK/watch.log"
"$WORK/idlewild-cli" watch --threshold 70 --sustain 0.2 --interval 4 \
    --memory-share 1 --memory-sustain 0.4 > "$LOG" 2>&1 &
WATCH=$!
for _ in $(seq 1 40); do
    grep -q "pid $BURNER" "$LOG" && grep -q "pid $GROWER" "$LOG" && break
    sleep 2
done
kill $WATCH 2>/dev/null

grep -q "RUNAWAY" "$LOG"; check $? "detected a runaway process"
grep -q "idlewild_test_spinner" "$LOG"; check $? "found our burner specifically"
grep -q "idlewild_test_spinner" "$LOG"; check $? "identified the burner by name"
grep -q "pid $BURNER" "$LOG"; check $? "reported the correct pid"
grep -qE "likely cause:" "$LOG"; check $? "produced a cause"

# It must not accuse things that are merely present.
DUPES=$(grep -c "pid $BURNER" "$LOG")
[ "$DUPES" -eq 1 ] && check 0 "alerted exactly once for the burner" || check 1 "alerted $DUPES times for one process"

grep -q "MEMORY HOG" "$LOG"; check $? "detected a memory hog"
grep -q "idlewild_test_grower" "$LOG"; check $? "found our grower specifically"
grep -q "pid $GROWER" "$LOG"; check $? "reported the grower's pid"
grep -A2 "pid $GROWER" "$LOG" | grep -q "growing"; check $? "reported the grower as growing"
grep -A3 "pid $GROWER" "$LOG" | grep -q "leak"; check $? "called it a leak"
grep -A3 "pid $GROWER" "$LOG" | grep -q "fills memory in"; check $? "projected when it fills memory"
GDUPES=$(grep -c "pid $GROWER" "$LOG")
[ "$GDUPES" -eq 1 ] && check 0 "alerted exactly once for the grower" || check 1 "alerted $GDUPES times for the grower"
# The two alarms must not cross: the burner barely allocates and the grower
# barely computes.
grep -B1 "pid $BURNER" "$LOG" | grep -q "MEMORY HOG" && check 1 "burner was reported as a memory hog" || check 0 "burner was not reported as a memory hog"
grep -B1 "pid $GROWER" "$LOG" | grep -q "RUNAWAY" && check 1 "grower was reported as a CPU runaway" || check 0 "grower was not reported as a CPU runaway"

echo
echo "--- watch output ---"; sed 's/^/  /' "$LOG" | head -30
echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
