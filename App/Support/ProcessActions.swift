// SPDX-FileCopyrightText: 2026 Luca Gibelli
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import AppKit
import Darwin

/// The things a user actually wants to do about a runaway process.
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

    /// Whether a signal from us would land. A process belonging to another user
    /// cannot be stopped, so a rule to stop it every time would be a promise
    /// Idlewild could never keep.
    static func canSignal(pid: pid_t) -> Bool { kill(pid, 0) == 0 || errno == ESRCH }

    // MARK: - Starting it again

    /// What "open it again afterwards" can mean for a given process. Only an
    /// app can honestly be reopened: it is self-contained and LaunchServices
    /// knows how to start it. Anything else was started by something with its
    /// own arguments, environment and reasons, and restarting it without them
    /// would be guessing.
    enum Restart {
        case app(URL)
        /// Why not, as a sentence for the prompt.
        case unavailable(String)
    }

    @MainActor
    static func restart(for pid: pid_t, name: String) -> Restart {
        // An app's own helpers are apps too as far as LaunchServices is
        // concerned, but reopening one would start a helper with no parent;
        // the parent app starts its helpers by itself.
        if let app = NSRunningApplication(processIdentifier: pid),
           app.activationPolicy != .prohibited, let url = app.bundleURL {
            return .app(url)
        }
        let parent = parentPID(pid)
        if parent == 1 {
            return .unavailable("macOS starts \(name) again by itself when it next needs it.")
        }
        if let parent, parent > 1 {
            let who = procName(parent)
            if !who.isEmpty {
                return .unavailable("\(name) was started by \(who), so only \(who) can start it again.")
            }
        }
        return .unavailable("Idlewild cannot tell what started \(name), so it will not start it again.")
    }

    /// Asked before the kill, while there is still a process to ask about.
    @MainActor
    static func appURL(pid: pid_t) -> URL? {
        if case .app(let url) = restart(for: pid, name: "") { return url }
        return nil
    }

    /// Reopens the app once the killed copy has actually gone - opening it while
    /// the old process is still being torn down would only bring that one
    /// forward. Without activating it: it was not the user who asked.
    @MainActor
    static func reopen(_ url: URL, after pid: pid_t) {
        Task { @MainActor in
            var waited = 0
            while isAlive(pid: pid), waited < 50 {
                try? await Task.sleep(for: .milliseconds(100))
                waited += 1
            }
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = false
            NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, error in
                if let error {
                    log.error("could not reopen \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    private static func parentPID(_ pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let sz = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sz) == sz else { return nil }
        return pid_t(info.pbi_ppid)
    }

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