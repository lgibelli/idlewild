import SwiftUI

struct MenuView: View {
    @ObservedObject var monitor: Monitor
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if monitor.incidents.isEmpty {
                Divider().padding(.vertical, 6)
                calmState
            } else {
                ForEach(monitor.incidents) { inc in
                    Divider().padding(.vertical, 6)
                    IncidentRow(incident: inc, monitor: monitor)
                }
            }

            Divider().padding(.vertical, 6)
            topList
            Divider().padding(.vertical, 6)
            footer
        }
        .padding(12)
        .frame(width: 340)
    }

    private var header: some View {
        HStack {
            Image(systemName: monitor.incidents.isEmpty ? "checkmark.circle.fill" : "flame.fill")
                .foregroundStyle(monitor.incidents.isEmpty ? .green : .orange)
            Text(monitor.incidents.isEmpty ? "Nothing running away" : "Runaway process detected")
                .font(.headline)
            Spacer()
            if monitor.isPaused {
                Text("PAUSED").font(.caption2.bold()).foregroundStyle(.secondary)
            }
        }
    }

    private var calmState: some View {
        Text("Watching for processes that hold above \(Int(monitor.settings.cpuThreshold))% of a core for \(Int(monitor.settings.sustainMinutes)) minutes.")
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private var topList: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("BUSIEST NOW").font(.caption2.bold()).foregroundStyle(.tertiary)
            if monitor.topProcesses.isEmpty {
                Text("idle").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(monitor.topProcesses, id: \.pid) { p in
                HStack(spacing: 6) {
                    Text(p.name).font(.caption).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text(String(format: "%.0f%%", p.pct))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(p.pct > 80 ? .orange : .secondary)
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            // Our own cost, always visible. A watchdog should be accountable to
            // the same standard it enforces.
            Text(String(format: "idlewild: %.3f%% CPU", monitor.ownDutyCycle))
                .font(.caption2).foregroundStyle(.tertiary)
            Spacer()
            Button(monitor.isPaused ? "Resume" : "Pause") { monitor.togglePause() }
                .buttonStyle(.link).font(.caption)
            Button("Settings") { openSettings() }.buttonStyle(.link).font(.caption)
            Button("Quit") { NSApplication.shared.terminate(nil) }.buttonStyle(.link).font(.caption)
        }
    }
}

struct IncidentRow: View {
    let incident: Incident
    @ObservedObject var monitor: Monitor
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(incident.name).font(.subheadline.bold()).lineLimit(1).truncationMode(.middle)
            Text(incident.summary).font(.caption).foregroundStyle(.secondary)
            if !incident.cause.isEmpty {
                Text(incident.cause).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Only worth surfacing when it is the thermally expensive kind.
            if incident.heatWeight > 0.8 {
                Label("on performance cores - this is what heats the machine",
                      systemImage: "thermometer.high")
                    .font(.caption2).foregroundStyle(.orange)
            }
            if let error {
                Text(error).font(.caption2).foregroundStyle(.red)
            }
            HStack(spacing: 6) {
                Button("Force Quit") { act { monitor.kill(incident) } }
                Button("Pause It")   { act { monitor.suspend(incident) } }
                Button("Ignore")     { monitor.dismiss(incident) }
                Button("Always Allow") { monitor.alwaysAllow(incident) }
            }
            .buttonStyle(.bordered).controlSize(.small)
            Text("pid \(incident.pid) · \(incident.path)")
                .font(.caption2).foregroundStyle(.tertiary)
                .lineLimit(1).truncationMode(.middle)
        }
    }

    private func act(_ op: () -> ProcessActions.Result) {
        switch op() {
        case .ok, .gone: error = nil
        case .notPermitted: error = "Not permitted - this process belongs to another user."
        case .failed(let e): error = "Failed (errno \(e))."
        }
    }
}
