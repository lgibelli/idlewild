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

# The app's own engine, which the CLI above does not share: where CPU History
# files time. A launcher that execs into a busy program must leave the time
# under the program (an iOS Simulator app once filed hours under xpcproxy_sim),
# and a stored history with wrapped readings in it must come back with the real
# time kept and 584-year wraps gone.
echo "checking the app's CPU accounting..."
# The burner shares the spinner's name; left running it would blur the figures.
kill -9 "$BURNER" "$GROWER" 2>/dev/null; BURNER=""; GROWER=""
mkdir -p "$WORK/engine"   # top-level code has to live in a main.swift
cat > "$WORK/engine/main.swift" <<'SWIFT'
import Foundation
import os
let log = Logger(subsystem: "idlewild-engine-test", category: "test")

func execNaming(_ spinner: String) -> Bool {
    let d = Detector(settings: AppSettings())
    Thread.sleep(forTimeInterval: 0.1)       // a scan under 50 ms after the last is ignored
    _ = d.scan()                             // learns where every counter stands
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
    p.arguments = ["-e", "select(undef,undef,undef,0.4); exec \"\(spinner)\""]
    try! p.run()
    defer { kill(p.processIdentifier, SIGKILL) }
    Thread.sleep(forTimeInterval: 0.1)
    _ = d.scan()                             // first sight, while it is still perl
    let early = d.takeUsage().seconds
    Thread.sleep(forTimeInterval: 1.5)       // it has exec'd and burned about a second
    _ = d.scan()
    let later = d.takeUsage().seconds
    let spun = later["idlewild_test_spinner"] ?? 0, perl = later["perl"] ?? 0
    print(String(format: "  launcher seen: %@; then spinner %.2f s, perl %.3f s",
                 early["perl"] != nil ? "yes" : "no", spun, perl))
    return early["perl"] != nil && spun > 0.5 && perl < 0.1
}

struct Stored: Codable { var version = 1; var fine: [Slice]; var coarse: [Slice]; var open: Slice? }

func wraps(_ dir: String) -> Bool {
    let w = Slice.wrap
    var s = Slice(start: 0)
    s.apps = ["three": 3 * w + 12.5, "stepback": w - 0.0005, "honest": 100]
    s.other = w + 2
    var ok = s.removeWraps() == 3 && abs(s.apps["three"]! - 12.5) < 0.001
        && s.apps["stepback"] == nil && s.apps["honest"] == 100 && abs(s.other - 2) < 0.001
        && s.removeWraps() == 0
    let now = Date().timeIntervalSince1970
    var hour = Slice(start: (now / 3600).rounded(.down) * 3600)
    hour.seen = 300; hour.busy = 600; hour.apps = ["xpcproxy_sim": w + 22.4, "OneDrive": 30]
    var five = hour; five.start = (now / 300).rounded(.down) * 300 - 300
    let url = URL(fileURLWithPath: dir).appendingPathComponent("history.plist")
    try! PropertyListEncoder().encode(Stored(fine: [five], coarse: [hour], open: nil)).write(to: url)
    let loaded = CPUHistory(url: url).snapshot()
    let all = loaded.fine + loaded.coarse
    ok = ok && all.count == 2 && all.allSatisfy {
        abs(($0.apps["xpcproxy_sim"] ?? 0) - 22.4) < 0.001 && $0.apps["OneDrive"] == 30
    }
    let saved = try! PropertyListDecoder().decode(Stored.self, from: Data(contentsOf: url))
    return ok && (saved.fine + saved.coarse).allSatisfy { $0.apps.values.allSatisfy { $0 < w / 2 } }
}

let a = CommandLine.arguments
switch a.count > 2 ? a[1] : "" {
case "exec":  exit(execNaming(a[2]) ? 0 : 1)
case "wraps": exit(wraps(a[2]) ? 0 : 1)
default:      print("usage: engine-test exec SPINNER | wraps DIR"); exit(2)
}
SWIFT
swiftc -swift-version 5 -target arm64-apple-macos14.0 -o "$WORK/engine-test" \
    App/Engine/Detector.swift App/Engine/History.swift App/Engine/ProcessSampler.swift \
    App/Support/AppSettings.swift "$WORK/engine/main.swift" || exit 1
"$WORK/engine-test" exec "$WORK/idlewild_test_spinner"
check $? "a launched program's CPU is filed under its own name, not the launcher's"
"$WORK/engine-test" wraps "$WORK"
check $? "a stored history loses its wrapped readings and keeps the real time"

echo
echo "--- watch output ---"; sed 's/^/  /' "$LOG" | head -30
echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
