import Foundation
import Darwin

// ============================================================================
// idlewild - runaway process detector
//
// Design constraint: this must never become the thing it hunts.
// Budget: < 1 second of CPU time per hour (~0.03% of one core).
//
// How the budget is met:
//   1. The hot loop touches ONLY proc_pid_rusage() - one syscall per pid, no
//      string formatting, no fork/exec. Names and paths are resolved lazily,
//      for suspects only, and cached.
//   2. Timers carry large leeway so the kernel coalesces our wakeups with
//      others instead of pulling the SoC out of deep idle on its own.
//   3. The scan interval is adaptive: it backs off to 2 min when the machine
//      is calm and tightens to 10 s only while a suspect is building.
//   4. The expensive part (sample(1)) runs once per incident, never on a timer.
// ============================================================================

// MARK: - Tunables

struct Config {
    var cpuThreshold  = 80.0    // percent of ONE core
    var sustainSecs   = 300.0   // must hold above threshold this long
    var calmInterval  = 120.0   // scan period when nothing is brewing
    var busyInterval  = 10.0    // scan period while a suspect is building
    var leewayFrac    = 0.25    // timer slack, as a fraction of the interval

    // Processes that are *supposed* to peg a core. Matched against exec path.
    var allowList = [
        "ffmpeg", "clang", "swift-frontend",
        "cc1plus", "rustc", "cargo", "node_modules/.bin",
        "Xcode.app", "Final Cut Pro.app", "Compressor.app",
        "com.docker", "qemu", "HandBrake",
    ]
}

// MARK: - Kernel sampling primitives (no shelling out, no allocation churn)

struct Sample {
    let cpuNanos: UInt64      // cumulative user + system
    let footprint: UInt64     // ri_phys_footprint (what Activity Monitor calls Memory)
    let startAbs: UInt64      // distinguishes a recycled pid from the original
    let wakeups: UInt64       // idle wakeups - the metric that actually drives heat
}

/// proc_pid_rusage reports CPU time in MACH ABSOLUTE TIME UNITS, not nanoseconds.
/// On Intel the timebase is 1/1 so the two coincide and the bug is invisible;
/// on Apple Silicon it is 125/3, making raw values ~41.7x too small. Always convert.
let machTimebase: (numer: UInt64, denom: UInt64) = {
    var tb = mach_timebase_info_data_t()
    mach_timebase_info(&tb)
    return (UInt64(tb.numer), UInt64(tb.denom))
}()

@inline(__always)
func absToNanos(_ v: UInt64) -> UInt64 {
    machTimebase.numer == machTimebase.denom ? v : v &* machTimebase.numer / machTimebase.denom
}

@inline(__always)
func sampleProc(_ pid: pid_t) -> Sample? {
    var info = rusage_info_v4()
    let rc = withUnsafeMutablePointer(to: &info) { p -> Int32 in
        p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
            proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
        }
    }
    guard rc == 0 else { return nil }
    return Sample(cpuNanos: absToNanos(info.ri_user_time &+ info.ri_system_time),
                  footprint: info.ri_phys_footprint,
                  startAbs: info.ri_proc_start_abstime,
                  wakeups: info.ri_pkg_idle_wkups)
}

/// Reuses its buffer across calls so a scan allocates nothing.
final class PIDLister {
    private var buf = [pid_t](repeating: 0, count: 2048)
    func list() -> ArraySlice<pid_t> {
        while true {
            let bytes = buf.withUnsafeMutableBufferPointer {
                proc_listpids(UInt32(PROC_ALL_PIDS), 0, $0.baseAddress,
                              Int32($0.count * MemoryLayout<pid_t>.size))
            }
            guard bytes > 0 else { return buf[0..<0] }
            let n = Int(bytes) / MemoryLayout<pid_t>.size
            if n < buf.count { return buf[0..<n] }
            buf = [pid_t](repeating: 0, count: buf.count * 2)   // rare
        }
    }
}

/// Expensive (string copy), so we call it only for suspects and cache it.
func execPath(_ pid: pid_t) -> String {
    var buf = [CChar](repeating: 0, count: 4096)
    let r = proc_pidpath(pid, &buf, UInt32(buf.count))
    return r > 0 ? String(cString: buf) : "<pid \(pid)>"
}

