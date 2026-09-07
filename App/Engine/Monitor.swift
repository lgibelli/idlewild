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

    // Published so the menu shows current values. Under .menuBarExtraStyle(.menu)
    // the menu content is only materialised when opened, so publishing this
    // invalidates just the tiny label view rather than a whole view hierarchy -
    // measured at no meaningful cost. It was expensive under .window style.
    @Published private(set) var topProcesses: [(pid: pid_t, name: String, pct: Double)] = []
    private(set) var lastScan: Date?
    private(set) var ownCPUms: Double = 0

    let settings = AppSettings()
    /// Owned exclusively by `queue`. Every access - including from the UI -
    /// must go through `queue`, which is what makes the unchecked annotation
    /// safe. Detector holds mutable per-pid state, so touching it from the main
    /// actor while a scan is in flight would be a genuine data race.
    private let detector: Detector
    private let queue = DispatchQueue(label: "it.salamacchine.idlewild.scan", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var currentInterval: Double = 0
    private let started = Date()

    init() {
        detector = Detector(settings: settings)
        AppDelegate.monitor = self      // so notification actions can reach us
        start()
    }

    func start() {
        isPaused = false
        schedule(interval: settings.calmInterval)
    }

    func pause() {
        isPaused = true
        timer?.cancel()
        timer = nil
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
        let top = detector.topProcesses
        let suspect = detector.hasActiveSuspect

        // Diagnosis is expensive, so it happens here on the utility queue,
        // never on main, and only for confirmed incidents.
        let enriched = found.map { inc -> Incident in
            var i = inc
            i.cause = Diagnoser.diagnose(pid: inc.pid,
                                        processName: (inc.path as NSString).lastPathComponent).cause
            return i
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            self.topProcesses = top
            self.lastScan = Date()
            self.refreshOwnCost()
            for i in enriched {
                self.incidents.removeAll { $0.pid == i.pid }
                self.incidents.append(i)
                log.notice("incident: \(i.name, privacy: .public) pid \(i.pid) \(i.cpuPercent, format: .fixed(precision: 0))% cause=\(i.cause, privacy: .public)")
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

    func alwaysAllow(_ incident: Incident) {
        settings.allow(path: incident.path)
        dismiss(incident)
    }

    /// Settings changed while a scan may be running; hand the new values over on
    /// the queue that owns the detector.
    func settingsChanged() {
        let s = settings
        queue.async { [detector] in detector.settings = s }
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
