// SPDX-FileCopyrightText: 2026 Luca Gibelli
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

struct Incident: Identifiable, Equatable {
    enum Kind { case cpu, memory }

    let id = UUID()
    let kind: Kind
    let pid: pid_t
    let name: String
    let path: String
    let cpuPercent: Double
    let heatWeight: Double      // 0...1, share of time on performance cores
    let ipc: Double
    /// When a CPU process first crossed the threshold. The duration is read
    /// from this at display time instead of being frozen when the alert fired:
    /// the process is normally still running away when the menu is opened, so a
    /// reading of "5 min" twenty minutes in would be plainly wrong. Memory
    /// incidents have no crossing instant - theirs is a measurement.
    var heldSince: Date? = nil
    /// The measured duration, used as-is by memory incidents (the span a leak's
    /// history was fitted to) and as the floor for a CPU one, which must never
    /// read less than it did when the alert fired.
    var heldMeasured: TimeInterval = 0

    /// How long to say the process has been running away: the live elapsed time
    /// since it crossed for a CPU incident, the measured span for a memory one.
    var heldFor: TimeInterval {
        guard let heldSince else { return heldMeasured }
        return max(heldMeasured, Date().timeIntervalSince(heldSince))
    }

    let footprintMB: Double
    let growthMBPerMin: Double
    /// Memory incidents only: this process's share of physical RAM, 0...1, and
    /// whether the kernel was reporting memory pressure when it was raised.
    var memoryShare: Double = 0
    var underPressure: Bool = false
    var swapUsedBytes: UInt64 = 0
    /// At the fitted growth rate, how long until it has eaten all physical
    /// memory. Nil when it is not growing.
    var fillsIn: TimeInterval? = nil
    var cause: String = ""
    /// Set when an "Always Force Quit" rule covers this process: it is to be
    /// stopped, not reported.
    var autoQuit: AutoQuitRule? = nil

    static func == (a: Incident, b: Incident) -> Bool { a.id == b.id }

    /// Memory climbing steadily while CPU is pinned is strong evidence of a
    /// runaway loop rather than honest work.
    var isLeaking: Bool { growthMBPerMin > 1.0 }

    /// SIGSTOP stops a CPU burn but frees nothing, so pausing a memory hog
    /// would leave the user exactly where they were.
    var canPause: Bool { kind == .cpu }

    var footprintText: String { formatBytes(UInt64(max(footprintMB, 0) * 1_048_576)) }

    var summary: String {
        switch kind {
        case .cpu:
            var s = String(format: "%.0f%% CPU for %@", cpuPercent, formatDuration(heldFor))
            if isLeaking { s += String(format: ", memory +%.0f MB/min", growthMBPerMin) }
            return s
        case .memory:
            var s = String(format: "%@, %.0f%% of memory", footprintText, memoryShare * 100)
            if isLeaking { s += String(format: ", growing %.0f MB/min", growthMBPerMin) }
            return s
        }
    }

    /// Compact enough for a single menu item title.
    var menuSummary: String {
        switch kind {
        case .cpu:
            return String(format: "%.0f%% for %@", cpuPercent, formatDuration(heldFor))
        case .memory:
            return isLeaking
                ? String(format: "%@, +%.0f MB/min", footprintText, growthMBPerMin)
                : String(format: "%@, %.0f%% of memory", footprintText, memoryShare * 100)
        }
    }

    /// What "Always Allow" would actually add to the allowlist.
    var binaryName: String {
        let base = (path as NSString).lastPathComponent
        return base.isEmpty ? name : base
    }
}

func formatDuration(_ t: TimeInterval) -> String {
    if t < 90 { return "\(Int(t))s" }
    if t < 5400 { return "\(Int(t / 60)) min" }
    return String(format: "%.1f hours", t / 3600)
}

/// The whole machine's CPU, as opposed to any one process's. A dozen programs
/// each well under the threshold, or hundreds that start and finish between two
/// scans, keep a Mac's cores busy as thoroughly as one runaway does, and none
/// of them is an incident. Nor is this: there is no process to stop. But a menu
/// that said "Nothing running away" and stopped there, on a machine with every
/// core in use, read as "all is well".
struct MachineLoad {
    struct Share {
        let name: String
        /// Cores in use, averaged over the window.
        let cores: Double

        var text: String { String(format: "%@ \u{2014} %.1f cores", name, cores) }
    }