/// The kernel's short name (comm), used when a basename is unhelpful.
func procName(_ pid: pid_t) -> String {
    var buf = [CChar](repeating: 0, count: 256)
    let r = proc_name(pid, &buf, UInt32(buf.count))
    return r > 0 ? String(cString: buf) : ""
}

/// Basenames are usually right, but some binaries live in versioned directories
/// (".../2.1.263/claude"), where the basename is a version string. Fall back.
func displayName(_ pid: pid_t, _ path: String) -> String {
    let base = (path as NSString).lastPathComponent
    let looksLikeVersion = !base.isEmpty && base.allSatisfy { $0.isNumber || $0 == "." }
    if looksLikeVersion || base.isEmpty {
        let n = procName(pid)
        if !n.isEmpty { return n }
    }
    return base
}

// MARK: - Tier 0 gate: whole-machine CPU, one Mach call, microseconds

func hostCPUTicks() -> (busy: UInt64, total: UInt64)? {
    var size = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size
                                      / MemoryLayout<integer_t>.size)
    var info = host_cpu_load_info_data_t()
    let rc = withUnsafeMutablePointer(to: &info) { p -> kern_return_t in
        p.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
            host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &size)
        }
    }
    guard rc == KERN_SUCCESS else { return nil }
    let u = UInt64(info.cpu_ticks.0), s = UInt64(info.cpu_ticks.1)
    let i = UInt64(info.cpu_ticks.2), n = UInt64(info.cpu_ticks.3)
    return (busy: u &+ s &+ n, total: u &+ s &+ n &+ i)
}

/// Matches whole path components, never raw substrings: "ld" as a substring
/// matches "/var/folders/..." because "folders" contains it.
func isAllowed(path: String, allowList: [String]) -> Bool {
    guard !path.isEmpty else { return false }
    let components = path.components(separatedBy: "/").filter { !$0.isEmpty }
    return allowList.contains { entry in
        guard entry.count >= 2 else { return false }
        if entry.contains("/") { return path.localizedCaseInsensitiveContains(entry) }
        return components.contains {
            $0.compare(entry, options: .caseInsensitive) == .orderedSame
                || $0.lowercased().hasPrefix(entry.lowercased())
        }
    }
}

// MARK: - Detector state

struct Track {
    var startAbs: UInt64
    var lastCPU: UInt64
    var lastFootprint: UInt64
    var overSince: Date?        // when it first crossed the threshold
    var footprintAtCross: UInt64
    var alerted = false
}

final class Detector {
    private let cfg: Config
    private let lister = PIDLister()
    private var tracks: [pid_t: Track] = [:]
    private var pathCache: [pid_t: String] = [:]
    private var lastScan = Date()
    private let selfPID = getpid()

    // self-instrumentation
    private(set) var scanCount = 0
    private(set) var lastSampled = 0
    private(set) var lastListed = 0
    private(set) var startedAt = Date()

    init(cfg: Config) { self.cfg = cfg }

    var hasActiveSuspect: Bool { tracks.values.contains { $0.overSince != nil } }

    struct Alert {
        let pid: pid_t
        let name: String
        let path: String
        let cpuPercent: Double
        let heldFor: TimeInterval
        let footprintMB: Double
        let footprintGrowthMB: Double
    }

