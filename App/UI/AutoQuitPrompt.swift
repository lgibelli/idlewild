// SPDX-FileCopyrightText: 2026 Luca Gibelli
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit

/// The two questions "Always Force Quit" has to ask: how long the program may
/// run away before it is stopped, and whether to open it again afterwards.
///
/// An alert with an accessory view rather than a window: the question comes
/// from a menu, a menu cannot hold controls, and an alert is the native shape
/// for "confirm, with one or two choices".
@MainActor
enum AutoQuitPrompt {

    static func ask(name: String, restart: ProcessActions.Restart,
                    settings: AppSettings) -> AutoQuitRule? {
        let alert = NSAlert()
        alert.messageText = "Always force quit \(name)?"
        alert.informativeText = "Whenever \(name) runs away, Idlewild will force quit it "
            + "instead of asking. Anything unsaved in it is lost."
        alert.addButton(withTitle: "Always Force Quit")
        alert.addButton(withTitle: "Cancel")

        let waits = choices(sustain: settings.sustainSeconds)
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: waits.map(\.title))
        let row = NSStackView(views: [NSTextField(labelWithString: "Force quit it"), popup])
        row.orientation = .horizontal
        row.spacing = 8

        let counted = caption("Counted from when it first went over "
                              + "\(Int(settings.cpuThreshold))% CPU.")
        var views: [NSView] = [row, counted]

        let reopen: NSButton?
        switch restart {
        case .app:
            let box = NSButton(checkboxWithTitle: "Open \(name) again afterwards",
                               target: nil, action: nil)
            box.state = .on
            views.append(box)
            reopen = box
        case .unavailable(let why):
            views.append(caption(why))
            reopen = nil
        }

        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(4, after: row)
        stack.setCustomSpacing(12, after: counted)
        stack.frame = NSRect(origin: .zero, size: NSSize(width: 300, height: stack.fittingSize.height))
        alert.accessoryView = stack

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return AutoQuitRule(after: waits[max(popup.indexOfSelectedItem, 0)].seconds,
                            restart: reopen?.state == .on)
    }

    /// "As soon as it is caught" first, meaning whenever the sustain window
    /// catches it, then longer leashes for things that finish on their own
    /// given time but should not be allowed to burn all night.
    private static func choices(sustain: TimeInterval) -> [(title: String, seconds: TimeInterval)] {
        let caught = (title: "as soon as it is caught (after \(AutoQuitRule.span(sustain)))",
                      seconds: TimeInterval(0))
        let longer = [15, 30, 60, 120].map { TimeInterval($0 * 60) }.filter { $0 > sustain }
        return [caught] + longer.map { (title: "after \(AutoQuitRule.span($0))", seconds: $0) }
    }

    private static func caption(_ text: String) -> NSTextField {
        let f = NSTextField(wrappingLabelWithString: text)
        f.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        f.textColor = .secondaryLabelColor
        f.preferredMaxLayoutWidth = 300
        return f
    }
}