    /// Cores in use, averaged over the sustain window.
    let cores: Double
    let of: Int
    /// The start of the first window that came out busy.
    let since: Date
    /// Where it is going, largest first. Short: this is a menu, and CPU History
    /// has the rest.
    let top: [Share]

    /// CPU time no process could be named for: what belongs to root, to other
    /// users or to the kernel, and what was used by programs that started and
    /// finished between two scans. CPU History draws it as System & kernel; on
    /// a machine that is building or running tests most of it is the second
    /// kind, and here it is one line of four, so it says so.
    static let unattributed = "System & short-lived processes"

    var heldFor: TimeInterval { Date().timeIntervalSince(since) }

    var summary: String {
        String(format: "%.1f of %d cores in use for %@", min(cores, Double(of)), of,
               formatDuration(heldFor))
    }
}

/// The Mac moving memory to and from swap faster than it can afford to. Every
/// page read back from swap is a stall in whatever needed it, and every page
/// written out is the working set not fitting in memory. Like MachineLoad this
/// is about the machine and not one process: a dozen apps of a gigabyte or two
/// each fill a Mac's memory as thoroughly as one runaway does, and none of them
/// is the problem on its own. So it names the apps holding the memory, all of
/// a browser's or a build's processes added up, however small each one is.
struct Swapping {
    struct Holder {
        let name: String
        let bytes: UInt64
        let processes: Int

        var text: String {
            "\(name) \u{2014} \(formatBytes(bytes))" + (processes > 1 ? " in \(processes) processes" : "")
        }
    }

    /// Bytes a second moved to or from swap, averaged over the window, and how
    /// much of it was read back.
    let rate: Double
    let readBack: Double
    /// Swap in use now.
    let used: UInt64
    /// The start of the first window that came out heavy.
    let since: Date
    /// The apps holding the most memory, largest first.
    let top: [Holder]

    var heldFor: TimeInterval { Date().timeIntervalSince(since) }

    var rateText: String { Self.rate(rate) }

    static func rate(_ bytesPerSecond: Double) -> String {
        let mb = bytesPerSecond / 1_048_576
        return String(format: mb < 10 ? "%.1f MB/s" : "%.0f MB/s", mb)
    }

    /// "Swapping 21 MB/s for 12 min"
    var headline: String { "Swapping \(rateText) for \(formatDuration(heldFor))" }

    var details: [String] {
        ["\(Self.rate(readBack)) read back from swap and \(Self.rate(max(rate - readBack, 0))) written to it, on average",
         "\(formatBytes(used)) of swap in use, on a Mac with \(formatBytes(HostMemory.physical)) of memory",
         // Otherwise the apps below add up to more than the Mac has, and look wrong.
         "What each app holds includes what of it has been compressed or swapped out"]
    }
}

/// Decides when the swapping is heavy, from the system's running totals of
/// what it has moved to and from swap. Kept apart from the detector, which
/// reads the totals, so the decision can be tested on totals made up for it.
struct SwapWatch {
    /// Heavy is an average over ten minutes, so the cost of waking an app
    /// that was swapped out overnight, a gigabyte or two read back once, is
    /// not mistaken for a machine that keeps running out of memory.
    static let window: TimeInterval = 600
    /// 4 MB/s is 2.4 GB moved in the window. A Mac with room to spare moves
    /// almost nothing; one that has run out moves tens of megabytes a second
    /// for as long as it stays out. It stays heavy until the average falls
    /// under half that, so a machine sitting on the line is one episode.
    static let heavyAt: Double = 4 * 1_048_576
    static let easedAt: Double = 2 * 1_048_576

    private struct Point { let t: TimeInterval; let moved: UInt64; let readBack: UInt64 }
    private var points: [Point] = []
    private(set) var since: TimeInterval?
    private(set) var rate: Double = 0
    private(set) var readBack: Double = 0

    mutating func reset() {
        points.removeAll()
        since = nil
        rate = 0
        readBack = 0
    }

