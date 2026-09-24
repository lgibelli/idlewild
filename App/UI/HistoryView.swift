// SPDX-FileCopyrightText: 2026 Luca Gibelli
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

// Where the CPU went, drawn as a radial bar chart: time runs clockwise round a
// ring, and each slice of time is a spoke bursting outwards, stacked by app.
//
// The radius is area-true. A spoke's length is not proportional to its value,
// its *area* is - r = sqrt(r0² + k·v) - because a wedge widens as it goes out,
// and a linear radius would make every outer segment look several times larger
// than the same CPU time nearer the ring.

enum HistoryRange: String, CaseIterable, Identifiable {
    case day, week, month
    var id: Self { self }

    var title: String {
        switch self {
        case .day: "24 Hours"
        case .week: "7 Days"
        case .month: "30 Days"
        }
    }

    var caption: String {
        switch self {
        case .day: "The last 24 hours, in five-minute slices"
        case .week: "The last 7 days, by the hour"
        case .month: "The last 30 days, in two-hour slices"
        }
    }

    var step: TimeInterval {
        switch self {
        case .day: 300
        case .week: 3600
        case .month: 7200
        }
    }

    var bins: Int {
        switch self {
        case .day: 288
        case .week: 168
        case .month: 360
        }
    }
}

/// Everything the chart draws, computed once per load rather than per frame.
struct HistoryChart {
    enum Tint: Equatable { case slot(Int), other, system }

    struct Series: Identifiable {
        /// Also the index into each bin's values, centre outwards.
        let id: Int
        let name: String
        let tint: Tint
        /// CPU-seconds over the whole range.
        let total: Double
    }

    let range: HistoryRange
    /// The first bin, in seconds since 1970.
    let start: TimeInterval
    /// Stacking order, centre outwards: what macOS kept to itself, then the
    /// long tail, then the apps from the largest.
    let series: [Series]
    /// Average cores in use, by bin and then by series.
    let values: [[Double]]
    let watched: [Bool]
    /// CPU-seconds used, and what the cores could have given in the time
    /// Idlewild was watching. The second is the budget the first is spent from.
    let used: Double
    let budget: Double
    let cores: Int
    let peak: Double
    let now: TimeInterval
    /// The earliest recorded slice in the range, when the record starts inside it.
    let recordingSince: TimeInterval?
    /// Where bin 0 sits, in turns clockwise from twelve o'clock. The day is a
    /// clock face, midnight at the top; the week and the month start there.
    let turn0: Double

    var binCount: Int { values.count }
    var step: TimeInterval { range.step }

    func turn(ofBin i: Int) -> Double {
        (turn0 + Double(i) / Double(binCount)).truncatingRemainder(dividingBy: 1)
    }

    func turn(of t: TimeInterval) -> Double {
        turn(ofBin: 0) + (t - start) / (step * Double(binCount))
    }

    func bin(atTurn t: Double) -> Int {
        var f = (t - turn0).truncatingRemainder(dividingBy: 1)
        if f < 0 { f += 1 }
        return min(Int(f * Double(binCount)), binCount - 1)
    }

    static let slots = 8

