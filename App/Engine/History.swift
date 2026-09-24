// SPDX-FileCopyrightText: 2026 Luca Gibelli
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// CPU time used between two scans, as the detector hands it over.
struct Usage {
    /// CPU-seconds by app. See accountName.
    var seconds: [String: Double] = [:]
    /// CPU-seconds the whole machine used, every core and every process,
    /// including the ones macOS will not let us measure.
    var busy: Double = 0
    /// Wall-clock seconds these figures cover.
    var span: Double = 0
}

/// CPU time used in one span of time, by app.
struct Slice: Codable {
    /// Seconds since 1970, aligned to the length of the slice.
    var start: TimeInterval
    /// Seconds of the span Idlewild was actually watching. Less than the span
    /// when the machine slept or monitoring was paused, and the divisor for
    /// "cores in use", so a half-watched slice is not read as a quiet one.
    var seen: Double = 0
    var busy: Double = 0
    /// CPU-seconds of the apps folded out of `apps` to keep the slice small.
    var other: Double = 0
    var apps: [String: Double] = [:]

    init(start: TimeInterval) { self.start = start }

    mutating func add(_ u: Usage) {
        seen += u.span
        busy += u.busy
        for (k, v) in u.seconds { apps[k, default: 0] += v }
    }

    mutating func merge(_ s: Slice) {
        seen += s.seen
        busy += s.busy
        other += s.other
        for (k, v) in s.apps { apps[k, default: 0] += v }
    }

    /// Keeps the `n` biggest apps and folds the rest into `other`. The long
    /// tail is dozens of daemons using a few milliseconds each; nobody reads
    /// the history for them, and they would triple its size.
    mutating func fold(keeping n: Int) {
        guard apps.count > n else { return }
        let ranked = apps.sorted { $0.value > $1.value }
        for (k, v) in ranked[n...] {
            other += v
            apps.removeValue(forKey: k)
        }
    }
}

/// What the history window is given to draw.
struct HistoryData {
    var fine: [Slice] = []
    var coarse: [Slice] = []
    var cores: Int = HostCPU.cores
}

/// Where the CPU time went, for the last month.
///
/// Two tiers: five-minute slices for the last day, hourly slices for the last
/// thirty-one. The open five-minute slice is filled scan by scan and filed into
/// both tiers when it closes. Stored as a binary property list, which writes
/// each app's name once however many slices mention it; a full month is well
/// under 200 KB.
///
/// Not internally synchronised: like Detector, it belongs to Monitor's scan
/// queue, and every call must come from there.
final class CPUHistory: @unchecked Sendable {
    static let fineStep: TimeInterval = 300
    static let coarseStep: TimeInterval = 3600
    static let fineKeep: TimeInterval = 24 * 3600 + fineStep
    static let coarseKeep: TimeInterval = 31 * 24 * 3600
    /// How often the file is rewritten while the app runs. It is also written
    /// when the app quits; a crash loses at most this much.
    static let saveEvery: TimeInterval = 15 * 60

    private struct Stored: Codable {
        var version = 1
        var fine: [Slice]
        var coarse: [Slice]
        var open: Slice?
    }

    private var fine: [Slice] = []
    private var coarse: [Slice] = []
    private var open: Slice?
    private let url: URL?
    private var savedAt = Date()
    private var dirty = false

    init(url: URL? = CPUHistory.defaultURL) {
        self.url = url
        load()
    }

    static var defaultURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("it.salamacchine.idlewild", isDirectory: true)
            .appendingPathComponent("cpu-history.plist")
    }

    func record(_ u: Usage, at now: Date = Date()) {
        guard u.span > 0 else { return }
        let start = (now.timeIntervalSince1970 / Self.fineStep).rounded(.down) * Self.fineStep
        if let o = open, o.start != start {
            close(o)
            open = nil
        }
        var o = open ?? Slice(start: start)
        o.add(u)
        open = o
        dirty = true
        if now.timeIntervalSince(savedAt) >= Self.saveEvery { save() }
    }

    /// Copies of both tiers, the open slice included, so the chart reaches the
    /// present instead of stopping at the last slice to close.
    func snapshot() -> HistoryData {
        var d = HistoryData(fine: fine, coarse: coarse)
        if var o = open {
            o.fold(keeping: 12)
            d.fine.append(o)
            file(o, into: &d.coarse)
        }
        return d
    }

    func clear() {
        fine = []
        coarse = []
        open = nil
        dirty = true
        save()
    }

    func save() {
        guard dirty, let url else { return }
        savedAt = Date()
        do {
            let enc = PropertyListEncoder()
            enc.outputFormat = .binary
            let data = try enc.encode(Stored(fine: fine, coarse: coarse, open: open))
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            dirty = false
        } catch {
            log.error("could not save the CPU history: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func load() {
        guard let url, let data = try? Data(contentsOf: url) else { return }
        guard let s = try? PropertyListDecoder().decode(Stored.self, from: data), s.version == 1 else {
            log.error("the CPU history could not be read and starts afresh")
            return
        }
        fine = s.fine
        coarse = s.coarse
        // The slice open when the app last quit carries on if we are back
        // within it, and is closed otherwise: it simply ends early.
        if let o = s.open {
            let current = (Date().timeIntervalSince1970 / Self.fineStep).rounded(.down) * Self.fineStep
            if o.start == current { open = o } else { close(o) }
        }
        prune(now: Date().timeIntervalSince1970)
    }

    private func close(_ s: Slice) {
        var s = s
        s.fold(keeping: 12)
        fine.append(s)
        file(s, into: &coarse)
        prune(now: s.start)
    }

    /// Adds a five-minute slice to the hour it falls in.
    private func file(_ s: Slice, into tier: inout [Slice]) {
        let hour = (s.start / Self.coarseStep).rounded(.down) * Self.coarseStep
        if var last = tier.last, last.start == hour {
            last.merge(s)
            last.fold(keeping: 16)
            tier[tier.count - 1] = last
        } else {
            var h = s
            h.start = hour
            tier.append(h)
        }
    }

    private func prune(now: TimeInterval) {
        if let first = fine.first, first.start < now - Self.fineKeep {
            fine.removeAll { $0.start < now - Self.fineKeep }
        }
        if let first = coarse.first, first.start < now - Self.coarseKeep {
            coarse.removeAll { $0.start < now - Self.coarseKeep }
        }
    }
}
