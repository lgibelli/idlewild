// SPDX-FileCopyrightText: 2026 Luca Gibelli
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// User-visible configuration, persisted in UserDefaults.
/// Backed entirely by UserDefaults, which is thread-safe, so this can be read
/// from the scan queue and written from the UI without additional locking.
final class AppSettings: @unchecked Sendable {
    private let d = UserDefaults.standard

    private enum K {
        static let threshold = "cpuThreshold"
        static let sustain = "sustainMinutes"
        static let calm = "calmInterval"
        static let allow = "allowList"
        static let notify = "notificationsEnabled"
        static let launchAtLogin = "launchAtLogin"
        static let checkUpdates = "checkForUpdates"
        static let cpu = "cpuEnabled"
        static let memory = "memoryEnabled"
        static let memoryShare = "memoryShareThreshold"
        static let memorySustain = "memorySustainMinutes"
        static let memoryFill = "memoryFillHours"
        static let colouredIcon = "colouredIcon"
        static let snoozed = "snoozedUntil"
    }

    init() {
        d.register(defaults: [
            K.threshold: 80.0,
            K.sustain: 5.0,
            K.calm: 120.0,
            K.notify: true,
            K.launchAtLogin: false,
            K.checkUpdates: true,
            K.cpu: true,
            K.memory: true,
            K.memoryShare: 50.0,
            K.memorySustain: 10.0,
            K.memoryFill: 12.0,
            K.colouredIcon: false,
            K.allow: Self.defaultAllowList,
        ])
    }

    /// Things that are *supposed* to peg a core. A watchdog that interrupts a
    /// video export gets uninstalled the same day.
    static let defaultAllowList = [
        "ffmpeg", "HandBrake", "clang", "swift-frontend", "rustc", "cargo",
        "Xcode.app", "Final Cut Pro.app", "Compressor.app", "Motion.app",
        "com.docker", "qemu", "VirtualBoxVM", "Blender", "DaVinci Resolve",
        "Logic Pro.app", "Adobe Premiere", "Adobe Media Encoder",
    ]

    var cpuThreshold: Double {
        get { d.double(forKey: K.threshold) } set { d.set(newValue, forKey: K.threshold) } }
    var sustainMinutes: Double {
        get { d.double(forKey: K.sustain) } set { d.set(newValue, forKey: K.sustain) } }
    var sustainSeconds: Double { sustainMinutes * 60 }
    var calmInterval: Double {
        get { max(d.double(forKey: K.calm), 15) } set { d.set(newValue, forKey: K.calm) } }
    var busyInterval: Double { max(calmInterval / 12, 5) }
    var notificationsEnabled: Bool {
        get { d.bool(forKey: K.notify) } set { d.set(newValue, forKey: K.notify) } }
    var launchAtLogin: Bool {
        get { d.bool(forKey: K.launchAtLogin) } set { d.set(newValue, forKey: K.launchAtLogin) } }
    var checkForUpdates: Bool {
        get { d.bool(forKey: K.checkUpdates) } set { d.set(newValue, forKey: K.checkUpdates) } }
    var cpuEnabled: Bool {
        get { d.bool(forKey: K.cpu) } set { d.set(newValue, forKey: K.cpu) } }
    var memoryEnabled: Bool {
        get { d.bool(forKey: K.memory) } set { d.set(newValue, forKey: K.memory) } }
    /// Percent of physical RAM a single process must hold before its memory use
    /// is worth mentioning. A share rather than an absolute figure, because
    /// 6 GB is fine on a 64 GB Studio and fatal on an 8 GB Air.
    var memoryShareThreshold: Double {
        get { d.double(forKey: K.memoryShare) } set { d.set(newValue, forKey: K.memoryShare) } }
    var memoryThresholdBytes: UInt64 { UInt64(Double(HostMemory.physical) * memoryShareThreshold / 100) }
    /// How long the footprint must have been climbing in a straight line. Leaks
    /// are slow and a fit needs points, so this is longer than the CPU window.
    var memorySustainMinutes: Double {
        get { d.double(forKey: K.memorySustain) } set { d.set(newValue, forKey: K.memorySustain) } }
    var memorySustainSeconds: Double { memorySustainMinutes * 60 }
    /// A leak is only an alarm if it will hurt soon: at the fitted rate, the
    /// process would use up the rest of physical memory within this many hours.
    /// A 16 GB process gaining 5 MB/min on a 64 GB machine fills it in a week,
    /// which is nobody's emergency.
    var memoryFillHours: Double {
        get { d.double(forKey: K.memoryFill) } set { d.set(newValue, forKey: K.memoryFill) } }
    /// Off by default: most people keep the menu bar monochrome, and an app whose
    /// job is not crying wolf should not be the one splash of colour up there.
    var colouredIcon: Bool {
        get { d.bool(forKey: K.colouredIcon) } set { d.set(newValue, forKey: K.colouredIcon) } }
    var allowList: [String] {
        get { d.stringArray(forKey: K.allow) ?? Self.defaultAllowList }
        set { d.set(newValue, forKey: K.allow) } }