    static func build(_ data: HistoryData, range: HistoryRange, now: Date = Date(),
                      calendar: Calendar = .current) -> HistoryChart {
        let n = range.bins, step = range.step
        let nowT = now.timeIntervalSince1970
        let start: TimeInterval
        switch range {
        case .day:
            start = (nowT / step).rounded(.down) * step - Double(n - 1) * step
        case .week, .month:
            let midnight = calendar.startOfDay(for: now)
            let back = range == .week ? -6 : -29
            start = (calendar.date(byAdding: .day, value: back, to: midnight) ?? midnight)
                .timeIntervalSince1970
        }

        var seen = [Double](repeating: 0, count: n)
        var busy = seen, other = seen
        var apps = [[String: Double]](repeating: [:], count: n)
        var totals: [String: Double] = [:]
        var first: TimeInterval?
        for s in range == .day ? data.fine : data.coarse {
            let i = Int(((s.start - start) / step).rounded(.down))
            guard i >= 0, i < n else { continue }
            seen[i] += s.seen
            busy[i] += s.busy
            other[i] += s.other
            for (k, v) in s.apps {
                apps[i][k, default: 0] += v
                totals[k, default: 0] += v
            }
            if s.seen > 0 { first = min(first ?? s.start, s.start) }
        }

        let ranked = { (m: [String: Double]) in
            m.filter { $0.value > 0 }
                .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
                .map(\.key)
        }
        let top = Array(ranked(totals).prefix(slots))

        // Colour follows the app, not its rank in this range: the month's
        // leaders own their slots in every range, so switching from the week
        // to the day does not repaint an app that appears in both.
        var month: [String: Double] = [:]
        for s in data.coarse { for (k, v) in s.apps { month[k, default: 0] += v } }
        let anchors = Array(ranked(month).prefix(slots))
        var slot: [String: Int] = [:]
        for name in top { if let j = anchors.firstIndex(of: name) { slot[name] = j } }
        var free = (0..<slots).filter { j in !slot.values.contains(j) }
        for name in top where slot[name] == nil { slot[name] = free.removeFirst() }

        let topSet = Set(top)
        var values = [[Double]](repeating: [Double](repeating: 0, count: top.count + 2), count: n)
        var systemTotal = 0.0, otherTotal = 0.0, used = 0.0, watchedSeconds = 0.0, peak = 0.0
        for i in 0..<n where seen[i] > 0 {
            let named = top.map { apps[i][$0] ?? 0 }
            let rest = other[i] + apps[i].filter { !topSet.contains($0.key) }.values.reduce(0, +)
            let attributed = named.reduce(0, +) + rest
            let system = max(0, busy[i] - attributed)
            systemTotal += system
            otherTotal += rest
            used += attributed + system
            watchedSeconds += seen[i]
            values[i] = ([system, rest] + named).map { $0 / seen[i] }
            peak = max(peak, values[i].reduce(0, +))
        }

        let series = [Series(id: 0, name: "System & kernel", tint: .system, total: systemTotal),
                      Series(id: 1, name: "Everything else", tint: .other, total: otherTotal)]
            + top.enumerated().map { j, name in
                Series(id: j + 2, name: name, tint: .slot(slot[name] ?? 0), total: totals[name] ?? 0)
            }

        let turn0: Double
        if range == .day {
            let d = Date(timeIntervalSince1970: start)
            turn0 = d.timeIntervalSince(calendar.startOfDay(for: d)) / 86400
        } else {
            turn0 = 0
        }

        return HistoryChart(range: range, start: start, series: series, values: values,
                            watched: seen.map { $0 > 0 }, used: used,
                            budget: watchedSeconds * Double(data.cores), cores: data.cores,
                            peak: peak, now: nowT,
                            recordingSince: first.flatMap { $0 > start + step ? $0 : nil },
                            turn0: turn0)
    }
}

// MARK: - Palette

/// The reference categorical palette, stepped separately for light and dark
/// surfaces, and two neutrals for the parts that are not an app. Colour carries
/// identity only alongside the legend and the tooltip, never alone.
private struct Palette {
    let dark: Bool

    private static let light = [0x2a78d6, 0xeb6834, 0x1baf7a, 0xeda100, 0xe87ba4, 0x008300, 0x4a3aa7, 0xe34948]
    private static let darkSteps = [0x3987e5, 0xd95926, 0x199e70, 0xc98500, 0xd55181, 0x008300, 0x9085e9, 0xe66767]

    func tint(_ t: HistoryChart.Tint) -> Color {
        switch t {
        case .slot(let i): hex((dark ? Self.darkSteps : Self.light)[i % Self.light.count])
        case .other: hex(dark ? 0x4a4945 : 0xcfcec7)
        case .system: hex(dark ? 0x7a7973 : 0x9a9891)
        }
    }