    /// One pass. Returns any process that just crossed from "suspect" to "confirmed".
    func scan(syntheticDt: Double? = nil) -> [Alert] {
        let now = Date()
        let dt = syntheticDt ?? now.timeIntervalSince(lastScan)
        lastScan = now
        scanCount += 1
        guard dt > 0.05 else { return [] }

        var alerts: [Alert] = []
        var seen = Set<pid_t>()
        var sampled = 0
        var listed = 0

        for pid in lister.list() {
            listed += 1
            guard pid > 0, let s = sampleProc(pid) else { continue }
            sampled += 1
            seen.insert(pid)

            guard var t = tracks[pid], t.startAbs == s.startAbs else {
                // new process, or a recycled pid - start fresh, no reading yet
                tracks[pid] = Track(startAbs: s.startAbs, lastCPU: s.cpuNanos,
                                    lastFootprint: s.footprint, overSince: nil,
                                    footprintAtCross: s.footprint)
                continue
            }

            let deltaNanos = s.cpuNanos &- t.lastCPU
            let pct = (Double(deltaNanos) / 1_000_000_000.0) / dt * 100.0
            t.lastCPU = s.cpuNanos
            t.lastFootprint = s.footprint

            if pct >= cfg.cpuThreshold && pid != selfPID {
                if t.overSince == nil {
                    t.overSince = now
                    t.footprintAtCross = s.footprint
                }
                let held = now.timeIntervalSince(t.overSince!)
                if held >= cfg.sustainSecs && !t.alerted {
                    let path = pathCache[pid] ?? {
                        let p = execPath(pid); pathCache[pid] = p; return p
                    }()
                    if !isAllowed(path: path, allowList: cfg.allowList) {
                        t.alerted = true
                        alerts.append(Alert(
                            pid: pid, name: displayName(pid, path), path: path,
                            cpuPercent: pct, heldFor: held,
                            footprintMB: Double(s.footprint) / 1_048_576.0,
                            footprintGrowthMB: Double(Int64(s.footprint) - Int64(t.footprintAtCross)) / 1_048_576.0))
                    } else {
                        t.alerted = true   // allowlisted: never ask again this run
                    }
                }
            } else {
                t.overSince = nil
                t.alerted = false
            }
            tracks[pid] = t
        }

        // reap exited processes so the dictionaries do not grow without bound
        if tracks.count > seen.count {
            tracks = tracks.filter { seen.contains($0.key) }
            pathCache = pathCache.filter { seen.contains($0.key) }
        }
        lastSampled = sampled; lastListed = listed
        return alerts
    }
}

// MARK: - Diagnosis. Runs once per incident, never on a timer.

func diagnose(_ pid: pid_t, _ processName: String = "") -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
    p.arguments = ["\(pid)", "2", "-mayDie"]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return "could not sample (\(error.localizedDescription))" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard let text = String(data: data, encoding: .utf8) else { return "unreadable sample" }

    // Only the "sort by top of stack" section says where time is actually spent.
    // Locate it with a single range search and take a bounded window - never
    // split or copy the whole sample output, which can run to hundreds of KB.
    let hay: Substring
    if let r = text.range(of: "Sort by top of stack", options: .backwards) {
        hay = text[r.upperBound...].prefix(3000)
    } else {
        hay = text.suffix(3000)
    }

    // Ordered most-specific first.
    let rules: [(String, [String])] = [
        ("a web page stuck throwing JavaScript errors in a loop",
         ["Interpreter::unwind", "getStackTrace"]),
        ("runaway JavaScript (promise/microtask storm)",
         ["runInternalMicrotask", "MicrotaskQueue"]),
        ("heavy JavaScript execution", ["JavaScriptCore"]),
        ("a runaway animation or redraw loop", ["QuartzCore", "CA::Render"]),
        ("garbage-collection thrash - likely a memory leak", ["MarkedBlock", "collectAsync", "Heap::"]),
        ("an event-loop spin (kevent churn)", ["kevent", "__CFRunLoopServiceMachPort"]),
        ("allocation churn", ["malloc_zone", "free_tiny"]),
    ]
    for (verdict, needles) in rules where needles.allSatisfy({ hay.contains($0) }) {
        return verdict
    }
    // Guard against a false positive: threads parked, not burning.
    if hay.contains("__psynch_cvwait") && !hay.contains("JavaScriptCore") {
        return "mostly idle threads - the CPU time may be elsewhere; worth a manual look"
    }
    if !processName.isEmpty, hay.contains("(in \(processName))") {
        return "a tight loop in the program's own code"
    }
    return "unrecognised pattern - run: sample \(pid) 5"
}

// MARK: - Self-instrumentation. We hold ourselves to the same standard.

func ownCPUNanos() -> UInt64 { sampleProc(getpid())?.cpuNanos ?? 0 }

