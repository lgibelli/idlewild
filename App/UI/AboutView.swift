// SPDX-FileCopyrightText: 2026 Luca Gibelli
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// The About window, opened from the menu. It lives outside Settings because
/// it is not a setting: it is where the app accounts for its own cost.
struct AboutView: View {
    @ObservedObject var monitor: Monitor
    @State private var duty: Double = 0
    @State private var cpuMs: Double = 0

    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "Version \(v) (\(b))"
    }

    @ViewBuilder
    private var updates: some View {
        if let u = monitor.updates.available {
            VStack(spacing: 4) {
                Text("Version \(u.version) is available")
                    .font(.caption.bold()).foregroundStyle(.orange)
                Button("Download\u{2026}") { monitor.updates.openDownloadPage() }
                    .controlSize(.small)
            }
        } else {
            HStack(spacing: 10) {
                Text(monitor.settings.checkForUpdates ? "Idlewild is up to date" : "Update checks are off")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Check Now") { monitor.updates.check(manual: true) }
                    .controlSize(.small)
            }
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            Spacer(minLength: 0)

            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 76, height: 76)
            }
            Text("Idlewild").font(.title2.bold())
            Text(version).font(.caption).foregroundStyle(.secondary)

            Text("Notices when a process runs away, works out why, and offers to stop it.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 40)
                .padding(.top, 2)

            // A watchdog should be accountable to the standard it enforces.
            GroupBox {
                HStack(spacing: 0) {
                    Stat(value: String(format: "%.0f ms", cpuMs), label: "CPU used since launch")
                    Divider().frame(height: 32)
                    Stat(value: String(format: "%.4f%%", duty), label: "of one core")
                }
                .padding(.vertical, 6)
            }
            .padding(.horizontal, 30)

            Text("For comparison, a typical menu bar CPU meter costs about 3.6%.")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            Divider().padding(.vertical, 2)

            updates

            Text("Copyright \u{00A9} 2026 Luca Gibelli")
                .font(.caption).foregroundStyle(.secondary)
            Text("Released under the GNU General Public License, version 3 or later. Idlewild comes with absolutely no warranty. You are free to change it and redistribute it under the same licence.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 24)
            HStack(spacing: 14) {
                Link("Licence", destination: URL(string: "https://www.gnu.org/licenses/gpl-3.0.html")!)
                Link("Source", destination: URL(string: "https://github.com/lgibelli/idlewild")!)
            }
            .font(.caption)

            Spacer(minLength: 0)
        }
        .frame(width: 520, height: 470)
        .padding(20)
        .onAppear {
            duty = monitor.ownDutyCycle
            cpuMs = monitor.ownCPUms
        }
    }
}

private struct Stat: View {
    let value: String
    let label: String
    var body: some View {
        VStack(spacing: 3) {
            Text(value).font(.title3.monospacedDigit().weight(.medium))
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}