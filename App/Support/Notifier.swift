// SPDX-FileCopyrightText: 2026 Luca Gibelli
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import AppKit
import UserNotifications
import os

private let nlog = Logger(subsystem: "it.salamacchine.idlewild", category: "notifier")

/// Native notifications with actions. Requires a signed bundle with a bundle
/// identifier - one of the reasons this ships as an app rather than a CLI tool.
enum Notifier {

    /// Whether the system will actually show our notifications. When it will
    /// not, the menu says so rather than the app failing silently - the menu bar
    /// flame and the menu itself keep working regardless.
    @MainActor static var isAuthorized = false
    @MainActor static var authorizationProblem: String?

    static let categoryID = "it.salamacchine.idlewild.runaway"
    /// Pausing frees no memory, so a memory notification offers no Pause It.
    static let memoryCategoryID = "it.salamacchine.idlewild.memory"
    enum Action: String {
        case kill = "KILL"
        case suspend = "SUSPEND"
        case ignore = "IGNORE"              // this notification only
        case snoozeHour = "SNOOZE_HOUR"
        case snoozeToday = "SNOOZE_TODAY"
        case allowAlways = "ALLOW_ALWAYS"
    }

    /// Shared by both categories. "Ignore" dismisses this one notification;
    /// the snoozes stop reporting for a while and then lapse on their own, so a
    /// one-off nuisance never quietly becomes a permanent blind spot.
    private static var snoozeActions: [UNNotificationAction] {
        [
            UNNotificationAction(identifier: Action.ignore.rawValue, title: "Ignore", options: []),
            UNNotificationAction(identifier: Action.snoozeHour.rawValue,
                                 title: "Ignore for 1 Hour", options: []),
            UNNotificationAction(identifier: Action.snoozeToday.rawValue,
                                 title: "Ignore Until Tomorrow", options: []),
            UNNotificationAction(identifier: Action.allowAlways.rawValue,
                                 title: "Always Ignore This App", options: []),
        ]
    }

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
            ] + snoozeActions,
            intentIdentifiers: [], options: [])
        let kill = UNNotificationAction(identifier: Action.kill.rawValue, title: "Force Quit",
                                        options: [.destructive])
        let memory = UNNotificationCategory(identifier: memoryCategoryID,
                                            actions: [kill] + snoozeActions,
                                            intentIdentifiers: [], options: [])
        c.setNotificationCategories([category, memory])
        c.requestAuthorization(options: [.alert, .sound]) { granted, error in
            Task { @MainActor in
                if let error {
                    nlog.error("authorization failed: \(error.localizedDescription, privacy: .public)")
                    isAuthorized = false
                    authorizationProblem = error.localizedDescription
                } else {
                    nlog.notice("notification authorization granted=\(granted)")
                    isAuthorized = granted
                    authorizationProblem = granted ? nil : "Notifications are turned off for Idlewild."
                }
            }
        }
    }

    /// Opens the Notifications pane so the user can enable us by hand.
    @MainActor static func openSettings() {
        let url = "x-apple.systempreferences:com.apple.preference.notifications"
        if let u = URL(string: url) { NSWorkspace.shared.open(u) }
    }

    static func post(incident: Incident, enabled: Bool) {
        guard enabled else { return }
        let n = UNMutableNotificationContent()
        switch incident.kind {
        case .cpu:
            n.title = "\(incident.name) is running away"
            n.body = incident.cause.isEmpty ? "Sustained high CPU." : incident.cause.prefix(1).uppercased() + incident.cause.dropFirst() + "."
            n.categoryIdentifier = categoryID
        case .memory:
            n.title = incident.underPressure
                ? "\(incident.name) is eating the memory"
                : "\(incident.name) keeps growing"
            n.body = incident.cause.prefix(1).uppercased() + incident.cause.dropFirst() + "."
            n.categoryIdentifier = memoryCategoryID
        }
        n.subtitle = incident.summary
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