func fmtNanos(_ n: UInt64) -> String {
    let ms = Double(n) / 1_000_000.0
    return ms < 1 ? String(format: "%.0f us", ms * 1000) : String(format: "%.2f ms", ms)
}

/// Reports what the running daemon has actually cost. Closes the loop: the
/// budget claim is verifiable at any time, not just at build time.
func cmdCost(pidArg: pid_t?) {
    var target = pidArg
    if target == nil {
        let lister = PIDLister()
        let me = getpid()
        for pid in lister.list() where pid != me {
            if execPath(pid).hasSuffix("/idlewild") { target = pid; break }
        }
    }
    guard let pid = target else {
        print("no running idlewild found. start one with: idlewild watch")
        return
    }
    var info = rusage_info_v4()
    let rc = withUnsafeMutablePointer(to: &info) { p -> Int32 in
        p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
            proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
        }
    }
    // The throwaway version of this script ignored rc, so a dead pid produced a
    // zeroed struct and it cheerfully reported "0 ms CPU, alive 4.6 days".
    guard rc == 0, info.ri_proc_start_abstime > 0 else {
        print("pid \(pid) is not readable (gone, or owned by another user)")
        return
    }
    let cpuNs = absToNanos(info.ri_user_time &+ info.ri_system_time)
    let aliveNs = absToNanos(mach_absolute_time() &- info.ri_proc_start_abstime)
    guard aliveNs > 0 else { print("pid \(pid) just started; try again shortly"); return }

    let cpuMs = Double(cpuNs) / 1e6
    let aliveH = Double(aliveNs) / 3.6e12
    let duty = Double(cpuNs) / Double(aliveNs) * 100
    print("idlewild (pid \(pid))")
    print(String(format: "  alive        : %.2f hours", aliveH))
    print(String(format: "  CPU consumed : %.1f ms", cpuMs))
    print(String(format: "  duty cycle   : %.5f%% of one core", duty))
    if aliveH > 0.01 {
        let perHour = cpuMs / aliveH
        print(String(format: "  per hour     : %.0f ms  (budget: 1000 ms)", perHour))
        print(perHour < 1000 ? String(format: "  PASS - %.0fx under budget", 1000 / max(perHour, 0.001))
                             : "  OVER BUDGET - raise --interval")
    }
}

// MARK: - Commands

func cmdScan() {
    // Independent two-point sampler, deliberately NOT sharing Detector's code
    // path, so this can be cross-checked against ps(1).
    let lister = PIDLister()
    var first: [pid_t: UInt64] = [:]
    for pid in lister.list() { if let s = sampleProc(pid) { first[pid] = s.cpuNanos } }
    let t0 = Date()
    Thread.sleep(forTimeInterval: 2.0)
    let dt = Date().timeIntervalSince(t0)

    var rows: [(pct: Double, pid: pid_t, mb: Double)] = []
    for pid in lister.list() {
        guard let s = sampleProc(pid), let p0 = first[pid] else { continue }
        let pct = Double(s.cpuNanos &- p0) / 1_000_000_000.0 / dt * 100.0
        if pct > 0.5 { rows.append((pct, pid, Double(s.footprint) / 1_048_576.0)) }
    }
    rows.sort { $0.pct > $1.pct }
    print(String(format: "%7@ %7@ %9@  %@", "CPU%" as NSString, "PID" as NSString,
                 "MEM(MB)" as NSString, "PROCESS" as NSString))
    for r in rows.prefix(12) {
        print(String(format: "%6.1f%% %7d %9.0f  %@", r.pct, r.pid, r.mb, displayName(r.pid, execPath(r.pid))))
    }
}

