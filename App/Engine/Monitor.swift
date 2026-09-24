// SPDX-FileCopyrightText: 2026 Luca Gibelli
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Combine
import UserNotifications
import os

/// Owns the scan timer and turns detections into user-facing incidents.
/// Diagnostics go to the unified log, so an installed copy can be inspected
/// with:  log stream --predicate 'subsystem == "it.salamacchine.idlewild"'
let log = Logger(subsystem: "it.salamacchine.idlewild", category: "monitor")

@MainActor
final class Monitor: ObservableObject {

    // Published state drives the menu bar icon, so it must change only when the
    // icon does - roughly never. Publishing per-scan values here would
    // invalidate the label on every scan even with the menu closed, which is
    // exactly the always-redrawing menu bar item this app exists to catch.
    @Published private(set) var incidents: [Incident] = []
    @Published private(set) var isPaused = false
    /// Mirrors the setting so the label can read it without observing
    /// UserDefaults. Changes only when the user flips the switch.
    @Published private(set) var colouredIcon = false

    private(set) var lastScan: Date?
    private(set) var ownCPUms: Double = 0

    let settings = AppSettings()
    let updates: Updater
    /// Owned exclusively by `queue`. Every access - including from the UI -
    /// must go through `queue`, which is what makes the unchecked annotation
    /// safe. Detector holds mutable per-pid state, so touching it from the main
    /// actor while a scan is in flight would be a genuine data race.
    private let detector: Detector
    /// Where the CPU went, for the history window. Owned by `queue` exactly as
    /// the detector is.
    private let history = CPUHistory()
    private let queue = DispatchQueue(label: "it.salamacchine.idlewild.scan", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var pressureSource: DispatchSourceMemoryPressure?
    private var currentInterval: Double = 0
    /// The minute each incident's live duration last read, so the menu is
    /// republished when that changes and not otherwise. See refreshDurations.
    private var shownMinutes: [Int] = []
    private let started = Date()

    init() {
        updates = Updater(settings: settings)
        detector = Detector(settings: settings)
        AppDelegate.monitor = self      // so notification actions can reach us
        colouredIcon = settings.colouredIcon
        start()
    }

    func start() {
        isPaused = false
        schedule(interval: settings.calmInterval)
        watchPressure()
    }

    func pause() {
        isPaused = true
        timer?.cancel()
        timer = nil
        pressureSource?.cancel()
        pressureSource = nil
    }

    /// The kernel tells us when the machine starts swapping; we do not poll for
    /// it. This source costs nothing until it fires, and when it does the
    /// answer to "who is eating the memory" is wanted now, not in two minutes.
    private func watchPressure() {
        pressureSource?.cancel()
        let src = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: queue)
        src.setEventHandler { [weak self] in
            log.notice("memory pressure event")
            self?.tick()
        }
        src.resume()
        pressureSource = src
    }

    func togglePause() { isPaused ? start() : pause() }

    /// Cadence adapts: slow when the machine is calm, faster only while a
    /// suspect is building. Generous leeway lets the kernel coalesce our wakeup
    /// with others rather than waking the SoC on its own account.
    private func schedule(interval: Double) {
        timer?.cancel()
        currentInterval = interval
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: interval,
                   leeway: .milliseconds(Int(interval * 250)))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private nonisolated func tick() {
        let found = detector.scan()
        let suspect = detector.hasActiveSuspect
        let ongoing = detector.ongoing
        history.record(detector.takeUsage())

        // Diagnosis is expensive, so it happens here on the utility queue,
        // never on main, and only for confirmed CPU incidents. A stack sample
        // says nothing about a leak; memory incidents arrive already explained,
        // and a process about to be force quit by a rule needs no explaining.
        let enriched = found.map { inc -> Incident in
            guard inc.kind == .cpu, inc.autoQuit == nil else { return inc }
            var i = inc
            i.cause = Diagnoser.diagnose(pid: inc.pid,
                                        processName: (inc.path as NSString).lastPathComponent).cause
            return i
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            self.lastScan = Date()
            self.refreshOwnCost()
            self.resolve(keeping: ongoing)
            for i in enriched {
                if let rule = i.autoQuit {
                    self.autoQuit(i, rule)
                    continue
                }
                self.incidents.removeAll { $0.pid == i.pid }
                self.incidents.append(i)
                log.notice("incident: \(i.name, privacy: .public) pid \(i.pid) \(i.summary, privacy: .public) cause=\(i.cause, privacy: .public)")
                Notifier.post(incident: i, enabled: self.settings.notificationsEnabled)
            }
            let want = suspect ? self.settings.busyInterval : self.settings.calmInterval
            if want != self.currentInterval, !self.isPaused { self.schedule(interval: want) }
            self.refreshDurations()
        }
    }

    /// An incident is listed for as long as it is true, and no longer. Before
    /// this an incident stayed until somebody clicked it, and with the duration
    /// counting live a process that had exited at 23:32 was shown the next
    /// morning as "97% for 11.1 hours".
    private func resolve(keeping ongoing: Set<pid_t>) {
        let over = incidents.filter { !ongoing.contains($0.pid) }
        guard !over.isEmpty else { return }
        incidents.removeAll { !ongoing.contains($0.pid) }
        for i in over {
            log.notice("resolved: \(i.name, privacy: .public) pid \(i.pid) is no longer running away")
            Notifier.withdraw(pid: i.pid)
        }
    }