    /// Takes the running totals at time t, in bytes. Returns whether the
    /// swapping is heavy now.
    @discardableResult
    mutating func add(at t: TimeInterval, moved: UInt64, readBack read: UInt64) -> Bool {
        // Totals only grow. One that went down is a counter that started
        // again, and nothing before it can be compared with what follows.
        if let last = points.last, t <= last.t || moved < last.moved || read < last.readBack {
            reset()
        }
        points.append(Point(t: t, moved: moved, readBack: read))
        // Keep one point at or before the start of the window, so the average
        // always covers all of it.
        while points.count > 2, points[1].t <= t - Self.window { points.removeFirst() }
        guard let first = points.first, t - first.t >= Self.window else {
            since = nil
            return false
        }
        let span = t - first.t
        rate = Double(moved - first.moved) / span
        readBack = Double(read - first.readBack) / span
        if rate >= Self.heavyAt {
            if since == nil { since = first.t }
        } else if rate < Self.easedAt {
            since = nil
        }
        return since != nil
    }
}

private struct MemPoint {
    let t: Double        // seconds, timeIntervalSinceReferenceDate
    let bytes: UInt64
}

/// Least-squares line through a footprint history, with the goodness of fit.
/// A leak is a straight line: r² near 1, positive slope. Honest work is a
/// staircase (loads something, stops) or a sawtooth (allocates, collects),
/// and both fit a line badly.
struct LeakFit {
    let bytesPerSecond: Double
    let r2: Double
    let span: TimeInterval
    let grownBytes: Double
    let count: Int

    var mbPerMin: Double { bytesPerSecond * 60 / 1_048_576 }

    fileprivate init?(_ pts: [MemPoint]) {
        guard pts.count >= 2, let first = pts.first, let last = pts.last else { return nil }
        let n = Double(pts.count)
        let t0 = first.t, y0 = Double(first.bytes)
        var sx = 0.0, sy = 0.0, sxx = 0.0, sxy = 0.0, syy = 0.0
        for p in pts {
            let x = p.t - t0, y = Double(p.bytes) - y0
            sx += x; sy += y; sxx += x * x; sxy += x * y; syy += y * y
        }
        let vx = sxx - sx * sx / n
        let vy = syy - sy * sy / n
        guard vx > 0 else { return nil }
        let cov = sxy - sx * sy / n
        bytesPerSecond = cov / vx
        r2 = vy > 0 ? (cov * cov) / (vx * vy) : 0
        span = last.t - first.t
        grownBytes = Double(last.bytes) - Double(first.bytes)
        count = pts.count
    }

    /// Everything that has to be true before a rising footprint is called a
    /// leak. Each clause removes a class of false positive that a plain
    /// threshold would raise.
    func isLeak(sustain: TimeInterval, latest: UInt64, peak: UInt64,
                physical: UInt64, fillHours: Double) -> Bool {
        guard count >= 6, span >= sustain else { return false }          // enough evidence
        guard bytesPerSecond > 0, r2 >= 0.85 else { return false }        // a line, going up
        guard grownBytes >= 32 * 1_048_576,                                // not noise...
              grownBytes >= Double(latest) * 0.05 else { return false }   // ...relative to its size
        guard Double(latest) >= Double(peak) * 0.98 else { return false } // still climbing, no plateau
        return fillsIn(latest: latest, physical: physical) <= fillHours * 3600
    }

    func fillsIn(latest: UInt64, physical: UInt64) -> TimeInterval {
        guard bytesPerSecond > 0, physical > latest else { return .infinity }
        return Double(physical - latest) / bytesPerSecond
    }
}

private struct Track {
    var startAbs: UInt64
    var lastCPU: UInt64
    var lastFootprint: UInt64
    var overSince: Date?
    /// When a process that is running away first dipped back under the
    /// threshold. See Detector.calmAfter.
    var underSince: Date?
    var footprintAtCross: UInt64
    var alerted = false
    var lastPercent: Double = 0

    // Memory. A time-decimated history of the footprint, kept only once the
    // process is large enough to be worth watching, so the hundreds of small
    // processes on a Mac cost nothing here. Cleared on a real drop, which is a
    // process freeing memory and therefore not leaking it.
    var mem: [MemPoint] = []
    var memStoredAt: Double = -.infinity
    var memPeak: UInt64 = 0
    var memAlerted = false

    /// The name the history files this process's CPU time under, resolved the
    /// first time it uses any.
    var account: String?
    /// The account was named while the process was under a second old, when it
    /// may still have been a launcher about to exec into something else. It is
    /// named once more, from a fresh path, the next time the process uses CPU.
    var accountProvisional = false

