// SPDX-FileCopyrightText: 2026 Luca Gibelli
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import ServiceManagement

// Panes are laid out with GroupBox rather than Form. `.formStyle(.grouped)`
// looks right but wraps its content in an implicit ScrollView, so the settings
// scrolled - and settings this small should never scroll.

struct SettingsView: View {
    @ObservedObject var monitor: Monitor

    var body: some View {
        TabView {
            DetectionPane(monitor: monitor)
                .tabItem { Label("Detection", systemImage: "gauge.with.dots.needle.33percent") }
            ExceptionsPane(monitor: monitor)
                .tabItem { Label("Exceptions", systemImage: "checkmark.shield") }
            AboutPane(monitor: monitor)
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 560, height: 452)
    }
}

// MARK: - Detection

private struct DetectionPane: View {
    @ObservedObject var monitor: Monitor
    @State private var threshold: Double = 80
    @State private var sustain: Double = 5
    @State private var interval: Double = 120
    @State private var notify = true
    @State private var launchAtLogin = false
    @State private var loginError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            summary

            GroupBox {
                VStack(spacing: 14) {
                    SliderRow(title: "CPU threshold",
                              value: $threshold, range: 30...200, step: 5,
                              display: "\(Int(threshold))%",
                              hint: "of one core") { save() }
                    Divider()
                    SliderRow(title: "Held for",
                              value: $sustain, range: 1...30, step: 1,
                              display: "\(Int(sustain)) min",
                              hint: "before alerting") { save() }
                    Divider()
                    SliderRow(title: "Check every",
                              value: $interval, range: 30...300, step: 15,
                              display: "\(Int(interval))s",
                              hint: "when calm") { save() }
                }
                .padding(.vertical, 4)
            }

            GroupBox {
                VStack(spacing: 10) {
                    Toggle(isOn: $notify) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Show notifications")
                            Text("The menu bar icon changes either way.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .onChange(of: notify) { _, _ in save() }

                    Divider()

                    Toggle(isOn: $launchAtLogin) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Launch at login")
                            Text("A watchdog you have to remember to start is not much of a watchdog.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .onChange(of: launchAtLogin) { _, v in setLogin(v) }
                }
                // macOS renders Toggle as a checkbox inside a form-like layout
                // unless the switch style is requested explicitly.
                .toggleStyle(.switch)
                .padding(.vertical, 4)
            }

            if let loginError {
                Label(loginError, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }

            Spacer(minLength: 0)
        }
        .padding(20)
        .onAppear(perform: load)
    }

    /// Reads as a sentence and updates live, which removes the need for a
    /// paragraph of explanation under every control.
    private var summary: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "text.bubble")
                .foregroundStyle(.secondary)
                .font(.system(size: 13))
                .padding(.top, 1)
            // Markdown rather than Text concatenation, which is deprecated.
            Text(summaryText).foregroundStyle(.secondary)
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
    }

    private var summaryText: AttributedString {
        let mins = Int(sustain)
        let md = "Alert me when a process holds above **\(Int(threshold))%** of one core "
               + "for **\(mins) minute\(mins == 1 ? "" : "s")**."
        return (try? AttributedString(markdown: md)) ?? AttributedString(md)
    }

    private func load() {
        threshold = monitor.settings.cpuThreshold
        sustain = monitor.settings.sustainMinutes
        interval = monitor.settings.calmInterval
        notify = monitor.settings.notificationsEnabled
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func save() {
        monitor.settings.cpuThreshold = threshold
        monitor.settings.sustainMinutes = sustain
        monitor.settings.calmInterval = interval
        monitor.settings.notificationsEnabled = notify
        monitor.settingsChanged()
    }

    private func setLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() }
            else  { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = "Could not change login item: \(error.localizedDescription)"
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

private struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let display: String
    let hint: String
    let onCommit: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .frame(width: 108, alignment: .leading)
            Slider(value: $value, in: range, step: step) { editing in
                if !editing { onCommit() }
            }
            HStack(spacing: 4) {
                Text(display)
                    .monospacedDigit()
                    .fontWeight(.medium)
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 116, alignment: .leading)
        }
    }
}

// MARK: - Exceptions

private struct ExceptionsPane: View {
    @ObservedObject var monitor: Monitor
    @State private var entries: [String] = []
    @State private var selection: Set<String> = []
    @State private var newEntry = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Never alert about these")
                .font(.headline)
            Text("Matched against whole path components, so \"ffmpeg\" or \"Final Cut Pro.app\" is enough. A build that pegs a core for a minute is normal; these are the things that do it legitimately for hours.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            List(selection: $selection) {
                ForEach(entries, id: \.self) { e in
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.shield.fill")
                            .foregroundStyle(.green.opacity(0.8))
                            .font(.caption)
                        Text(e)
                    }
                    .tag(e)
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            .frame(maxHeight: .infinity)

            HStack(spacing: 8) {
                TextField("Add an app or binary name", text: $newEntry)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                Button(action: add) { Image(systemName: "plus") }
                    .disabled(newEntry.trimmingCharacters(in: .whitespaces).isEmpty)
                Button(action: remove) { Image(systemName: "minus") }
                    .disabled(selection.isEmpty)
                Spacer()
                Button("Restore Defaults") {
                    entries = AppSettings.defaultAllowList
                    persist()
                }
            }
        }
        .padding(20)
        .onAppear { entries = monitor.settings.allowList }
    }

    private func add() {
        let e = newEntry.trimmingCharacters(in: .whitespaces)
        guard !e.isEmpty, !entries.contains(e) else { newEntry = ""; return }
        entries.append(e)
        newEntry = ""
        persist()
    }

    private func remove() {
        entries.removeAll { selection.contains($0) }
        selection.removeAll()
        persist()
    }

    private func persist() {
        monitor.settings.allowList = entries
        monitor.settingsChanged()
    }
}

// MARK: - About

private struct AboutPane: View {
    @ObservedObject var monitor: Monitor
    @State private var duty: Double = 0
    @State private var cpuMs: Double = 0

    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "Version \(v) (\(b))"
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

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
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