    /// Entries are matched against whole path components, never as raw
    /// substrings of the full path. A substring match makes short entries
    /// catastrophic: "ld" (the linker) matches "/var/folders/..." because
    /// "folders" contains "ld", which silently allowlists most temp binaries.
    func isAllowed(path: String) -> Bool {
        guard !path.isEmpty else { return false }
        let components = path.components(separatedBy: "/").filter { !$0.isEmpty }
        return allowList.contains { entry in
            let e = entry.trimmingCharacters(in: .whitespaces)
            guard e.count >= 2 else { return false }
            // An entry containing a slash is an explicit path fragment.
            if e.contains("/") { return path.localizedCaseInsensitiveContains(e) }
            // Otherwise a component must equal it, or begin with it, so that
            // "Adobe Premiere" still matches "Adobe Premiere Pro 2024.app".
            return components.contains {
                $0.compare(e, options: .caseInsensitive) == .orderedSame
                    || $0.lowercased().hasPrefix(e.lowercased())
            }
        }
    }

    // MARK: - Temporary snoozes
    //
    // A path mapped to the epoch second it becomes reportable again. Distinct
    // from the allowlist, which is permanent and edited by hand: these expire on
    // their own, so a one-off nuisance never becomes a permanent blind spot.

    private var snoozes: [String: Double] {
        get { d.dictionary(forKey: K.snoozed) as? [String: Double] ?? [:] }
        set { d.set(newValue, forKey: K.snoozed) }
    }

    /// Identity for snoozing. The executable path rather than the display name,
    /// so "Safari web page" snoozes Safari's web content rather than anything
    /// that happens to render with the same friendly name.
    static func snoozeKey(path: String, name: String) -> String {
        path.isEmpty ? name : path
    }

    func snooze(path: String, name: String, until: Date) {
        var m = snoozes
        m[Self.snoozeKey(path: path, name: name)] = until.timeIntervalSince1970
        snoozes = m
    }

    func isSnoozed(path: String, name: String = "") -> Bool {
        let key = Self.snoozeKey(path: path, name: name)
        guard let until = snoozes[key] else { return false }
        if Date().timeIntervalSince1970 >= until {
            var m = snoozes; m.removeValue(forKey: key); snoozes = m   // expired
            return false
        }
        return true
    }

    /// Live snoozes, newest expiry last. Expired entries are pruned in passing.
    func activeSnoozes() -> [(key: String, until: Date)] {
        let now = Date().timeIntervalSince1970
        var m = snoozes
        let expired = m.filter { $0.value <= now }.map(\.key)
        if !expired.isEmpty { expired.forEach { m.removeValue(forKey: $0) }; snoozes = m }
        return m.map { (key: $0.key, until: Date(timeIntervalSince1970: $0.value)) }
                .sorted { $0.until < $1.until }
    }

    func clearSnooze(key: String) {
        var m = snoozes; m.removeValue(forKey: key); snoozes = m
    }

    func clearAllSnoozes() { snoozes = [:] }

    /// Local midnight, so "until tomorrow" means what a person means by it.
    static func nextMidnight(from now: Date = Date()) -> Date {
        let cal = Calendar.current
        return cal.nextDate(after: now, matching: DateComponents(hour: 0, minute: 0, second: 0),
                            matchingPolicy: .nextTime) ?? now.addingTimeInterval(24 * 3600)
    }

    func allow(path: String) {
        let name = (path as NSString).lastPathComponent
        guard !name.isEmpty, !allowList.contains(name) else { return }
        allowList = allowList + [name]
    }
}