    /// Carries out an "Always Force Quit" rule. If the process cannot be
    /// stopped after all, the user is told the ordinary way, so a rule that
    /// fails never turns into silence.
    private func autoQuit(_ incident: Incident, _ rule: AutoQuitRule) {
        // Asked before the kill, while there is still a process to ask about.
        let reopen = rule.restart ? ProcessActions.appURL(pid: incident.pid) : nil
        switch ProcessActions.forceKill(pid: incident.pid) {
        case .ok:
            log.notice("force quit \(incident.name, privacy: .public) pid \(incident.pid) by rule, \(incident.summary, privacy: .public)")
            if let reopen { ProcessActions.reopen(reopen, after: incident.pid) }
            Notifier.postAutoQuit(incident: incident, reopened: reopen != nil,
                                  enabled: settings.notificationsEnabled)
        case .gone:
            break
        case .notPermitted, .failed:
            var i = incident
            i.autoQuit = nil
            i.cause = "Idlewild was set to force quit it, but the system would not let it"
            incidents.removeAll { $0.pid == i.pid }
            incidents.append(i)
            Notifier.post(incident: i, enabled: settings.notificationsEnabled)
        }
    }

    /// A CPU incident keeps burning after it is reported, and its duration is
    /// read live from the instant it crossed the threshold, so a menu opened
    /// twenty minutes in says twenty minutes. That change happens inside a value
    /// type, and SwiftUI is only told when published state changes, so send the
    /// notification by hand - once a minute at most, and only while an incident
    /// is on screen, which is well inside what this app spends looking anyway.
    private func refreshDurations() {
        guard !incidents.isEmpty else {
            shownMinutes.removeAll()
            return
        }
        let minutes = incidents.map { Int($0.heldFor / 60) }
        guard minutes != shownMinutes else { return }
        shownMinutes = minutes
        objectWillChange.send()
    }

    private func refreshOwnCost() {
        guard let s = sampleProc(getpid()) else { return }
        ownCPUms = Double(s.cpuNanos) / 1e6
    }

    /// Our own consumption, as a share of one core, since launch.
    var ownDutyCycle: Double {
        let alive = Date().timeIntervalSince(started)
        guard alive > 1 else { return 0 }
        return (ownCPUms / 1000) / alive * 100
    }

    // MARK: - Actions

    func dismiss(_ incident: Incident) {
        incidents.removeAll { $0.id == incident.id }
        Notifier.withdraw(pid: incident.pid)
        let pid = incident.pid
        queue.async { [detector] in detector.suppress(pid: pid) }
    }

    /// Stop reporting this process for a while. Unlike the allowlist this
    /// lapses on its own, so a nuisance dismissed once does not become a
    /// permanent blind spot.
    func snooze(_ incident: Incident, for interval: TimeInterval) {
        snooze(incident, until: Date().addingTimeInterval(interval))
    }

    func snooze(_ incident: Incident, until: Date) {
        settings.snooze(path: incident.path, name: incident.name, until: until)
        log.notice("snoozed \(incident.name, privacy: .public) until \(until, privacy: .public)")
        dismiss(incident)
    }

    func snoozeUntilTomorrow(_ incident: Incident) {
        snooze(incident, until: AppSettings.nextMidnight())
    }

    func alwaysAllow(_ incident: Incident) {
        settings.allow(path: incident.path)
        dismiss(incident)
    }

    /// From now on this program is stopped instead of reported, the run that
    /// prompted the rule included.
    func alwaysForceQuit(_ incident: Incident, rule: AutoQuitRule) {
        settings.setAutoQuit(path: incident.path, rule: rule)
        log.notice("always force quit \(incident.path, privacy: .public) \(rule.waitText, privacy: .public)")
        incidents.removeAll { $0.id == incident.id }
        Notifier.withdraw(pid: incident.pid)
        let pid = incident.pid
        queue.async { [detector] in detector.rearm(pid: pid) }
    }

    // MARK: - History

    func historySnapshot() async -> HistoryData {
        await withCheckedContinuation { c in
            queue.async { [history] in c.resume(returning: history.snapshot()) }
        }
    }

    func clearHistory() {
        queue.async { [history] in history.clear() }
    }

    /// Called as the app quits, so the last quarter of an hour is kept.
    func saveHistory() {
        queue.sync { history.save() }
    }

    /// Settings changed while a scan may be running; hand the new values over on
    /// the queue that owns the detector.
    func settingsChanged() {
        let s = settings
        queue.async { [detector] in detector.settings = s }
        if colouredIcon != settings.colouredIcon { colouredIcon = settings.colouredIcon }
        if !isPaused { schedule(interval: settings.calmInterval) }
    }

    @discardableResult
    func kill(_ incident: Incident) -> ProcessActions.Result {
        let r = ProcessActions.forceKill(pid: incident.pid)
        if case .ok = r { dismiss(incident) }
        if case .gone = r { dismiss(incident) }
        return r
    }

    @discardableResult
    func suspend(_ incident: Incident) -> ProcessActions.Result {
        let r = ProcessActions.suspend(pid: incident.pid)
        if case .ok = r { dismiss(incident) }
        return r
    }

    func rescan() { queue.async { [weak self] in self?.tick() } }
}