    init(startAbs: UInt64, cpu: UInt64, footprint: UInt64) {
        self.startAbs = startAbs
        lastCPU = cpu
        lastFootprint = footprint
        footprintAtCross = footprint
    }

    mutating func clearMemory() {
        if !mem.isEmpty { mem.removeAll(keepingCapacity: true) }
        memPeak = 0
        memAlerted = false
    }
}

/// Pure detection logic. No UI, no I/O beyond the kernel calls, so it can be
/// exercised directly in tests and in the CLI.
///
/// Not internally synchronised: safety comes from confinement to Monitor's scan
/// queue. Every caller must be on that queue.
final class Detector: @unchecked Sendable {
    private let lister = PIDLister()
    private var tracks: [pid_t: Track] = [:]
    private var pathCache: [pid_t: String] = [:]
    private var lastScan = Date()
    private let selfPID = getpid()
    private var swapWatch = SwapWatch()
    /// Set while the Mac is swapping heavily. See Swapping.
    private(set) var swapping: Swapping?

    /// CPU time used since the last takeUsage(), by app, for the history. The
    /// deltas are computed for detection anyway; filing them costs a dictionary
    /// update per busy process per scan.
    private var usage = Usage()
    /// The same, for the scan in progress alone.
    private var scanned = Usage()
    private var lastHostTicks: HostCPU.Ticks?

    /// The last sustain window of CPU time, in about ten pieces however often
    /// the scans come, and what it adds up to. See weigh.
    private var recent: [Usage] = []
    private var busySince: Date?
    private(set) var load: MachineLoad?

    var settings: AppSettings

    init(settings: AppSettings) { self.settings = settings }

    /// Something is building towards an alert, so the caller should scan more
    /// often. A rising footprint counts only once it is large enough to matter,
    /// and only while it rises fast enough to be reported: at the rate of its
    /// last step it would fill memory within the horizon. At any moment
    /// *something* on a Mac is growing, and a Gradle daemon of 5 GB putting on
    /// a few hundred kilobytes a minute would otherwise hold the cadence tight
    /// for as long as it ran, spending the CPU budget on nothing.
    var hasActiveSuspect: Bool {
        let limit = settings.memoryEnabled ? settings.memoryThresholdBytes : UInt64.max
        let horizon = settings.memoryFillHours * 3600
        let physical = HostMemory.physical
        return tracks.values.contains { t in
            if t.overSince != nil { return true }
            guard t.lastFootprint >= limit, t.mem.count >= 2 else { return false }
            let a = t.mem[t.mem.count - 2], b = t.mem[t.mem.count - 1]
            guard b.bytes > a.bytes, b.t > a.t, physical > b.bytes else { return false }
            let rate = Double(b.bytes - a.bytes) / (b.t - a.t)
            return Double(physical - b.bytes) / rate <= horizon
        }
    }

    /// History points are spaced so that the sustain window holds a fit's worth
    /// of them whatever the scan cadence, and capped so a long-lived process
    /// never accumulates more than a few hundred bytes of it.
    static let historyCap = 64

    /// How long a process that is running away must stay under the threshold
    /// before it counts as calm. Without this one quiet scan reset the clock:
    /// a process busy for an hour was reported four times in twenty minutes,
    /// and a rule to force quit something after an hour could never fire on a
    /// process that paused for breath.
    static let calmAfter: TimeInterval = 60

    /// A gap between scans longer than this is the machine asleep or
    /// monitoring paused. The CPU used across it cannot be placed in time, so
    /// the history leaves the gap empty rather than piling it into one slice.
    static let longestAccountedGap: TimeInterval = 900

    /// Launchers exec into the program they start within milliseconds:
    /// xpcproxy for every launchd job, xpcproxy_sim for every process in the
    /// iOS Simulator, arch, a shell's exec. A process named this young is named
    /// again later; without that, a Simulator app first seen in that instant
    /// filed hours of its CPU under xpcproxy_sim.
    static let launcherWindow: UInt64 = 1_000_000_000

    /// The machine is busy once the sustain window averages half its cores in
    /// use, and stays so until that drops under four tenths, so a load sitting
    /// on the line is one busy spell and not twenty. Half is deliberately well
    /// short of full: load that comes in bursts, a test run and then a build,
    /// pins every core for half a minute at a time and averages two thirds.
    /// It can afford to be generous because it only changes what the menu says.
    static let busyAt = 0.5
    static let easedAt = 0.4

