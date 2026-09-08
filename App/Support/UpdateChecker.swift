// SPDX-FileCopyrightText: 2026 Luca Gibelli
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import AppKit
import os

private let ulog = Logger(subsystem: "it.salamacchine.idlewild", category: "update")

/// What the feed publishes.
struct UpdateInfo: Decodable, Equatable {
    let version: String
    let url: String
    let notes: String?
    let minimumSystemVersion: String?
}

/// Checks a small JSON feed for a newer release and reports it in the menu.
///
/// Deliberately does not download or install anything. Sparkle-style updaters
/// fetch and execute code, which means the feed becomes a way to run arbitrary
/// software on the user's machine and has to be signed and verified to be safe.
/// Idlewild only ever tells the user a version exists and opens the download
/// page; macOS then applies Gatekeeper to whatever they choose to run, which is
/// the same protection a fresh download gets.
@MainActor
final class UpdateChecker: ObservableObject {

    @Published private(set) var available: UpdateInfo?
    @Published private(set) var lastCheck: Date?
    @Published private(set) var lastError: String?

    static let feedURL = URL(string: "https://www.salamacchine.it/apps/idlewild/latest.json")!
    private static let interval: TimeInterval = 24 * 60 * 60
    private static let lastCheckKey = "lastUpdateCheck"

    private let settings: AppSettings
    private var timer: Timer?

    init(settings: AppSettings) {
        self.settings = settings
        let stored = UserDefaults.standard.double(forKey: Self.lastCheckKey)
        if stored > 0 { lastCheck = Date(timeIntervalSince1970: stored) }
        start()
    }

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    private func start() {
        guard settings.checkForUpdates else { return }
        // A daily check, deferred so it never competes with launch. Generous
        // tolerance lets the system batch the wake-up with other work.
        let t = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkIfDue() }
        }
        t.tolerance = 60 * 60
        RunLoop.main.add(t, forMode: .common)
        timer = t

        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            self?.checkIfDue()
        }
    }

    func settingsChanged() {
        timer?.invalidate()
        timer = nil
        if settings.checkForUpdates { start() } else { available = nil }
    }

    private func checkIfDue() {
        guard settings.checkForUpdates else { return }
        if let last = lastCheck, Date().timeIntervalSince(last) < Self.interval { return }
        check()
    }

    /// `manual` skips the interval check and reports "you are up to date".
    func check(manual: Bool = false) {
        Task { [weak self] in
            guard let self else { return }
            do {
                var request = URLRequest(url: Self.feedURL)
                request.timeoutInterval = 15
                request.setValue("Idlewild/\(self.currentVersion)", forHTTPHeaderField: "User-Agent")
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    throw URLError(.badServerResponse)
                }
                let info = try JSONDecoder().decode(UpdateInfo.self, from: data)
                self.apply(info, manual: manual)
            } catch {
                self.lastError = error.localizedDescription
                ulog.error("update check failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func apply(_ info: UpdateInfo, manual: Bool) {
        lastCheck = Date()
        lastError = nil
        UserDefaults.standard.set(lastCheck!.timeIntervalSince1970, forKey: Self.lastCheckKey)

        // Only ever open an https URL on the expected host: a compromised or
        // mistyped feed must not be able to point the user anywhere else.
        guard let u = URL(string: info.url),
              u.scheme == "https",
              u.host?.hasSuffix("salamacchine.it") == true
                || u.host?.hasSuffix("github.com") == true else {
            ulog.error("update feed proposed an unacceptable URL; ignoring")
            return
        }

        if Self.isNewer(info.version, than: currentVersion) {
            available = info
            ulog.notice("update available: \(info.version, privacy: .public)")
        } else {
            available = nil
            if manual { ulog.notice("already up to date") }
        }
    }

    func openDownloadPage() {
        guard let info = available, let u = URL(string: info.url) else { return }
        NSWorkspace.shared.open(u)
    }

    /// Numeric component comparison, so 1.10.0 sorts above 1.9.0.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.split(whereSeparator: { !$0.isNumber }).map { Int($0) ?? 0 }
        }
        let a = parts(candidate), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
