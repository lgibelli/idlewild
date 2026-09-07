import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @ObservedObject var monitor: Monitor
    @State private var threshold: Double = 80
    @State private var sustain: Double = 5
    @State private var interval: Double = 120
    @State private var notify = true
    @State private var launchAtLogin = false
    @State private var allowText = ""
    @State private var loginError: String?

    var body: some View {
        TabView {
            detection.tabItem { Label("Detection", systemImage: "gauge") }
            exceptions.tabItem { Label("Exceptions", systemImage: "checkmark.shield") }
            about.tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 460, height: 340)
        .onAppear(perform: load)
    }

    private var detection: some View {
        Form {
            VStack(alignment: .leading) {
                Text("Alert above \(Int(threshold))% of one core")
                Slider(value: $threshold, in: 30...200, step: 5) { _ in save() }
                Text("100% means one core fully busy. Values above 100% catch multi-threaded runaways only.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading) {
                Text("Held for at least \(Int(sustain)) minutes")
                Slider(value: $sustain, in: 1...30, step: 1) { _ in save() }
                Text("A build hits 100% for a minute. A bug holds it for hours. This is the setting that prevents false alarms.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading) {
                Text("Check every \(Int(interval)) seconds when calm")
                Slider(value: $interval, in: 30...300, step: 15) { _ in save() }
                Text("Idlewild speeds up automatically while a suspect is building. Longer intervals cost less power.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Show notifications", isOn: $notify).onChange(of: notify) { _, _ in save() }
            Toggle("Launch at login", isOn: $launchAtLogin).onChange(of: launchAtLogin) { _, v in setLogin(v) }
            if let loginError {
                Text(loginError).font(.caption).foregroundStyle(.red)
            }
        }
        .formStyle(.grouped).padding()
    }

    private var exceptions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Never alert about these").font(.headline)
            Text("One per line. Matched against the executable path, so a name like \"ffmpeg\" or \"Final Cut Pro.app\" is enough.")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $allowText)
                .font(.system(.body, design: .monospaced))
                .border(.quaternary)
            HStack {
                Button("Restore Defaults") {
                    allowText = AppSettings.defaultAllowList.joined(separator: "\n"); save()
                }
                Spacer()
                Button("Save") { save() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding()
    }

    private var about: some View {
        VStack(spacing: 10) {
            Image(systemName: MenuBarIcon.calm).font(.system(size: 40)).foregroundStyle(.secondary)
            Text("Idlewild").font(.title2.bold())
            Text("Notices when a process runs away, works out why, and offers to stop it.")
                .font(.callout).multilineTextAlignment(.center).foregroundStyle(.secondary)
            Divider().padding(.vertical, 4)
            // A watchdog should be accountable to the standard it enforces.
            Text(String(format: "Idlewild has used %.0f ms of CPU since launch (%.4f%% of one core).",
                        monitor.ownCPUms, monitor.ownDutyCycle))
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Text("For comparison, a typical menu bar CPU meter costs around 3.6%.")
                .font(.caption2).foregroundStyle(.tertiary)
            Spacer()
        }
        .padding()
    }

    private func load() {
        threshold = monitor.settings.cpuThreshold
        sustain = monitor.settings.sustainMinutes
        interval = monitor.settings.calmInterval
        notify = monitor.settings.notificationsEnabled
        allowText = monitor.settings.allowList.joined(separator: "\n")
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func save() {
        monitor.settings.cpuThreshold = threshold
        monitor.settings.sustainMinutes = sustain
        monitor.settings.calmInterval = interval
        monitor.settings.notificationsEnabled = notify
        monitor.settings.allowList = allowText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
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