    var surface: Color { hex(dark ? 0x1a1a19 : 0xfcfcfb) }
    var ink: Color { hex(dark ? 0xffffff : 0x0b0b0b) }
    var secondary: Color { hex(dark ? 0xc3c2b7 : 0x52514e) }
    var muted: Color { hex(0x898781) }
    var grid: Color { hex(dark ? 0x2c2c2a : 0xe1e0d9) }
    var baseline: Color { hex(dark ? 0x383835 : 0xc3c2b7) }
    var card: Color { hex(dark ? 0x262625 : 0xffffff) }

    private func hex(_ v: Int) -> Color {
        Color(red: Double((v >> 16) & 0xff) / 255, green: Double((v >> 8) & 0xff) / 255,
              blue: Double(v & 0xff) / 255)
    }
}

// MARK: - Formatting

private func hoursText(_ seconds: Double) -> String {
    let h = seconds / 3600
    if seconds < 60 { return "\(Int(seconds.rounded())) s" }
    if h < 0.1 { return "\(Int((seconds / 60).rounded())) min" }
    return h < 10 ? String(format: "%.1f h", h) : String(format: "%.0f h", h)
}

private func coresText(_ v: Double) -> String {
    if v < 0.01 { return "0" }
    return v < 10 ? String(format: "%.2f", v) : String(format: "%.1f", v)
}

private func percentText(_ f: Double) -> String {
    let p = f * 100
    if p > 0, p < 0.1 { return "<0.1%" }
    return p < 10 ? String(format: "%.1f%%", p) : String(format: "%.0f%%", p)
}

// MARK: - Window

struct HistoryView: View {
    let load: () async -> HistoryData
    let clear: () -> Void

    @Environment(\.colorScheme) private var scheme
    @State private var range: HistoryRange = .day
    @State private var chart: HistoryChart?
    @State private var progress: Double = 0
    @State private var focus: Int?
    @State private var confirmClear = false

    private var palette: Palette { Palette(dark: scheme == .dark) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            HStack(alignment: .top, spacing: 28) {
                RadialPanel(chart: chart, progress: progress, focus: $focus, palette: palette)
                    .frame(width: 560, height: 560)
                if let chart {
                    Legend(chart: chart, focus: $focus, palette: palette)
                        .frame(width: 250)
                }
            }
            footer
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 22)
        .frame(width: 900)
        .background(palette.surface)
        .task(id: range) {
            await refresh(animated: true)
            // Slices close every five minutes; keep the open window current
            // without redrawing it any more often than that matters.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                if Task.isCancelled { break }
                await refresh(animated: false)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Where the CPU went")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(palette.ink)
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(palette.secondary)
            }
            Spacer()
            Picker("Range", selection: $range) {
                ForEach(HistoryRange.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 270)
        }
    }

    private var subtitle: String {
        guard let chart else { return range.caption }
        if let since = chart.recordingSince {
            let f = DateFormatter()
            f.setLocalizedDateFormatFromTemplate(range == .day ? "HH:mm" : "d MMM HH:mm")
            return range.caption + ", recorded since " + f.string(from: Date(timeIntervalSince1970: since))
        }
        return range.caption
    }

    private var footer: some View {
        HStack(alignment: .top, spacing: 16) {
            Text("**System & kernel** is CPU time macOS will not let an app attribute: processes that belong to root or to other users, the kernel itself, and programs that start and finish between two scans. The history is kept on this Mac only.")
                .font(.caption)
                .foregroundStyle(palette.muted)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            Button("Clear History\u{2026}") { confirmClear = true }
                .controlSize(.small)
                .confirmationDialog("Clear the CPU history?", isPresented: $confirmClear) {
                    Button("Clear History", role: .destructive) {
                        clear()
                        Task { await refresh(animated: true) }
                    }
                } message: {
                    Text("Everything recorded so far is deleted. Recording carries on from now.")
                }
        }
    }

    private func refresh(animated: Bool) async {
        let data = await load()
        chart = HistoryChart.build(data, range: range)
        guard animated else { return }
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { progress = 0 }
        try? await Task.sleep(for: .milliseconds(30))
        withAnimation(.easeOut(duration: 1.2)) { progress = 1 }
    }
}

