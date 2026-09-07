import Foundation

struct Incident: Identifiable, Equatable {
    let id = UUID()
    let pid: pid_t
    let name: String
    let path: String
    let cpuPercent: Double
    let heatWeight: Double      // 0...1, share of time on performance cores
    let ipc: Double
    let heldFor: TimeInterval
    let footprintMB: Double
    let growthMBPerMin: Double
    var cause: String = ""

    static func == (a: Incident, b: Incident) -> Bool { a.id == b.id }

    /// Memory climbing steadily while CPU is pinned is strong evidence of a
    /// runaway loop rather than honest work.
    var isLeaking: Bool { growthMBPerMin > 1.0 }

    var summary: String {
        var s = String(format: "%.0f%% CPU for %@", cpuPercent, formatDuration(heldFor))
        if isLeaking { s += String(format: ", memory +%.0f MB/min", growthMBPerMin) }
        return s
    }

    /// Compact enough for a single menu item title.
    var menuSummary: String {
        String(format: "%.0f%% for %@", cpuPercent, formatDuration(heldFor))
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

private struct Track {
    var startAbs: UInt64
    var lastCPU: UInt64
    var lastFootprint: UInt64
    var overSince: Date?
    var footprintAtCross: UInt64
    var alerted = false
    var lastPercent: Double = 0
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

    var settings: AppSettings

    init(settings: AppSettings) { self.settings = settings }

    var hasActiveSuspect: Bool { tracks.values.contains { $0.overSince != nil } }

    /// Top consumers right now, for the menu. Uses values already gathered by the
    /// last scan, so opening the menu costs nothing.
    private(set) var topProcesses: [(pid: pid_t, name: String, pct: Double)] = []

    func scan(syntheticDt: Double? = nil) -> [Incident] {
        let now = Date()
        let dt = syntheticDt ?? now.timeIntervalSince(lastScan)
        lastScan = now
        guard dt > 0.05 else { return [] }

        var incidents: [Incident] = []
        var seen = Set<pid_t>()
        var top: [(pid_t, Double, UInt64)] = []

        for pid in lister.list() {
            guard pid > 0, let s = sampleProc(pid) else { continue }
            seen.insert(pid)

            guard var t = tracks[pid], t.startAbs == s.startAbs else {
                tracks[pid] = Track(startAbs: s.startAbs, lastCPU: s.cpuNanos,
                                    lastFootprint: s.footprint, overSince: nil,
                                    footprintAtCross: s.footprint)
                continue
            }

            let pct = (Double(s.cpuNanos &- t.lastCPU) / 1e9) / dt * 100.0
            t.lastCPU = s.cpuNanos
            t.lastFootprint = s.footprint
            t.lastPercent = pct
            if pct > 1 { top.append((pid, pct, s.footprint)) }

            if pct >= settings.cpuThreshold && pid != selfPID {
                if t.overSince == nil { t.overSince = now; t.footprintAtCross = s.footprint }
                let held = now.timeIntervalSince(t.overSince!)
                if held >= settings.sustainSeconds && !t.alerted {
                    t.alerted = true
                    let path = cachedPath(pid)
                    if !settings.isAllowed(path: path) {
                        let grownMB = Double(Int64(s.footprint) - Int64(t.footprintAtCross)) / 1_048_576
                        incidents.append(Incident(
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
            tracks[pid] = t
        }

        if tracks.count > seen.count {
            tracks = tracks.filter { seen.contains($0.key) }
            pathCache = pathCache.filter { seen.contains($0.key) }
        }

        top.sort { $0.1 > $1.1 }
        topProcesses = top.prefix(5).map { (pid: $0.0, name: friendlyName($0.0, cachedPath($0.0)), pct: $0.1) }
        return incidents
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
    }
}
