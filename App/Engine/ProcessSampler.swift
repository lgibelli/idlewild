// SPDX-FileCopyrightText: 2026 Luca Gibelli
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Darwin

// Apple Silicon only. proc_pid_rusage reports CPU time in mach absolute time
// units; the timebase is a property of the machine, so we query it once at
// startup rather than hardcoding the (currently 125/3) ratio.
let machTimebase: (numer: UInt64, denom: UInt64) = {
    var tb = mach_timebase_info_data_t()
    mach_timebase_info(&tb)
    return (UInt64(tb.numer), UInt64(tb.denom))
}()

@inline(__always)
func absToNanos(_ v: UInt64) -> UInt64 { v &* machTimebase.numer / machTimebase.denom }

/// Where a process's CPU time was spent. On Apple Silicon this predicts heat far
/// better than raw CPU%: user-interactive work runs on P-cores at high clock,
/// while background work parks on E-cores and barely warms the die.
struct QoSMix {
    let performance: UInt64   // user_interactive + user_initiated -> P-cores
    let efficiency: UInt64    // utility + background + maintenance -> E-cores
    let unspecified: UInt64   // default + legacy

    var total: UInt64 { performance &+ efficiency &+ unspecified }

    /// 0...1. How thermally expensive this process's CPU time actually is.
    var heatWeight: Double {
        let t = total
        guard t > 0 else { return 0.5 }
        return (Double(performance) + 0.5 * Double(unspecified)) / Double(t)
    }
}

struct ProcSample {
    let pid: pid_t
    let cpuNanos: UInt64
    let footprint: UInt64
    let startAbs: UInt64
    let qos: QoSMix
    let instructions: UInt64
    let cycles: UInt64
    /// Cumulative page-ins. A rising rate means the process is actively being
    /// paged back in, i.e. the machine is swapping on its behalf.
    let pageins: UInt64

    /// High IPC alongside pinned CPU means a tight in-cache loop - the signature
    /// of a spin. Low IPC means memory stalls, more often genuine work.
    var ipc: Double { cycles > 0 ? Double(instructions) / Double(cycles) : 0 }
}

@inline(__always)
func sampleProc(_ pid: pid_t) -> ProcSample? {
    var i = rusage_info_v4()
    let rc = withUnsafeMutablePointer(to: &i) { p -> Int32 in
        p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
            proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
        }
    }
    guard rc == 0 else { return nil }
    let qos = QoSMix(
        performance: i.ri_cpu_time_qos_user_interactive &+ i.ri_cpu_time_qos_user_initiated,
        efficiency:  i.ri_cpu_time_qos_utility &+ i.ri_cpu_time_qos_background
                     &+ i.ri_cpu_time_qos_maintenance,
        unspecified: i.ri_cpu_time_qos_default &+ i.ri_cpu_time_qos_legacy)
    return ProcSample(pid: pid,
                      cpuNanos: absToNanos(i.ri_user_time &+ i.ri_system_time),
                      footprint: i.ri_phys_footprint,
                      startAbs: i.ri_proc_start_abstime,
                      qos: qos,
                      instructions: i.ri_instructions,
                      cycles: i.ri_cycles,
                      pageins: i.ri_pageins)
}

/// Whole-machine memory facts. Physical size never changes; the other two are
/// one sysctl each, cheaper than a single proc_pid_rusage call, and readable
/// without privilege.
///
/// Virtual size is deliberately absent. On macOS every process maps the shared
/// cache and reserves address space, so even TextEdit reports hundreds of
/// gigabytes; the number carries no information. Physical footprint - what
/// Activity Monitor calls "Memory" - and system-wide pressure are what matter.
enum HostMemory {
    static let physical: UInt64 = {
        var v: UInt64 = 0
        var sz = MemoryLayout<UInt64>.size
        return sysctlbyname("hw.memsize", &v, &sz, nil, 0) == 0 && v > 0 ? v : 8 << 30
    }()

    enum Pressure: Int32, Comparable {
        case unknown = 0, normal = 1, warning = 2, critical = 4
        static func < (a: Pressure, b: Pressure) -> Bool { a.rawValue < b.rawValue }
        var isElevated: Bool { self >= .warning }
    }

    /// The kernel's own verdict, the same one that drives the memory pressure
    /// dispatch source and Activity Monitor's pressure graph.
    static func pressure() -> Pressure {
        var v: Int32 = 0
        var sz = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &v, &sz, nil, 0) == 0 else {
            return .unknown
        }
        return Pressure(rawValue: v) ?? .unknown
    }

    static func swapUsed() -> UInt64 {
        var sw = xsw_usage()
        var sz = MemoryLayout<xsw_usage>.size
        return sysctlbyname("vm.swapusage", &sw, &sz, nil, 0) == 0 ? sw.xsu_used : 0
    }
}