    /// Processes whose incident is still true: running away, allowing for
    /// brief dips, or still holding the memory they were reported for. Monitor
    /// drops every incident not in here, so a process that has exited or calmed
    /// down stops being listed as running away.
    var ongoing: Set<pid_t> {
        var s = Set<pid_t>()
        for (pid, t) in tracks where t.overSince != nil || t.memAlerted { s.insert(pid) }
        return s
    }

    /// Hands over the CPU time recorded since the last call and starts afresh.
    func takeUsage() -> Usage {
        defer { usage = Usage() }
        return usage
    }

    func scan(syntheticDt: Double? = nil) -> [Incident] {
        let now = Date()
        let dt = syntheticDt ?? now.timeIntervalSince(lastScan)
        lastScan = now
        guard dt > 0.05 else { return [] }

        let watchCPU = settings.cpuEnabled
        let watchMemory = settings.memoryEnabled
        let memLimit = settings.memoryThresholdBytes
        let memGate = memLimit / 4                 // start keeping history here
        let memSustain = settings.memorySustainSeconds
        let memFillHours = settings.memoryFillHours
        let spacing = min(max(memSustain / 8, dt), 60)
        let tnow = now.timeIntervalSinceReferenceDate
        let pressure = watchMemory ? HostMemory.pressure() : .unknown

        var incidents: [Incident] = []
        var seen = Set<pid_t>()

        // The first scan only learns where every counter stands. After that a
        // process with no track was born since the last scan, so all the CPU
        // it has ever used falls inside this window.
        let primed = !tracks.isEmpty
        let accounting = primed && dt <= Self.longestAccountedGap
        scanned = Usage()
        if let host = HostCPU.busyTicks() {
            if accounting, let last = lastHostTicks {
                scanned.busy = HostCPU.seconds(from: last, to: host)
            }
            lastHostTicks = host
        }
        if accounting { scanned.span = dt }

        for pid in lister.list() {
            guard pid > 0, let s = sampleProc(pid) else { continue }
            seen.insert(pid)

            guard var t = tracks[pid], t.startAbs == s.startAbs else {
                var fresh = Track(startAbs: s.startAbs, cpu: s.cpuNanos, footprint: s.footprint)
                if accounting { charge(pid, &fresh, nanos: s.cpuNanos) }
                tracks[pid] = fresh
                continue
            }

            // A process can read up to a millisecond of CPU time higher while it
            // execs than a moment later, same pid and start time. Wrapping that
            // step back filed 584 years of CPU under xpcproxy_sim; it is nothing.
            let used = s.cpuNanos >= t.lastCPU ? s.cpuNanos - t.lastCPU : 0
            if accounting { charge(pid, &t, nanos: used) }
            let pct = (Double(used) / 1e9) / dt * 100.0
            t.lastCPU = s.cpuNanos
            t.lastFootprint = s.footprint
            t.lastPercent = pct

            let over = watchCPU && pct >= settings.cpuThreshold && pid != selfPID
            if over {
                t.underSince = nil
                if t.overSince == nil { t.overSince = now; t.footprintAtCross = s.footprint }
            } else if t.overSince == nil {
                t.alerted = false
            } else {
                // A dip. The clock keeps running until the process has stayed
                // down long enough to count as calm.
                let under = t.underSince ?? now
                t.underSince = under
                if !watchCPU || now.timeIntervalSince(under) >= Self.calmAfter {
                    t.overSince = nil
                    t.underSince = nil
                    t.alerted = false
                }
            }

            if over, let since = t.overSince, !t.alerted {
                let held = now.timeIntervalSince(since)
                if held >= settings.sustainSeconds {
                    let path = cachedPath(pid)
                    let grownMB = Double(Int64(s.footprint) - Int64(t.footprintAtCross)) / 1_048_576
                    var incident = Incident(
                        kind: .cpu,
                        pid: pid, name: friendlyName(pid, path), path: path,
                        cpuPercent: pct, heatWeight: s.qos.heatWeight, ipc: s.ipc,
                        heldSince: since, heldMeasured: held,
                        footprintMB: Double(s.footprint) / 1_048_576,
                        growthMBPerMin: held > 30 ? grownMB / (held / 60) : 0)
                    if let rule = settings.autoQuitRule(path: path) {
                        // Nobody is asked. The process is left alone until it
                        // has run away for as long as the rule allows.
                        if held >= rule.after {
                            t.alerted = true
                            incident.autoQuit = rule
                            incidents.append(incident)
                        }
                    } else {
                        t.alerted = true
                        if !settings.isAllowed(path: path), !settings.isSnoozed(path: path) {
                            incidents.append(incident)
                        }
                    }
                }
            }

            if watchMemory && pid != selfPID {
                if s.footprint < memGate {
                    if t.memPeak != 0 { t.clearMemory() }
                } else {
                    if t.memPeak > 0, Double(s.footprint) < Double(t.memPeak) * 0.9 { t.clearMemory() }
                    if tnow - t.memStoredAt >= spacing {
                        t.mem.append(MemPoint(t: tnow, bytes: s.footprint))
                        if t.mem.count > Self.historyCap { t.mem.removeFirst() }
                        t.memStoredAt = tnow
                    }
                    t.memPeak = max(t.memPeak, s.footprint)
                }

                if s.footprint >= memLimit {
                    if !t.memAlerted, let fit = LeakFit(t.mem),
                       fit.isLeak(sustain: memSustain, latest: s.footprint, peak: t.memPeak,
                                  physical: HostMemory.physical, fillHours: memFillHours) {
                        t.memAlerted = true
                        let path = cachedPath(pid)
                        if !settings.isAllowed(path: path), !settings.isSnoozed(path: path) {
                            let fills = fit.fillsIn(latest: s.footprint, physical: HostMemory.physical)
                            incidents.append(memoryIncident(
                                pid: pid, path: path, sample: s, heldFor: fit.span,
                                rate: fit.mbPerMin, fillsIn: fills, pressure: pressure,
                                cause: "memory climbing in a straight line for \(formatDuration(fit.span)), "
                                     + "usually a leak; at this rate it fills memory in \(formatDuration(fills))"))
                        }
                    }
                }
            }
            tracks[pid] = t
        }

        if tracks.count > seen.count {
            tracks = tracks.filter { seen.contains($0.key) }
            pathCache = pathCache.filter { seen.contains($0.key) }
        }

        usage.add(scanned)
        weigh(scanned, watching: watchCPU && accounting, at: now)
        watchSwap(watching: watchMemory && accounting, at: now)

        return incidents
    }

