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
                      cycles: i.ri_cycles)
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
    if base.isEmpty || base.allSatisfy({ $0.isNumber || $0 == "." }) {
        let n = procName(pid)
        if !n.isEmpty { return n }
    }
    return base.isEmpty ? "pid \(pid)" : base
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