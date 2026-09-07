#!/bin/bash
# End-to-end test against a process we control, rather than whatever happens to
# be misbehaving on the machine. Spawns a deliberate CPU burner, asserts that
# Idlewild finds it, classifies it, and leaves everything else alone.
set -uo pipefail
cd "$(dirname "$0")/.."

WORK=$(mktemp -d)
BURNER=""
cleanup() { [ -n "$BURNER" ] && kill -9 "$BURNER" 2>/dev/null; rm -rf "$WORK"; }
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

echo "starting burner..."
"$WORK/idlewild_test_spinner" & BURNER=$!
sleep 3
ps -p $BURNER >/dev/null; check $? "burner is running (pid $BURNER)"

echo "watching (threshold 70%, sustain 12s, scan every 4s)..."
LOG="$WORK/watch.log"
"$WORK/idlewild-cli" watch --threshold 70 --sustain 0.2 --interval 4 > "$LOG" 2>&1 &
WATCH=$!
for _ in $(seq 1 25); do grep -q "pid $BURNER" "$LOG" && break; sleep 2; done
kill $WATCH 2>/dev/null

grep -q "RUNAWAY" "$LOG"; check $? "detected a runaway process"
grep -q "idlewild_test_spinner" "$LOG"; check $? "found our burner specifically"
grep -q "idlewild_test_spinner" "$LOG"; check $? "identified the burner by name"
grep -q "pid $BURNER" "$LOG"; check $? "reported the correct pid"
grep -qE "likely cause:" "$LOG"; check $? "produced a cause"

# It must not accuse things that are merely present.
DUPES=$(grep -c "pid $BURNER" "$LOG")
[ "$DUPES" -eq 1 ] && check 0 "alerted exactly once for the burner" || check 1 "alerted $DUPES times for one process"

echo
echo "--- watch output ---"; sed 's/^/  /' "$LOG" | head -20
echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