// MARK: - The chart

private struct RadialPanel: View {
    let chart: HistoryChart?
    let progress: Double
    @Binding var focus: Int?
    let palette: Palette
    @State private var hover: CGPoint?

    var body: some View {
        GeometryReader { geo in
            let g = Geometry(size: geo.size)
            ZStack {
                if let chart {
                    RadialChart(chart: chart, geometry: g, progress: progress, focus: focus,
                                hoverBin: hoverBin(chart, g), palette: palette)
                    Hero(chart: chart, focus: focus, palette: palette)
                        .frame(width: g.inner * 1.6)
                        .position(g.center)
                        .allowsHitTesting(false)
                    if let p = hover, let bin = hoverBin(chart, g) {
                        Tooltip(chart: chart, bin: bin, palette: palette)
                            .fixedSize()
                            .modifier(Follow(point: p, bounds: geo.size))
                            .allowsHitTesting(false)
                    }
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let p): hover = p
                case .ended: hover = nil
                }
            }
        }
    }

    private func hoverBin(_ chart: HistoryChart, _ g: Geometry) -> Int? {
        guard let p = hover else { return nil }
        let dx = p.x - g.center.x, dy = p.y - g.center.y
        let d = (dx * dx + dy * dy).squareRoot()
        guard d >= g.inner - 14, d <= g.outer + 14 else { return nil }
        var t = atan2(dx, -dy) / (2 * .pi)
        if t < 0 { t += 1 }
        return chart.bin(atTurn: t)
    }
}

/// Places the tooltip beside the pointer, flipping to the other side near an
/// edge so it never leaves the chart.
private struct Follow: ViewModifier {
    let point: CGPoint
    let bounds: CGSize
    @State private var size: CGSize = .zero

    func body(content: Content) -> some View {
        content
            .background(GeometryReader { g in
                Color.clear.onAppear { size = g.size }.onChange(of: g.size) { _, s in size = s }
            })
            .position(x: clamp(point.x + (point.x + 18 + size.width > bounds.width
                                          ? -(size.width / 2 + 18) : size.width / 2 + 18),
                               size.width / 2, bounds.width - size.width / 2),
                      y: clamp(point.y + (point.y + 18 + size.height > bounds.height
                                          ? -(size.height / 2 + 12) : size.height / 2 + 12),
                               size.height / 2, bounds.height - size.height / 2))
    }

    private func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
        min(max(v, lo), max(lo, hi))
    }
}

private struct Geometry {
    let size: CGSize
    var center: CGPoint { CGPoint(x: size.width / 2, y: size.height / 2) }
    var side: CGFloat { min(size.width, size.height) }
    /// The ring the spokes grow from, wide enough to hold the headline.
    var inner: CGFloat { side * 0.2 }
    /// Room outside for the clock labels.
    var outer: CGFloat { side / 2 - 34 }

    func point(_ r: CGFloat, _ turn: Double) -> CGPoint {
        let a = turn * 2 * .pi - .pi / 2
        return CGPoint(x: center.x + r * cos(a), y: center.y + r * sin(a))
    }
}

private struct RadialChart: View, Animatable {
    let chart: HistoryChart
    let geometry: Geometry
    var progress: Double
    let focus: Int?
    let hoverBin: Int?
    let palette: Palette

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    /// The top of the scale: the busiest slice, rounded up to a figure the
    /// rings can be labelled with.
    private var scaleMax: Double {
        let steps: [Double] = [0.25, 0.5, 1, 1.5, 2, 3, 4, 6, 8, 12, 16, 24, 32, 48, 64, 96, 128]
        return steps.first { $0 >= chart.peak } ?? chart.peak
    }

    private func radius(_ v: Double) -> CGFloat {
        let r0 = geometry.inner, r1 = geometry.outer
        let f = min(max(v / scaleMax, 0), 1)
        return (r0 * r0 + (r1 * r1 - r0 * r0) * f).squareRoot()
    }