    /// Below this a process is left out of the memory holders: there are
    /// hundreds of them on a Mac, and naming each costs a path lookup.
    static let holderFloor: UInt64 = 16 << 20

    /// One Mach call a scan, and a look at every process's footprint, already
    /// read, only while the swapping is heavy.
    private func watchSwap(watching: Bool, at now: Date) {
        // Asleep, paused, or memory not watched: the totals across the gap
        // cannot be placed in time, and whatever was building is over.
        guard watching, let traffic = HostMemory.swapTraffic() else {
            swapWatch.reset()
            swapping = nil
            return
        }
        let heavy = swapWatch.add(at: now.timeIntervalSinceReferenceDate,
                                  moved: traffic.in &+ traffic.out, readBack: traffic.in)
        guard heavy, let since = swapWatch.since else {
            swapping = nil
            return
        }
        swapping = Swapping(rate: swapWatch.rate, readBack: swapWatch.readBack,
                            used: HostMemory.swapUsed(),
                            since: Date(timeIntervalSinceReferenceDate: since),
                            top: memoryHolders())
    }

    /// The apps holding the most memory, each one's processes added up, so a
    /// browser's forty helpers count as the browser. Filed under the same names
    /// as CPU History's.
    private func memoryHolders() -> [Swapping.Holder] {
        var bytes: [String: UInt64] = [:]
        var count: [String: Int] = [:]
        for (pid, t) in tracks where t.lastFootprint >= Self.holderFloor {
            guard let name = t.account ?? accountName(pid, cachedPath(pid)) else { continue }
            bytes[name, default: 0] += t.lastFootprint
            count[name, default: 0] += 1
        }
        var top: [Swapping.Holder] = []
        for (name, b) in bytes {
            top.append(Swapping.Holder(name: name, bytes: b, processes: count[name] ?? 1))
        }
        top.sort { a, b in a.bytes != b.bytes ? a.bytes > b.bytes : a.name < b.name }
        return Array(top.prefix(4))
    }

