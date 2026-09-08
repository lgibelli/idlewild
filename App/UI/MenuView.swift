// SPDX-FileCopyrightText: 2026 Luca Gibelli
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import AppKit

/// The menu bar menu.
///
/// Built with `.menuBarExtraStyle(.menu)`, so this is a real NSMenu - system
/// highlighting, keyboard navigation, standard metrics - rather than a custom
/// floating panel. That constrains the content to genuine menu items: Button,
/// Text (renders disabled, useful for status lines), Divider, Section and Menu
/// for submenus. No custom layout, which is the whole point.
struct MenuView: View {
    @ObservedObject var monitor: Monitor
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        status

        if !monitor.incidents.isEmpty {
            Divider()
            ForEach(monitor.incidents) { incident in
                IncidentMenu(incident: incident, monitor: monitor)
            }
        }

        if Notifier.authorizationProblem != nil {
            Divider()
            Text("Notifications are turned off")
            Button("Open Notification Settings…") { Notifier.openSettings() }
        }

        Divider()
        Button(monitor.isPaused ? "Resume Monitoring" : "Pause Monitoring") {
            monitor.togglePause()
        }
        Button("Settings…") { showSettings() }
            .keyboardShortcut(",", modifiers: .command)

        Divider()
        Button("Quit Idlewild") { NSApp.terminate(nil) }
            .keyboardShortcut("q", modifiers: .command)
    }

    @ViewBuilder
    private var status: some View {
        if monitor.isPaused {
            Text("Paused")
        } else if monitor.incidents.isEmpty {
            Text("Nothing running away")
        } else {
            Text(monitor.incidents.count == 1
                 ? "1 process running away"
                 : "\(monitor.incidents.count) processes running away")
        }
    }

    /// An LSUIElement app is not activated by opening a window, so the Settings
    /// window appears behind whatever the user was working in. Activate the app
    /// and bring that specific window forward.
    private func showSettings() {
        openSettings()
        NSApp.activate(ignoringOtherApps: true)
        // The window exists only after openSettings() has been processed.
        DispatchQueue.main.async {
            let settings = NSApp.windows.first {
                $0.identifier?.rawValue == "com_apple_SwiftUI_Settings_window"
                    || $0.title == "Idlewild Settings"
            }
            settings?.makeKeyAndOrderFront(nil)
        }
    }
}

/// One runaway process, as a submenu. The actions live one level down so the
/// top level stays scannable when several things are misbehaving at once.
private struct IncidentMenu: View {
    let incident: Incident
    @ObservedObject var monitor: Monitor

    var body: some View {
        Menu("\(incident.name) — \(incident.menuSummary)") {
            Button("Force Quit") { perform { monitor.kill(incident) } }
            Button("Pause It") { perform { monitor.suspend(incident) } }
            Divider()
            Button("Ignore This Time") { monitor.dismiss(incident) }
            Button("Always Allow \(incident.binaryName)") { monitor.alwaysAllow(incident) }
            Divider()
            if !incident.cause.isEmpty {
                Text(incident.cause.prefix(1).uppercased() + incident.cause.dropFirst())
            }
            if incident.heatWeight > 0.8 {
                Text("On performance cores — this is what heats the machine")
            }
            if incident.isLeaking {
                Text(String(format: "Memory growing %.0f MB/min", incident.growthMBPerMin))
            }
            Text("pid \(incident.pid)")
        }
    }

    /// A menu cannot show inline errors, so report a failure the native way.
    private func perform(_ op: () -> ProcessActions.Result) {
        switch op() {
        case .ok, .gone:
            break
        case .notPermitted:
            alert("Not permitted",
                  "\(incident.name) belongs to another user, so Idlewild cannot stop it.")
        case .failed(let e):
            alert("Could not stop \(incident.name)", "The system reported error \(e).")
        }
    }

    private func alert(_ title: String, _ body: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = body
        a.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }
}