func cmdSelfTest(cycles: Int) {
    print("idlewild selftest - \(cycles) full scans, back to back")
    let d = Detector(cfg: Config())
    _ = d.scan()
    let t0 = ownCPUNanos()
    let wall0 = Date()
    for _ in 0..<cycles { _ = d.scan(syntheticDt: 1.0) }
    let cost = ownCPUNanos() - t0
    let wall = Date().timeIntervalSince(wall0)

    let perScan = Double(cost) / Double(cycles)
    print(String(format: "  total   : %@ CPU over %.2f s wall", fmtNanos(cost), wall))
    print(String(format: "  per scan: %@", fmtNanos(UInt64(perScan))))
    print("  pids listed: \(d.lastListed), sampled ok: \(d.lastSampled)")
    print(String(format: "  per pid  : %.0f ns", perScan / Double(max(d.lastSampled,1))))
    print("")
    let cfg = Config()
    for (label, interval) in [("calm (120 s)", cfg.calmInterval), ("busy (10 s)", cfg.busyInterval)] {
        let perHour = perScan * (3600.0 / interval)
        let pct = perHour / 3_600_000_000_000.0 * 100.0
        print(String(format: "  at %@ -> %.1f ms CPU/hour  (%.5f%% of one core)",
                     label, perHour / 1_000_000.0, pct))
    }
    print("")
    let budgetNs = 1_000_000_000.0                    // 1 second per hour
    let worst = perScan * (3600.0 / cfg.busyInterval) // assume always-busy
    print(worst < budgetNs
          ? String(format: "  PASS - worst case is %.0fx under the 1 s/hour budget", budgetNs / worst)
          : "  FAIL - over budget")
}

func cmdWatch(cfg: Config) {
    let d = Detector(cfg: cfg)
    let q = DispatchQueue(label: "idlewild.scan", qos: .utility)
    let timer = DispatchSource.makeTimerSource(queue: q)

    func reschedule(interval: Double) {
        timer.schedule(deadline: .now() + interval,
                       repeating: interval,
                       leeway: .milliseconds(Int(interval * cfg.leewayFrac * 1000)))
    }

    var currentInterval = cfg.calmInterval
    let iso = ISO8601DateFormatter()

    timer.setEventHandler {
        for a in d.scan() {
            let why = diagnose(a.pid, a.name)
            print("""

            [\(iso.string(from: Date()))]  RUNAWAY PROCESS
              \(a.name)  (pid \(a.pid))
              \(String(format: "%.0f%%", a.cpuPercent)) of one core, held for \(a.heldFor < 90 ? "\(Int(a.heldFor))s" : "\(Int(a.heldFor / 60)) min")
              memory \(String(format: "%.0f MB", a.footprintMB)) \
            (\(String(format: "%+.0f MB", a.footprintGrowthMB)) since it started spinning)
              likely cause: \(why)
              to stop it:   kill \(a.pid)
            """)
            fflush(stdout)
        }
        // Adaptive cadence: tighten only while something is actually building.
        let want = d.hasActiveSuspect ? cfg.busyInterval : cfg.calmInterval
        if want != currentInterval { currentInterval = want; reschedule(interval: want) }
    }

    reschedule(interval: currentInterval)
    timer.resume()
    print("idlewild watching. threshold \(Int(cfg.cpuThreshold))% of a core, "
          + "sustained \(Int(cfg.sustainSecs / 60)) min. calm scan every \(Int(cfg.calmInterval)) s.")
    fflush(stdout)
    dispatchMain()
}

// MARK: - Entry

var cfg = Config()
let args = Array(CommandLine.arguments.dropFirst())
var cmd = args.first ?? "watch"

var i = 1
while i < args.count {
    switch args[i] {
    case "--threshold": if i+1 < args.count { cfg.cpuThreshold = Double(args[i+1]) ?? cfg.cpuThreshold; i += 1 }
    case "--sustain":   if i+1 < args.count { cfg.sustainSecs = (Double(args[i+1]) ?? 5) * 60; i += 1 }
    case "--interval":  if i+1 < args.count { cfg.calmInterval = Double(args[i+1]) ?? cfg.calmInterval; i += 1 }
    default: break
    }
    i += 1
}

switch cmd {
case "selftest": cmdSelfTest(cycles: 200)
case "scan":     cmdScan()
case "cost":     cmdCost(pidArg: args.count > 1 ? pid_t(args[1]) : nil)
case "watch":    cmdWatch(cfg: cfg)
default:
    print("usage: idlewild [watch|scan|selftest|cost] [--threshold PCT] [--sustain MIN] [--interval SEC]")
}
