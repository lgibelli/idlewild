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
    let updates: UpdateChecker
    /// Owned exclusively by `queue`. Every access - including from the UI -
    /// must go through `queue`, which is what makes the unchecked annotation
    /// safe. Detector holds mutable per-pid state, so touching it from the main
    /// actor while a scan is in flight would be a genuine data race.
    private let detector: Detector
    private let queue = DispatchQueue(label: "it.salamacchine.idlewild.scan", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var pressureSource: DispatchSourceMemoryPressure?
    private var currentInterval: Double = 0
    private let started = Date()

    init() {
        updates = UpdateChecker(settings: settings)
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

        // Diagnosis is expensive, so it happens here on the utility queue,
        // never on main, and only for confirmed CPU incidents. A stack sample
        // says nothing about a leak; memory incidents arrive already explained.
        let enriched = found.map { inc -> Incident in
            guard inc.kind == .cpu else { return inc }
            var i = inc
            i.cause = Diagnoser.diagnose(pid: inc.pid,
                                        processName: (inc.path as NSString).lastPathComponent).cause
            return i
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            self.lastScan = Date()
            self.refreshOwnCost()
            for i in enriched {
                self.incidents.removeAll { $0.pid == i.pid }
                self.incidents.append(i)
                log.notice("incident: \(i.name, privacy: .public) pid \(i.pid) \(i.summary, privacy: .public) cause=\(i.cause, privacy: .public)")
                Notifier.post(incident: i, enabled: self.settings.notificationsEnabled)
            }
            let want = suspect ? self.settings.busyInterval : self.settings.calmInterval
            if want != self.currentInterval, !self.isPaused { self.schedule(interval: want) }
        }
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

    /// Settings changed while a scan may be running; hand the new values over on
    /// the queue that owns the detector.
    func settingsChanged() {
        let s = settings
        queue.async { [detector] in detector.settings = s }
        updates.settingsChanged()
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