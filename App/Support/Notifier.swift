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
        withdrawLeftovers()
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

    /// Takes back the alert for a process that has exited, calmed down or been
    /// dealt with. A Focus mode holds notifications back, so without this a
    /// process that ran away at night was announced in the morning, hours
    /// after it had gone.
    static func withdraw(pid: pid_t) {
        let id = ["runaway-\(pid)"]
        let c = UNUserNotificationCenter.current()
        c.removePendingNotificationRequests(withIdentifiers: id)
        c.removeDeliveredNotifications(withIdentifiers: id)
    }

    /// Takes back every alert left over from a previous run. Incidents do not
    /// survive a restart, so each one describes a process nobody is watching
    /// any more, and its actions would find nothing to act on.
    static func withdrawLeftovers() {
        let c = UNUserNotificationCenter.current()
        c.getDeliveredNotifications { delivered in
            let stale = delivered.map(\.request.identifier).filter { $0.hasPrefix("runaway-") }
            if !stale.isEmpty {
                c.removeDeliveredNotifications(withIdentifiers: stale)
                nlog.notice("withdrew \(stale.count) notifications left from a previous run")
            }
        }
    }

    /// Reports what an "Always Force Quit" rule did. Silent, with no actions:
    /// the user already decided, and this is a record rather than a question.
    static func postAutoQuit(incident: Incident, reopened: Bool, enabled: Bool) {
        guard enabled else { return }
        let n = UNMutableNotificationContent()
        n.title = "Force quit \(incident.name)"
        n.body = String(format: "It had been at %.0f%% CPU for %@.", incident.cpuPercent,
                        formatDuration(incident.heldFor))
            + (reopened ? " Idlewild opened it again." : "")
        n.userInfo = ["name": incident.name]
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "autoquit-\(incident.pid)", content: n, trigger: nil)) { error in
                if let error {
                    nlog.error("post failed: \(error.localizedDescription, privacy: .public)")
                }
            }
    }

    /// One slot, reused: there is only ever one update waiting.
    static let updateNotificationID = "idlewild-update"

    /// Sparkle found a new version. Its alert cannot take focus from whatever
    /// the user is doing — a dockless app is not allowed to interrupt — so on a
    /// menu bar app the alert can sit behind everything and never be seen. This
    /// is the reminder Sparkle's documentation asks for; clicking it starts the
    /// update, see AppDelegate.
    static func postUpdate(version: String, enabled: Bool) {
        guard enabled else { return }
        let n = UNMutableNotificationContent()
        n.title = "Idlewild \(version) is available"
        n.body = "Open Idlewild to install it."
        n.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: updateNotificationID, content: n, trigger: nil)) { error in
                if let error {
                    nlog.error("update notification failed: \(error.localizedDescription, privacy: .public)")
                } else {
                    nlog.notice("posted update notification for \(version, privacy: .public)")
                }
            }
    }

    /// Called when the user has seen the update alert, so the reminder does not
    /// outlive it.
    static func dismissUpdate() {
        UNUserNotificationCenter.current()
            .removeDeliveredNotifications(withIdentifiers: [updateNotificationID])
    }
}