    var body: some View {
        Canvas { ctx, _ in
            let g = geometry
            drawGrid(&ctx, g)
            if let b = hoverBin { drawHover(&ctx, g, bin: b) }
            drawSpokes(&ctx, g)
            drawClock(&ctx, g)
            drawNow(&ctx, g)
        }
    }

    private func drawGrid(_ ctx: inout GraphicsContext, _ g: Geometry) {
        let rings = [scaleMax / 4, scaleMax / 2, scaleMax]
        for v in rings {
            let r = radius(v)
            ctx.stroke(Path(ellipseIn: CGRect(x: g.center.x - r, y: g.center.y - r, width: 2 * r, height: 2 * r)),
                       with: .color(palette.grid), lineWidth: 1)
        }
        let r0 = g.inner
        ctx.stroke(Path(ellipseIn: CGRect(x: g.center.x - r0, y: g.center.y - r0, width: 2 * r0, height: 2 * r0)),
                   with: .color(palette.baseline), lineWidth: 1)
        // Ring labels ride the twelve o'clock line, on the surface so a spoke
        // running under one cannot swallow it.
        for v in rings {
            let r = radius(v)
            let label = v == 1 ? "1 core" : String(format: "%g cores", v)
            let text = ctx.resolve(Text(label).font(.system(size: 9.5, weight: .medium))
                .foregroundColor(palette.muted))
            let size = text.measure(in: CGSize(width: 200, height: 40))
            let at = CGPoint(x: g.center.x + 5, y: g.center.y - r)
            let pill = CGRect(x: at.x - 3, y: at.y - size.height / 2 - 1,
                              width: size.width + 6, height: size.height + 2)
            ctx.fill(Path(roundedRect: pill, cornerRadius: 3), with: .color(palette.surface.opacity(0.85)))
            ctx.draw(text, at: at, anchor: .leading)
        }
    }

    private func drawHover(_ ctx: inout GraphicsContext, _ g: Geometry, bin: Int) {
        let a0 = chart.turn(ofBin: bin), a1 = a0 + 1 / Double(chart.binCount)
        let widen = 0.5 / Double(chart.binCount)
        var p = Path()
        quad(&p, g, g.inner, g.outer + 6, a0 - widen, a1 + widen)
        ctx.fill(p, with: .color(palette.ink.opacity(0.07)))
    }

    private func drawSpokes(_ ctx: inout GraphicsContext, _ g: Geometry) {
        let n = chart.binCount
        let slot = 1 / Double(n)
        let gap = slot * 0.24
        var paths = [Path](repeating: Path(), count: chart.series.count)
        for i in 0..<n where chart.watched[i] {
            // Each spoke grows in turn, oldest first, so the chart replays the
            // period as it draws.
            let delay = 0.4 * Double(i) / Double(n)
            let local = min(max((progress - delay) / 0.6, 0), 1)
            let grow = 1 - pow(1 - local, 3)
            guard grow > 0 else { continue }
            let a0 = chart.turn(ofBin: i) + gap / 2, a1 = a0 + slot - gap
            var cum = 0.0
            var r = g.inner
            for (s, v) in chart.values[i].enumerated() where v > 0 {
                cum += v
                let next = radius(cum * grow)
                if next - r > 0.15 { quad(&paths[s], g, r, next, a0, a1) }
                r = next
            }
        }
        for s in chart.series {
            let dim = focus != nil && focus != s.id
            ctx.fill(paths[s.id], with: .color(palette.tint(s.tint).opacity(dim ? 0.16 : 1)))
        }
    }

    /// Wedges are a few pixels wide at most, so a chord is indistinguishable
    /// from the arc and a quadrilateral is all a segment needs.
    private func quad(_ p: inout Path, _ g: Geometry, _ r0: CGFloat, _ r1: CGFloat, _ a0: Double, _ a1: Double) {
        p.move(to: g.point(r0, a0))
        p.addLine(to: g.point(r1, a0))
        p.addLine(to: g.point(r1, a1))
        p.addLine(to: g.point(r0, a1))
        p.closeSubpath()
    }

