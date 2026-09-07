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
        // Guard against accusing a process whose threads are merely parked.
        if hay.contains("__psynch_cvwait") || hay.contains("mach_msg2_trap") {
            return Verdict(cause: "threads look idle - the CPU time may be elsewhere",
                           confident: false)
        }
        // No framework matched, but the hot frames belong to the process itself:
        // a plain compute loop in its own code. Common, and worth naming rather
        // than shrugging at.
        if !processName.isEmpty, hay.contains("(in \(processName))") {
            return Verdict(cause: "a tight loop in the program's own code", confident: true)
        }
        return Verdict(cause: "cause unclear", confident: false)
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
