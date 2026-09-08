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
    let heldFor: TimeInterval
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
    var pressureAlerted = false

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
    /// The process named for the current pressure episode. One alarm per
    /// episode: naming the next-largest process on every scan for as long as
    /// the machine swaps would be a list, not an alarm. A new one may be named
    /// only once pressure has cleared or the named process has gone.
    private var pressureNamed: pid_t?

    var settings: AppSettings

    init(settings: AppSettings) { self.settings = settings }

    /// Something is building towards an alert, so the caller should scan more
    /// often. A rising footprint counts only once it is large enough to matter;
    /// at any moment *something* on a Mac is growing, and tightening the cadence
    /// for all of them would spend the CPU budget on nothing.
    var hasActiveSuspect: Bool {
        let limit = settings.memoryEnabled ? settings.memoryThresholdBytes : UInt64.max
        return tracks.values.contains { t in
            if t.overSince != nil { return true }
            guard t.lastFootprint >= limit, t.mem.count >= 2 else { return false }
            return t.mem[t.mem.count - 1].bytes > t.mem[t.mem.count - 2].bytes
        }
    }

    /// History points are spaced so that the sustain window holds a fit's worth
    /// of them whatever the scan cadence, and capped so a long-lived process
    /// never accumulates more than a few hundred bytes of it.
    static let historyCap = 64

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
        var hogs: [(pid: pid_t, sample: ProcSample)] = []

        for pid in lister.list() {
            guard pid > 0, let s = sampleProc(pid) else { continue }
            seen.insert(pid)

            guard var t = tracks[pid], t.startAbs == s.startAbs else {
                tracks[pid] = Track(startAbs: s.startAbs, cpu: s.cpuNanos, footprint: s.footprint)
                continue
            }

            let pct = (Double(s.cpuNanos &- t.lastCPU) / 1e9) / dt * 100.0
            t.lastCPU = s.cpuNanos
            t.lastFootprint = s.footprint
            t.lastPercent = pct

            if watchCPU && pct >= settings.cpuThreshold && pid != selfPID {
                if t.overSince == nil { t.overSince = now; t.footprintAtCross = s.footprint }
                let held = now.timeIntervalSince(t.overSince!)
                if held >= settings.sustainSeconds && !t.alerted {
                    t.alerted = true
                    let path = cachedPath(pid)
                    if !settings.isAllowed(path: path), !settings.isSnoozed(path: path) {
                        let grownMB = Double(Int64(s.footprint) - Int64(t.footprintAtCross)) / 1_048_576
                        incidents.append(Incident(
                            kind: .cpu,
                            pid: pid, name: friendlyName(pid, path), path: path,
                            cpuPercent: pct, heatWeight: s.qos.heatWeight, ipc: s.ipc,
                            heldFor: held,
                            footprintMB: Double(s.footprint) / 1_048_576,
                            growthMBPerMin: held > 30 ? grownMB / (held / 60) : 0))
                    }
                }
            } else {
                t.overSince = nil
                t.alerted = false
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
                if !pressure.isElevated { t.pressureAlerted = false }

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
                    if pressure.isElevated && !t.pressureAlerted && !t.memAlerted {
                        hogs.append((pid, s))
                    }
                }
            }
            tracks[pid] = t
        }

        // Under pressure, name one culprit: the largest process that is not
        // allowlisted. Naming every large process would be a list, not an alarm.
        if !pressure.isElevated || (pressureNamed.map { !seen.contains($0) } ?? false) {
            pressureNamed = nil
        }
        if pressure.isElevated && pressureNamed == nil {
            for h in hogs.sorted(by: { $0.sample.footprint > $1.sample.footprint }) {
                let path = cachedPath(h.pid)
                guard !settings.isAllowed(path: path), !settings.isSnoozed(path: path) else { continue }
                tracks[h.pid]?.pressureAlerted = true
                tracks[h.pid]?.memAlerted = true
                pressureNamed = h.pid
                let track = tracks[h.pid]
                let fit = track.flatMap { LeakFit($0.mem) }
                let growing = (fit?.bytesPerSecond ?? 0) > 0 && (fit?.r2 ?? 0) >= 0.85
                let fills = growing ? fit!.fillsIn(latest: h.sample.footprint, physical: HostMemory.physical) : nil
                let leak = fit?.isLeak(sustain: memSustain, latest: h.sample.footprint,
                                       peak: track?.memPeak ?? 0, physical: HostMemory.physical,
                                       fillHours: memFillHours) ?? false
                let cause: String
                if leak {
                    cause = "memory climbing in a straight line for \(formatDuration(fit!.span)), usually a leak, "
                          + "and the machine is already low on memory; at this rate it fills memory in \(formatDuration(fills!))"
                } else if growing {
                    cause = "the machine is low on memory, and this process is the largest and still growing"
                } else {
                    cause = "the machine is low on memory, and this process is the largest"
                }
                incidents.append(memoryIncident(
                    pid: h.pid, path: path, sample: h.sample,
                    heldFor: fit?.span ?? 0, rate: growing ? fit!.mbPerMin : 0,
                    fillsIn: fills, pressure: pressure, cause: cause))
                break
            }
        }

        if tracks.count > seen.count {
            tracks = tracks.filter { seen.contains($0.key) }
            pathCache = pathCache.filter { seen.contains($0.key) }
        }

        return incidents
    }

    private func memoryIncident(pid: pid_t, path: String, sample s: ProcSample,
                                heldFor: TimeInterval, rate: Double, fillsIn: TimeInterval?,
                                pressure: HostMemory.Pressure, cause: String) -> Incident {
        var i = Incident(kind: .memory,
                         pid: pid, name: friendlyName(pid, path), path: path,
                         cpuPercent: 0, heatWeight: 0, ipc: 0,
                         heldFor: heldFor,
                         footprintMB: Double(s.footprint) / 1_048_576,
                         growthMBPerMin: rate)
        i.memoryShare = Double(s.footprint) / Double(HostMemory.physical)
        i.underPressure = pressure.isElevated
        i.swapUsedBytes = pressure.isElevated ? HostMemory.swapUsed() : 0
        i.fillsIn = fillsIn.flatMap { $0.isFinite ? $0 : nil }
        i.cause = cause
        return i
    }

    private func cachedPath(_ pid: pid_t) -> String {
        if let p = pathCache[pid] { return p }
        let p = execPath(pid)
        pathCache[pid] = p
        return p
    }

    /// Called when the user chooses "ignore this one" so we stop re-alerting.
    func suppress(pid: pid_t) {
        tracks[pid]?.alerted = true
        tracks[pid]?.overSince = nil
        tracks[pid]?.memAlerted = true
        tracks[pid]?.pressureAlerted = true
    }
}