    private func drawClock(_ ctx: inout GraphicsContext, _ g: Geometry) {
        let labelR = g.outer + 18
        var ticks = Path()
        var dividers = Path()
        switch chart.range {
        case .day:
            for h in 0..<24 {
                let t = Double(h) / 24
                ticks.move(to: g.point(g.outer + 3, t))
                ticks.addLine(to: g.point(g.outer + (h % 3 == 0 ? 8 : 5), t))
                guard h % 3 == 0 else { continue }
                let major = h % 6 == 0
                let text = Text(String(format: "%02d", h))
                    .font(.system(size: major ? 11 : 10, weight: major ? .semibold : .regular))
                    .foregroundColor(major ? palette.secondary : palette.muted)
                ctx.draw(text, at: g.point(labelR, t), anchor: .center)
            }
        case .week, .month:
            let days = chart.range == .week ? 7 : 30
            let cal = Calendar.current
            let f = DateFormatter()
            f.setLocalizedDateFormatFromTemplate(chart.range == .week ? "EEE" : "d MMM")
            for d in 0..<days {
                let t = Double(d) / Double(days)
                let weekly = chart.range == .week || d % 7 == 0
                if chart.range == .week {
                    dividers.move(to: g.point(g.inner, t))
                    dividers.addLine(to: g.point(g.outer, t))
                }
                ticks.move(to: g.point(g.outer + 3, t))
                ticks.addLine(to: g.point(g.outer + (weekly ? 8 : 5), t))
                guard weekly else { continue }
                let day = cal.date(byAdding: .day, value: d, to: Date(timeIntervalSince1970: chart.start)) ?? Date()
                let today = cal.isDateInToday(day)
                // A week's labels name the whole day, so they sit mid-segment;
                // a month's mark a date, so they sit on its tick.
                let at = chart.range == .week ? t + 0.5 / Double(days) : t
                // Today by weight rather than by a word: the names come from the
                // user's locale, and an English "Today" among them would not.
                let text = Text(f.string(from: day))
                    .font(.system(size: 10.5, weight: today ? .semibold : .regular))
                    .foregroundColor(today ? palette.secondary : palette.muted)
                ctx.draw(text, at: g.point(labelR, at), anchor: .center)
            }
        }
        ctx.stroke(dividers, with: .color(palette.grid), lineWidth: 1)
        ctx.stroke(ticks, with: .color(palette.baseline), lineWidth: 1)
    }

    private func drawNow(_ ctx: inout GraphicsContext, _ g: Geometry) {
        let t = chart.turn(of: chart.now)
        var p = Path()
        p.move(to: g.point(g.inner - 7, t))
        p.addLine(to: g.point(g.outer + 2, t))
        ctx.stroke(p, with: .color(palette.ink.opacity(0.4)), lineWidth: 1)
        let dot = g.point(g.inner - 7, t)
        ctx.fill(Path(ellipseIn: CGRect(x: dot.x - 3, y: dot.y - 3, width: 6, height: 6)),
                 with: .color(palette.ink.opacity(0.75)))
    }
}

/// The one number the view leads with: how much of the machine's CPU was
/// spent, against what its cores could have given in the same time.
private struct Hero: View {
    let chart: HistoryChart
    let focus: Int?
    let palette: Palette

