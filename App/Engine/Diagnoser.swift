// SPDX-FileCopyrightText: 2026 Luca Gibelli
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Turns a stack sample into a sentence a human can act on.
///
/// This is the expensive path - sample(1) suspends the target and walks its
/// stacks - so it runs once per incident, never on a timer.
enum Diagnoser {

    struct Verdict {
        let cause: String
        let confident: Bool
    }

    /// Ordered most-specific first. All needles must appear.
    private static let rules: [(cause: String, needles: [String], confident: Bool)] = [
        ("a web page stuck throwing JavaScript errors in a loop",
         ["Interpreter::unwind", "getStackTrace"], true),
        ("runaway JavaScript - a promise or microtask storm",
         ["runInternalMicrotask", "MicrotaskQueue"], true),
        ("garbage-collection thrash, usually a memory leak",
         ["MarkedBlock", "Heap::"], true),
        ("heavy JavaScript execution", ["JavaScriptCore"], false),
        ("a runaway animation or redraw loop", ["QuartzCore"], false),
        ("an event-loop spin", ["__CFRunLoopServiceMachPort", "kevent"], false),
        ("regular-expression backtracking", ["YarrJIT"], true),
        ("allocation churn", ["malloc_zone", "free_tiny"], false),
    ]

    static func diagnose(pid: pid_t, processName: String = "", timeout: TimeInterval = 12) -> Verdict {
        guard let text = runSample(pid: pid, seconds: 2, timeout: timeout) else {
            return Verdict(cause: "could not inspect this process", confident: false)
        }
        // Locate the summary section with one search and bound the window; the
        // full sample output can run to hundreds of KB.
        let hay: Substring
        if let r = text.range(of: "Sort by top of stack", options: .backwards) {
            hay = text[r.upperBound...].prefix(3000)
        } else {
            hay = text.suffix(3000)
        }

        for rule in rules where rule.needles.allSatisfy({ hay.contains($0) }) {
            return Verdict(cause: rule.cause, confident: rule.confident)
        }
        // Every thread is sampled whether it runs or not, so in a process with
        // a dozen parked threads and one busy one the parked frames top the
        // list: 10,200 samples in __psynch_cvwait against 1,700 in the loop
        // that was actually burning the core. Look past them.
        guard let hot = hottestWork(hay) else {
            return Verdict(cause: "threads look idle - the CPU time may be elsewhere",
                           confident: false)
        }
        // No framework matched, but the hot frames belong to the process itself:
        // a plain compute loop in its own code. Common, and worth naming rather
        // than shrugging at.
        if !processName.isEmpty, hot == processName {
            return Verdict(cause: "a tight loop in the program's own code", confident: true)
        }
        // Otherwise say whose code it is. "Busy in SpotlightKnowledgeDaemon"
        // tells a user more than "cause unclear" ever will.
        return Verdict(cause: "busy in \(hot)", confident: false)
    }

    /// Frames a thread sits in while it waits for something, not working.
    private static let waitFrames = [
        "__psynch_cvwait", "__psynch_mutexwait", "mach_msg2_trap", "mach_msg_trap",
        "__semwait_signal", "__workq_kernreturn", "kevent", "__select", "__ulock_wait",
        "__sigsuspend", "__wait4", "__recvfrom", "__read_nocancel", "poll",
    ]

    /// The image holding the busiest frame that is not a wait, from the "Sort
    /// by top of stack" summary. Nil when waiting is all the threads were doing
    /// - fewer than 100 working samples, a twentieth of one core over the two
    /// second sample.
    static func hottestWork(_ summary: Substring) -> String? {
        var best: (image: String, count: Int)?
        var working = 0
        for line in summary.split(separator: "\n", omittingEmptySubsequences: false).dropFirst() {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.isEmpty { break }
            guard let open = text.range(of: "(in "),
                  let close = text.range(of: ")", range: open.upperBound..<text.endIndex),
                  let count = Int(text[close.upperBound...].trimmingCharacters(in: .whitespaces))
            else { continue }
            let symbol = text[..<open.lowerBound].trimmingCharacters(in: .whitespaces)
            if waitFrames.contains(where: { symbol.hasPrefix($0) }) { continue }
            working += count
            if count > (best?.count ?? 0) {
                var image = String(text[open.upperBound..<close.lowerBound])
                if image.hasSuffix(".dylib") { image.removeLast(6) }
                best = (image, count)
            }
        }
        return working >= 100 ? best?.image : nil
    }

    private static func runSample(pid: pid_t, seconds: Int, timeout: TimeInterval) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        p.arguments = ["\(pid)", "\(seconds)", "-mayDie"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }

        // Read on a background queue so a wedged sample cannot deadlock us on a
        // full pipe buffer, and enforce a hard timeout.
        var data = Data()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            data = pipe.fileHandleForReading.readDataToEndOfFile()
            done.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            _ = done.wait(timeout: .now() + 2)
        }
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}