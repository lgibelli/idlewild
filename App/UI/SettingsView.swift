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
            GeneralPane(monitor: monitor)
                .tabItem { Label("General", systemImage: "gearshape") }
            CPUPane(monitor: monitor)
                .tabItem { Label("CPU", systemImage: "cpu") }
            MemoryPane(monitor: monitor)
                .tabItem { Label("Memory", systemImage: "memorychip") }
            ExceptionsPane(monitor: monitor)
                .tabItem { Label("Exceptions", systemImage: "checkmark.shield") }
        }
        .frame(width: 560, height: 420)
    }
}

// MARK: - Shared pieces

/// Reads as a sentence and updates live, which removes the need for a
/// paragraph of explanation under every control.
private struct Summary: View {
    let markdown: String
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "text.bubble")
                .foregroundStyle(.secondary)
                .font(.system(size: 13))
                .padding(.top, 1)
            // Markdown rather than Text concatenation, which is deprecated.
            Text((try? AttributedString(markdown: markdown)) ?? AttributedString(markdown))
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// A switch with a one-line explanation underneath, the shape every toggle in
/// Settings takes so the panes read alike.
///
/// Laid out by hand rather than as Toggle's own label: a switch-style Toggle
/// sizes itself to its content and the VStack centres it, so three rows with
/// captions of different lengths stagger across the pane. Here the text is
/// pinned to the leading edge and the switch to the trailing one.
private struct SwitchRow: View {
    let title: String
    let caption: String
    @Binding var isOn: Bool
    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(caption)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
    }
}

private func minutes(_ m: Double) -> String {
    let n = Int(m)
    return "\(n) minute\(n == 1 ? "" : "s")"
}

// MARK: - General

private struct GeneralPane: View {
    @ObservedObject var monitor: Monitor
    @State private var interval: Double = 120
    @State private var notify = true
    @State private var launchAtLogin = false
    @State private var checkUpdates = true
    @State private var colouredIcon = false
    @State private var loginError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox {
                SliderRow(title: "Check every",
                          value: $interval, range: 30...300, step: 15,
                          display: "\(Int(interval))s",
                          hint: "when calm") { save() }
                    .padding(.vertical, 4)
            }

