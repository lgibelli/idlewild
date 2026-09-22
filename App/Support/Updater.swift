// SPDX-FileCopyrightText: 2026 Luca Gibelli
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import AppKit
import Combine
import Sparkle

/// Updates, via Sparkle.
///
/// The app used to read a small JSON feed itself and offer to open the download
/// page. That is the smallest possible attack surface, but it left the update a
/// manual drag out of the disk image, so the installed copy fell behind the one
/// being worked on. Sparkle is the boring answer, and the one every other
/// Developer ID app on the Mac uses.
///
/// The trust anchor is not the feed: the archive has to carry an Ed25519
/// signature made with the private key that only the release job holds, and the
/// app inside it has to be signed by the same team as the one already running.
/// Somebody who takes over the web server can serve a different appcast and
/// Sparkle will refuse everything in it.
///
/// The feed URL, the public key and the check interval live in Info.plist, and
/// Sparkle persists the user's choice about automatic checks in the defaults -
/// there is deliberately no second copy of that setting here.
@MainActor
final class Updater: ObservableObject {

    /// False while a check or an installation is already running. Sparkle owns
    /// this; the menu follows it so "Check for Updates" cannot be started twice.
    @Published private(set) var canCheckForUpdates = false

    private let reminders: UpdateReminders
    private let controller: SPUStandardUpdaterController

    init(settings: AppSettings) {
        reminders = UpdateReminders(settings: settings)
        controller = SPUStandardUpdaterController(startingUpdater: true,
                                                  updaterDelegate: nil,
                                                  userDriverDelegate: reminders)
        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    /// What the Settings switch reads and writes, so the switch and Sparkle's
    /// own alerts cannot disagree about it.
    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}

/// Gentle reminders: Sparkle asks every dockless app for these, and warns in the
/// log when it does not get them.
///
/// A menu bar app may not steal focus, so a scheduled update alert is put behind
/// whatever the user is doing and can go unseen for days. While an update is
/// being handled the app rejoins the Dock — which is what lets the alert come to
/// the front, and what makes it reachable with Cmd-Tab — and a notification says
/// so. Both are taken back when the user has seen the alert, or when the update
/// session ends.
///
/// Sparkle calls these on the main thread; the protocol cannot say so, hence the
/// explicit hops.
final class UpdateReminders: NSObject, SPUStandardUserDriverDelegate {

    private let settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings
        super.init()
    }

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool,
                                                   forUpdate update: SUAppcastItem,
                                                   state: SPUUserUpdateState) {
        let version = update.displayVersionString
        let userInitiated = state.userInitiated
        MainActor.assumeIsolated {
            _ = NSApp.setActivationPolicy(.regular)
            // A check the user asked for already has their attention.
            guard !userInitiated else { return }
            NSApp.dockTile.badgeLabel = "1"
            Notifier.postUpdate(version: version,
                                enabled: settings.notificationsEnabled)
        }
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        MainActor.assumeIsolated {
            NSApp.dockTile.badgeLabel = ""
            Notifier.dismissUpdate()
        }
    }

    func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated {
            _ = NSApp.setActivationPolicy(.accessory)
        }
    }
}