    var body: some View {
        let s = focus.flatMap { f in chart.series.first { $0.id == f } }
        let seconds = s?.total ?? chart.used
        VStack(spacing: 2) {
            Text(String(format: seconds / 3600 < 10 ? "%.1f" : "%.0f", seconds / 3600))
                .font(.system(size: 38, weight: .semibold))
                .foregroundStyle(palette.ink)
            Text(s.map { $0.name } ?? "CPU hours used")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(palette.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(s == nil
                 ? "\(percentText(chart.budget > 0 ? chart.used / chart.budget : 0)) of \(chart.cores) cores"
                 : "CPU hours, \(percentText(chart.used > 0 ? seconds / chart.used : 0)) of all used")
                .font(.system(size: 10))
                .foregroundStyle(palette.muted)
        }
        .multilineTextAlignment(.center)
    }
}

private struct Tooltip: View {
    let chart: HistoryChart
    let bin: Int
    let palette: Palette

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(when)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(palette.ink)
            if chart.watched[bin] {
                let v = chart.values[bin]
                Text("\(coresText(v.reduce(0, +))) cores in use")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.secondary)
                let rows = chart.series.filter { v[$0.id] >= 0.005 }
                    .sorted { v[$0.id] > v[$1.id] }.prefix(7)
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(rows)) { s in
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(palette.tint(s.tint))
                                .frame(width: 8, height: 8)
                            Text(s.name).lineLimit(1)
                                .foregroundStyle(palette.secondary)
                            Spacer(minLength: 12)
                            Text(coresText(v[s.id])).monospacedDigit()
                                .foregroundStyle(palette.ink)
                        }
                        .font(.system(size: 11))
                    }
                }
            } else {
                Text(chart.start + Double(bin) * chart.step > chart.now
                     ? "Not yet"
                     : "Nothing recorded: the Mac was asleep, or Idlewild was not watching")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.muted)
                    .frame(maxWidth: 200, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(minWidth: 170, alignment: .leading)
        .background(palette.card, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(palette.ink.opacity(0.1)))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
    }

    private var when: String {
        let a = Date(timeIntervalSince1970: chart.start + Double(bin) * chart.step)
        let b = a.addingTimeInterval(chart.step)
        let time = DateFormatter()
        time.setLocalizedDateFormatFromTemplate("HH:mm")
        let day = DateFormatter()
        day.setLocalizedDateFormatFromTemplate(chart.range == .week ? "EEEE" : "EEE d MMM")
        let span = time.string(from: a) + "\u{2009}\u{2013}\u{2009}" + time.string(from: b)
        return chart.range == .day ? span : day.string(from: a) + ", " + span
    }
}

/// The ranked table beside the chart, which is also its legend. Hovering a row
/// picks that app out in the chart.
private struct Legend: View {
    let chart: HistoryChart
    @Binding var focus: Int?
    let palette: Palette

    var body: some View {
        let apps = chart.series.filter { if case .slot = $0.tint { true } else { false } }
        let rest = chart.series.filter { if case .slot = $0.tint { false } else { true } }
        VStack(alignment: .leading, spacing: 4) {
            Text("By app")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(palette.muted)
                .padding(.bottom, 4)
            if apps.isEmpty {
                Text("Nothing recorded in this range yet. Idlewild files CPU time as it scans; the first slices appear within five minutes.")
                    .font(.callout)
                    .foregroundStyle(palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(apps) { row($0) }
            if !rest.isEmpty && chart.used > 0 {
                Rectangle().fill(palette.grid).frame(height: 1).padding(.vertical, 6)
                ForEach(rest.reversed()) { row($0) }
            }
        }
    }

    private func row(_ s: HistoryChart.Series) -> some View {
        let share = chart.used > 0 ? s.total / chart.used : 0
        let dim = focus != nil && focus != s.id
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 2.5)
                    .fill(palette.tint(s.tint))
                    .frame(width: 10, height: 10)
                Text(s.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(palette.ink)
                Spacer(minLength: 6)
                Text(hoursText(s.total))
                    .monospacedDigit()
                    .foregroundStyle(palette.secondary)
                Text(percentText(share))
                    .monospacedDigit()
                    .foregroundStyle(palette.muted)
                    .frame(width: 42, alignment: .trailing)
            }
            .font(.system(size: 12))
            GeometryReader { g in
                Capsule()
                    .fill(palette.tint(s.tint))
                    .frame(width: max(2, g.size.width * share), height: 3)
            }
            .frame(height: 3)
            .padding(.leading, 18)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(palette.ink.opacity(focus == s.id ? 0.06 : 0)))
        .opacity(dim ? 0.45 : 1)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { focus = s.id } else if focus == s.id { focus = nil }
        }
    }
}
