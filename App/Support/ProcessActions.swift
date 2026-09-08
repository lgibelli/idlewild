// SPDX-FileCopyrightText: 2026 Luca Gibelli
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Darwin

/// The two things a user actually wants to do about a runaway process.
enum ProcessActions {

    enum Result { case ok, notPermitted, gone, failed(Int32) }

    /// SIGTERM first so the process can clean up; the caller may escalate.
    static func quit(pid: pid_t) -> Result { send(SIGTERM, to: pid) }
    static func forceKill(pid: pid_t) -> Result { send(SIGKILL, to: pid) }

    /// Suspend rather than kill. The process stops burning CPU but keeps its
    /// state, so a stuck page can be resumed instead of losing the tab. This is
    /// the same mechanism App Tamer uses to throttle.
    static func suspend(pid: pid_t) -> Result { send(SIGSTOP, to: pid) }
    static func resume(pid: pid_t) -> Result { send(SIGCONT, to: pid) }

    static func isSuspended(pid: pid_t) -> Bool {
        var info = proc_bsdinfo()
        let sz = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sz) == sz else { return false }
        return info.pbi_status == UInt32(SSTOP)
    }

    static func isAlive(pid: pid_t) -> Bool { kill(pid, 0) == 0 || errno == EPERM }

    private static func send(_ sig: Int32, to pid: pid_t) -> Result {
        guard pid > 1 else { return .failed(EINVAL) }   // never signal launchd
        if kill(pid, sig) == 0 { return .ok }
        switch errno {
        case EPERM:  return .notPermitted
        case ESRCH:  return .gone
        default:     return .failed(errno)
        }
    }
}