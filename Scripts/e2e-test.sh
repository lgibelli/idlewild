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
# time kept and 584-year wraps gone. And the machine as a whole: a spinner on
# every core is eight processes none of which is the problem, so it is the
# machine that has to be reported busy, with the spinner named as the reason.
# And when the swapping counts as heavy, decided on running totals made up for
# it: a test cannot make a Mac swap without hurting it.
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

/// The sustain window is -sustainMinutes on the command line, which
/// UserDefaults reads without anything being written.
func machineLoad(_ spinner: String) -> Bool {
    let settings = AppSettings()
    let d = Detector(settings: settings)
    let window = settings.sustainSeconds
    Thread.sleep(forTimeInterval: 0.1)
    _ = d.scan()
    let began = Date()
    let burners = (0..<HostCPU.cores).map { _ -> Process in
        let p = Process()
        p.executableURL = URL(fileURLWithPath: spinner)
        try! p.run()
        return p
    }
    defer { burners.forEach { kill($0.processIdentifier, SIGKILL) } }

    let named = { (l: MachineLoad?) in l?.top.first { $0.name == "idlewild_test_spinner" } }
    var early = false                        // called busy before a whole window was in
    var found: (load: MachineLoad, share: MachineLoad.Share, said: String, after: TimeInterval)?
    for _ in 0..<Int(window) + 15 {
        Thread.sleep(forTimeInterval: 1)
        _ = d.scan()
        let t = Date().timeIntervalSince(began)
        if d.load != nil, t < window - 0.5 { early = true }
        if let l = d.load, let s = named(l) { found = (l, s, l.summary, t); break }
    }
    guard let found else { print("  the machine was never reported busy"); return false }

    burners.forEach { kill($0.processIdentifier, SIGKILL) }
    let stopped = Date()
    var gone: TimeInterval?                  // the machine may well stay busy; the spinner may not
    for _ in 0..<Int(window) + 15 {
        Thread.sleep(forTimeInterval: 1)
        _ = d.scan()
        if named(d.load) == nil { gone = Date().timeIntervalSince(stopped); break }
    }
    print(String(format: "  %@, said after %.0f s; spinners %.1f cores; out of it %@",
                 found.said, found.after, found.share.cores,
                 gone.map { String(format: "%.0f s after they stopped", $0) } ?? "never"))
    let of = Double(found.load.of)
    return !early && found.load.cores >= of * Detector.busyAt && found.load.cores <= of * 1.05
        && found.share.cores >= of / 4 && gone != nil
}

/// Swap traffic at a steady rate, scanned every 30 s, half of it read back.
struct SwapSim {
    var w = SwapWatch()
    var t = 1000.0, moved = 0.0, read = 0.0
    init() { w.add(at: t, moved: 0, readBack: 0) }   // the first scan, which only learns the totals
    mutating func run(_ seconds: Double, mbps: Double) -> [Bool] {
        var seen: [Bool] = []
        for _ in 0..<Int(seconds / 30) {
            t += 30
            moved += mbps * 30 * 1_048_576
            read += mbps * 15 * 1_048_576
            seen.append(w.add(at: t, moved: UInt64(moved), readBack: UInt64(read)))
        }
        return seen
    }
}

func swapDecision() -> Bool {
    var ok = true
    func expect(_ c: Bool, _ what: String) { if !c { print("  wrong: " + what); ok = false } }

    var a = SwapSim()
    expect(!a.run(570, mbps: 20).contains(true), "heavy before a whole window was in")
    expect(a.run(30, mbps: 20) == [true], "not heavy after ten minutes at 20 MB/s")
    expect(a.w.since == 1000, "the episode does not start where the window did")
    expect(abs(a.w.rate / 1_048_576 - 20) < 0.01 && abs(a.w.readBack / 1_048_576 - 10) < 0.01,
           "the rates are not what was moved")
    expect(!a.run(300, mbps: 0).contains(false), "cleared while the average was still 10 MB/s")
    expect(a.run(300, mbps: 0).last == false, "still heavy after ten minutes of nothing")

    var b = SwapSim()                            // an app swapped out overnight, woken
    _ = b.run(30, mbps: 2048.0 / 30)             // 2 GB read back at once
    expect(!b.run(1200, mbps: 0.2).contains(true), "a single 2 GB restore was called heavy")

    var c = SwapSim()                            // sitting between the two thresholds
    expect(!c.run(1200, mbps: 3).contains(true), "3 MB/s was called heavy")
    _ = c.run(600, mbps: 8)
    expect(!c.run(1200, mbps: 3).contains(false), "3 MB/s ended an episode that started higher")

    var d = SwapSim()
    _ = d.run(600, mbps: 20)
    d.moved = 0; d.read = 0                      // the totals started again
    expect(d.run(30, mbps: 20) == [false], "a counter that went back was not a fresh start")

    print("  swap decision: " + (ok ? "as expected" : "wrong"))
    return ok
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
case "busy":  exit(machineLoad(a[2]) ? 0 : 1)
case "swap":  exit(swapDecision() ? 0 : 1)
default:      print("usage: engine-test exec SPINNER | wraps DIR | busy SPINNER | swap -"); exit(2)
}
SWIFT
swiftc -swift-version 5 -target arm64-apple-macos14.0 -o "$WORK/engine-test" \
    App/Engine/Detector.swift App/Engine/History.swift App/Engine/ProcessSampler.swift \
    App/Support/AppSettings.swift "$WORK/engine/main.swift" || exit 1
"$WORK/engine-test" exec "$WORK/idlewild_test_spinner"
check $? "a launched program's CPU is filed under its own name, not the launcher's"
"$WORK/engine-test" wraps "$WORK"
check $? "a stored history loses its wrapped readings and keeps the real time"
"$WORK/engine-test" busy "$WORK/idlewild_test_spinner" -sustainMinutes 0.1
check $? "a machine kept busy by many processes is reported busy, and the spinner named for it"
"$WORK/engine-test" swap -
check $? "heavy swapping is told from a one-off restore, and an episode ends only once it has eased"

echo
echo "--- watch output ---"; sed 's/^/  /' "$LOG" | head -30
echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