            GroupBox {
                VStack(spacing: 10) {
                    SwitchRow(title: "Show notifications",
                              caption: "The menu bar icon changes either way.",
                              isOn: $notify)
                        .onChange(of: notify) { _, _ in save() }
                    Divider()
                    SwitchRow(title: "Colour the flame",
                              caption: "Orange when something is running away. Off by default; most people keep the menu bar monochrome.",
                              isOn: $colouredIcon)
                        .onChange(of: colouredIcon) { _, _ in save() }
                    Divider()
                    SwitchRow(title: "Launch at login",
                              caption: "A watchdog you have to remember to start is not much of a watchdog.",
                              isOn: $launchAtLogin)
                        .onChange(of: launchAtLogin) { _, v in setLogin(v) }
                    Divider()
                    SwitchRow(title: "Check for updates",
                              caption: "Contacts salamacchine.it once a day. Nothing is downloaded or installed automatically.",
                              isOn: $checkUpdates)
                        .onChange(of: checkUpdates) { _, _ in save() }
                }
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

    private func load() {
        interval = monitor.settings.calmInterval
        notify = monitor.settings.notificationsEnabled
        launchAtLogin = SMAppService.mainApp.status == .enabled
        checkUpdates = monitor.settings.checkForUpdates
        colouredIcon = monitor.settings.colouredIcon
    }

    private func save() {
        monitor.settings.calmInterval = interval
        monitor.settings.notificationsEnabled = notify
        monitor.settings.checkForUpdates = checkUpdates
        monitor.settings.colouredIcon = colouredIcon
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

// MARK: - CPU

private struct CPUPane: View {
    @ObservedObject var monitor: Monitor
    @State private var enabled = true
    @State private var threshold: Double = 80
    @State private var sustain: Double = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Summary(markdown: enabled
                ? "Alert me when a process holds above **\(Int(threshold))%** of one core for **\(minutes(sustain))**."
                : "CPU is not being watched.")

            GroupBox {
                VStack(spacing: 14) {
                    SwitchRow(title: "Watch CPU",
                              caption: "A process holding a core for longer than a build or an export should.",
                              isOn: $enabled)
                        .onChange(of: enabled) { _, _ in save() }
                    Divider()
                    SliderRow(title: "Threshold",
                              value: $threshold, range: 30...200, step: 5,
                              display: "\(Int(threshold))%",
                              hint: "of one core") { save() }
                    Divider()
                    SliderRow(title: "Held for",
                              value: $sustain, range: 1...30, step: 1,
                              display: "\(Int(sustain)) min",
                              hint: "before alerting") { save() }
                }
                .padding(.vertical, 4)
                .disabled(!enabled)
            }

            Text("The sustain window is the single most important setting. 100% for 30 seconds is a build; for nine hours it is a bug.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(20)
        .onAppear(perform: load)
    }

    private func load() {
        enabled = monitor.settings.cpuEnabled
        threshold = monitor.settings.cpuThreshold
        sustain = monitor.settings.sustainMinutes
    }

    private func save() {
        monitor.settings.cpuEnabled = enabled
        monitor.settings.cpuThreshold = threshold
        monitor.settings.sustainMinutes = sustain
        monitor.settingsChanged()
    }
}

// MARK: - Memory

private struct MemoryPane: View {
    @ObservedObject var monitor: Monitor
    @State private var enabled = true
    @State private var share: Double = 50
    @State private var sustain: Double = 10
    @State private var fillHours: Double = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Summary(markdown: enabled
                ? "Alert me when a process uses more than **\(Int(share))%** of memory (\(shareText)), "
                  + "has been growing steadily for **\(minutes(sustain))**, and at that rate would fill "
                  + "memory within **\(Int(fillHours)) hour\(Int(fillHours) == 1 ? "" : "s")**. "
                  + "Also name the largest process when the machine starts swapping."
                : "Memory is not being watched.")

            GroupBox {
                VStack(spacing: 14) {
                    SwitchRow(title: "Watch memory",
                              caption: "A leak climbs in a straight line and never plateaus; honest work loads something and stops.",
                              isOn: $enabled)
                        .onChange(of: enabled) { _, _ in save() }
                    Divider()
                    SliderRow(title: "Threshold",
                              value: $share, range: 10...90, step: 5,
                              display: "\(Int(share))%",
                              hint: "of memory, \(shareText)") { save() }
                    Divider()
                    SliderRow(title: "Growing for",
                              value: $sustain, range: 2...60, step: 1,
                              display: "\(Int(sustain)) min",
                              hint: "in a straight line") { save() }
                    Divider()
                    SliderRow(title: "Fills memory in",
                              value: $fillHours, range: 1...48, step: 1,
                              display: "\(Int(fillHours)) h",
                              hint: "or sooner") { save() }
                }
                .padding(.vertical, 4)
                .disabled(!enabled)
            }

            Spacer(minLength: 0)
        }
        .padding(20)
        .onAppear(perform: load)
    }

    private var shareText: String {
        formatBytes(UInt64(Double(HostMemory.physical) * share / 100))
    }

    private func load() {
        enabled = monitor.settings.memoryEnabled
        share = monitor.settings.memoryShareThreshold
        sustain = monitor.settings.memorySustainMinutes
        fillHours = monitor.settings.memoryFillHours
    }

    private func save() {
        monitor.settings.memoryEnabled = enabled
        monitor.settings.memoryShareThreshold = share
        monitor.settings.memorySustainMinutes = sustain
        monitor.settings.memoryFillHours = fillHours
        monitor.settingsChanged()
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
            .frame(width: 150, alignment: .leading)
        }
    }
}

// MARK: - Exceptions

private struct ExceptionsPane: View {
    @ObservedObject var monitor: Monitor
    @State private var entries: [String] = []
    @State private var selection: Set<String> = []
    @State private var newEntry = ""
    @State private var snoozes: [(key: String, until: Date)] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            snoozeSection
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
        .onAppear {
            entries = monitor.settings.allowList
            snoozes = monitor.settings.activeSnoozes()
        }
    }

    /// Shown only when something is snoozed. A temporary exception nobody can
    /// see is indistinguishable from the app having quietly stopped working.
    @ViewBuilder
    private var snoozeSection: some View {
        if !snoozes.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Temporarily ignored").font(.headline)
                ForEach(snoozes, id: \.key) { s in
                    HStack(spacing: 8) {
                        Image(systemName: "clock")
                            .foregroundStyle(.orange.opacity(0.9)).font(.caption)
                        Text((s.key as NSString).lastPathComponent)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 8)
                        Text(Self.remaining(until: s.until))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Button("Resume") {
                            monitor.settings.clearSnooze(key: s.key)
                            snoozes = monitor.settings.activeSnoozes()
                        }
                        .controlSize(.small)
                    }
                }
            }
            .padding(10)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private static func remaining(until: Date) -> String {
        let secs = max(0, Int(until.timeIntervalSinceNow))
        if secs < 3600 { return "\(max(1, secs / 60)) min left" }
        let h = secs / 3600, m = (secs % 3600) / 60
        return m == 0 ? "\(h)h left" : "\(h)h \(m)m left"
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