/// Whole-machine CPU time, for the part of the history no process accounts
/// for. A third of the processes on a Mac belong to root or to system users,
/// and proc_pid_rusage refuses to measure them for us, as it refuses the
/// kernel; the host counters include everything, so the difference between the
/// two is what macOS kept to itself.
enum HostCPU {
    static let cores: Int = {
        var n: Int32 = 0
        var sz = MemoryLayout<Int32>.size
        return sysctlbyname("hw.logicalcpu", &n, &sz, nil, 0) == 0 && n > 0 ? Int(n) : 1
    }()

    static let ticksPerSecond = Double(max(sysconf(Int32(_SC_CLK_TCK)), 1))

    /// Ticks every core has spent in user, system and nice since boot. Each is
    /// a 32-bit counter that wraps after a few weeks of load, so callers keep
    /// the three apart and subtract with wrapping arithmetic.
    typealias Ticks = (user: UInt32, system: UInt32, nice: UInt32)

    static func busyTicks() -> Ticks? {
        var load = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &load) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        let t = load.cpu_ticks
        return (UInt32(t.0), UInt32(t.1), UInt32(t.3))
    }

    /// CPU-seconds, summed over every core, used between two readings.
    static func seconds(from a: Ticks, to b: Ticks) -> Double {
        let ticks = UInt64(b.user &- a.user) + UInt64(b.system &- a.system) + UInt64(b.nice &- a.nice)
        return Double(ticks) / ticksPerSecond
    }
}

/// Where the history files a process's CPU time: under the app it belongs to,
/// so a browser's forty helpers add up to the browser, or under its own name
/// when it is not part of an app. Nil when there is nothing to call it.
func accountName(_ pid: pid_t, _ path: String) -> String? {
    // WebKit's processes live in the system framework, not in any app, and
    // serve Safari and every other app showing web content.
    if path.contains("com.apple.WebKit.") { return "Safari & WebKit" }
    // The outermost bundle: ".../Google Chrome.app/.../Helper (Renderer).app/..."
    // belongs to Google Chrome.
    if let r = path.range(of: ".app/") {
        let app = (String(path[..<r.lowerBound]) as NSString).lastPathComponent
        // Safari's own process and its web pages are one thing to a user.
        if app == "Safari" { return "Safari & WebKit" }
        if !app.isEmpty { return app }
    }
    let n = path.isEmpty ? procName(pid) : displayName(pid, path)
    return n.isEmpty ? nil : n
}

func formatBytes(_ b: UInt64) -> String {
    let mb = Double(b) / 1_048_576
    return mb < 1000 ? String(format: "%.0f MB", mb) : String(format: "%.1f GB", mb / 1024)
}

/// Reuses its buffer so a scan allocates nothing on the hot path.
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
            buf = [pid_t](repeating: 0, count: buf.count * 2)
        }
    }
}

func execPath(_ pid: pid_t) -> String {
    var buf = [CChar](repeating: 0, count: 4096)
    return proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : ""
}

func procName(_ pid: pid_t) -> String {
    var buf = [CChar](repeating: 0, count: 256)
    return proc_name(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : ""
}

/// Basenames are usually right, but some binaries live in versioned directories
/// (".../2.1.263/toolname") where the basename is a version string.
func displayName(_ pid: pid_t, _ path: String) -> String {
    let base = (path as NSString).lastPathComponent
    if base.isEmpty || isVersion(base) {
        let n = procName(pid)
        if !n.isEmpty && !isVersion(n) { return n }
        // Some tools are named after their own version, ".../claude/versions/
        // 2.1.281", and the kernel's name for them is the same number. The
        // program is whatever owns the versions directory.
        if let owner = versionOwner(path) { return owner }
        if !n.isEmpty { return n }
    }
    return base.isEmpty ? "pid \(pid)" : base
}

private func isVersion(_ s: String) -> Bool {
    !s.isEmpty && s.allSatisfy { $0.isNumber || $0 == "." }
}

private func versionOwner(_ path: String) -> String? {
    let generic: Set<String> = ["versions", "version", "releases", "current", "bin", "libexec"]
    return path.split(separator: "/").reversed().map(String.init)
        .first { !isVersion($0) && !generic.contains($0.lowercased()) }
}

/// "com.apple.WebKit.WebContent" means nothing to a user. We cannot get the tab
/// title without private API, but we can say which app it belongs to.
func friendlyName(_ pid: pid_t, _ path: String) -> String {
    let n = displayName(pid, path)
    if n.contains("WebKit.WebContent") || n.contains("Web Content") { return "Safari web page" }
    if n.hasSuffix("Helper (Renderer)") {
        if let app = path.components(separatedBy: "/").first(where: { $0.hasSuffix(".app") }) {
            return app.replacingOccurrences(of: ".app", with: "") + " tab"
        }
        return "Browser tab"
    }
    return n
}