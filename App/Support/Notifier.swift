import Foundation
import UserNotifications
import os

private let nlog = Logger(subsystem: "it.salamacchine.idlewild", category: "notifier")

/// Native notifications with actions. Requires a signed bundle with a bundle
/// identifier - one of the reasons this ships as an app rather than a CLI tool.
enum Notifier {

    static let categoryID = "it.salamacchine.idlewild.runaway"
    enum Action: String { case kill = "KILL", suspend = "SUSPEND", ignore = "IGNORE" }

    static func configure(delegate: UNUserNotificationCenterDelegate) {
        let c = UNUserNotificationCenter.current()
        c.delegate = delegate
        let category = UNNotificationCategory(
            identifier: categoryID,
            actions: [
                UNNotificationAction(identifier: Action.kill.rawValue, title: "Force Quit",
                                     options: [.destructive]),
                UNNotificationAction(identifier: Action.suspend.rawValue, title: "Pause It",
                                     options: []),
                UNNotificationAction(identifier: Action.ignore.rawValue, title: "Ignore",
                                     options: []),
            ],
            intentIdentifiers: [], options: [])
        c.setNotificationCategories([category])
        c.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                nlog.error("authorization failed: \(error.localizedDescription, privacy: .public)")
            } else {
                nlog.notice("notification authorization granted=\(granted)")
            }
        }
    }

    static func post(incident: Incident, enabled: Bool) {
        guard enabled else { return }
        let n = UNMutableNotificationContent()
        n.title = "\(incident.name) is running away"
        n.subtitle = incident.summary
        n.body = incident.cause.isEmpty ? "Sustained high CPU." : incident.cause.prefix(1).uppercased() + incident.cause.dropFirst() + "."
        n.categoryIdentifier = categoryID
        n.userInfo = ["pid": Int(incident.pid), "name": incident.name]
        n.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "runaway-\(incident.pid)", content: n, trigger: nil)) { error in
                if let error {
                    nlog.error("post failed: \(error.localizedDescription, privacy: .public)")
                } else {
                    nlog.notice("posted notification for pid \(incident.pid)")
                }
            }
    }
}