    /// Adds a scan to the last sustain window and says whether the machine as
    /// a whole has been busy for all of it. Costs no measurement: the host's
    /// busy time and every process's share of it are what the history is
    /// already handed.
    private func weigh(_ u: Usage, watching: Bool, at now: Date) {
        let window = settings.sustainSeconds
        // A gap the CPU time cannot be placed in, or CPU watching switched
        // off: whatever was building is over.
        guard watching, u.span > 0, window > 0 else {
            recent.removeAll()
            busySince = nil
            load = nil
            return
        }
        if let last = recent.last, last.span < window / 10 {
            recent[recent.count - 1].add(u)
        } else {
            recent.append(u)
        }
        var span = recent.reduce(0) { $0 + $1.span }
        while recent.count > 1, span - recent[0].span >= window {
            span -= recent[0].span
            recent.removeFirst()
        }
        // Not a whole window yet: too little to call anything sustained.
        guard span >= window else {
            busySince = nil
            load = nil
            return
        }

        let busy = recent.reduce(0) { $0 + $1.busy }
        let share = busy / span / Double(HostCPU.cores)
        if share >= Self.busyAt {
            if busySince == nil { busySince = now.addingTimeInterval(-span) }
        } else if share < Self.easedAt {
            busySince = nil
        }
        guard let since = busySince else {
            load = nil
            return
        }

        var by: [String: Double] = [:]
        for r in recent { for (k, v) in r.seconds { by[k, default: 0] += v } }
        let named = by.values.reduce(0, +)
        by[MachineLoad.unattributed, default: 0] += max(0, busy - named)
        var top: [MachineLoad.Share] = []
        for (name, seconds) in by where seconds / span >= 0.1 {
            top.append(MachineLoad.Share(name: name, cores: seconds / span))
        }
        top.sort { a, b in a.cores != b.cores ? a.cores > b.cores : a.name < b.name }
        load = MachineLoad(cores: busy / span, of: HostCPU.cores, since: since,
                           top: Array(top.prefix(4)))
    }

    private func memoryIncident(pid: pid_t, path: String, sample s: ProcSample,
                                heldFor: TimeInterval, rate: Double, fillsIn: TimeInterval?,
                                pressure: HostMemory.Pressure, cause: String) -> Incident {
        var i = Incident(kind: .memory,
                         pid: pid, name: friendlyName(pid, path), path: path,
                         cpuPercent: 0, heatWeight: 0, ipc: 0,
                         heldMeasured: heldFor,
                         footprintMB: Double(s.footprint) / 1_048_576,
                         growthMBPerMin: rate)
        i.memoryShare = Double(s.footprint) / Double(HostMemory.physical)
        i.underPressure = pressure.isElevated
        i.swapUsedBytes = pressure.isElevated ? HostMemory.swapUsed() : 0
        i.fillsIn = fillsIn.flatMap { $0.isFinite ? $0 : nil }
        i.cause = cause
        return i
    }

    /// Files CPU time under the app it belongs to. Processes with no name to
    /// file it under are left out, and their time lands in the part of the
    /// history the host counters account for and no process does.
    private func charge(_ pid: pid_t, _ t: inout Track, nanos: UInt64) {
        guard nanos > 0 else { return }
        if t.account == nil || t.accountProvisional {
            let secondLook = t.accountProvisional
            if secondLook { pathCache[pid] = nil }
            t.account = accountName(pid, cachedPath(pid))
            t.accountProvisional = !secondLook
                && absToNanos(mach_absolute_time() &- t.startAbs) < Self.launcherWindow
        }
        guard let name = t.account else { return }
        scanned.seconds[name, default: 0] += Double(nanos) / 1e9
    }

    private func cachedPath(_ pid: pid_t) -> String {
        if let p = pathCache[pid] { return p }
        let p = execPath(pid)
        pathCache[pid] = p
        return p
    }

    /// A rule was just made for a process already reported. Let the next scan
    /// look at it again, so the rule covers the run that prompted it: the
    /// process is stopped then, or when its wait is up.
    func rearm(pid: pid_t) {
        tracks[pid]?.alerted = false
    }

    /// Called when the user chooses "ignore this one" so we stop re-alerting.
    func suppress(pid: pid_t) {
        tracks[pid]?.alerted = true
        tracks[pid]?.overSince = nil
        tracks[pid]?.memAlerted = true
    }
}
