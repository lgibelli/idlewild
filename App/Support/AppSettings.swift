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
    }

    init() {
        d.register(defaults: [
            K.threshold: 80.0,
            K.sustain: 5.0,
            K.calm: 120.0,
            K.notify: true,
            K.launchAtLogin: false,
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

    func allow(path: String) {
        let name = (path as NSString).lastPathComponent
        guard !name.isEmpty, !allowList.contains(name) else { return }
        allowList = allowList + [name]
    }
}