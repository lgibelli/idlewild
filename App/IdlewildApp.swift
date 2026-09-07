import SwiftUI
import UserNotifications

@main
struct IdlewildApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var monitor = Monitor()

    var body: some Scene {
        MenuBarExtra {
            MenuView(monitor: monitor)
        } label: {
            // The icon changes shape only when state changes - never on a timer.
            // A menu bar item that repaints on a schedule is the exact failure
            // this app exists to catch.
            Image(systemName: iconName)
        }
        // .menu gives a real NSMenu - standard highlighting, keyboard
        // navigation and metrics - instead of a custom floating panel.
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(monitor: monitor)
        }
    }

    private var iconName: String {
        if !monitor.incidents.isEmpty { return "flame.fill" }
        return monitor.isPaused ? "pause.circle" : MenuBarIcon.calm
    }
}

/// The calm-state glyph is what people see essentially always, so it must read
/// as "monitoring, all normal" rather than as a warning. An ECG trace carries
/// exactly that meaning - it is the same visual language Activity Monitor uses -
/// where a flame, even an outline one, would look like an alert all day and
/// undermine an app whose whole purpose is not crying wolf.
enum MenuBarIcon {
    static let calm: String = firstAvailable([
        "waveform.path.ecg",                  // the heartbeat line
        "waveform.path",
        "speedometer",                        // long-standing fallback
    ])

    private static func firstAvailable(_ names: [String]) -> String {
        for n in names where NSImage(systemSymbolName: n, accessibilityDescription: nil) != nil {
            return n
        }
        return "circle"
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {

    /// Set by Monitor on init so notification actions can reach it.
    static weak var monitor: Monitor?

    func applicationDidFinishLaunching(_ n: Notification) {
        Notifier.configure(delegate: self)
    }

    /// Show the banner even when Idlewild is the active app.
    func userNotificationCenter(_ c: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound])
    }

    func userNotificationCenter(_ c: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        guard let raw = info["pid"] as? Int else { done(); return }
        let pid = pid_t(raw)

        Task { @MainActor in
            defer { done() }
            guard let monitor = AppDelegate.monitor,
                  let incident = monitor.incidents.first(where: { $0.pid == pid })
            else { return }

            switch response.actionIdentifier {
            case Notifier.Action.kill.rawValue:    monitor.kill(incident)
            case Notifier.Action.suspend.rawValue: monitor.suspend(incident)
            case Notifier.Action.ignore.rawValue:  monitor.dismiss(incident)
            default: break   // tapping the body just opens the menu
            }
        }
    }
}
