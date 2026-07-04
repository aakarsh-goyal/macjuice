import Charts
import SwiftUI

/// Single-series history chart (charge % or battery watts) with hover
/// scrubbing, plug/unplug hairlines in the 24H view, and a recessive
/// hairline grid. One series → no legend; the metric picker names it.
struct HistoryChart: View {
    let points: [HistoryPoint]
    let events: [EventRow]
    let metric: ChartMetric
    let range: ChartRange

    @EnvironmentObject private var model: BatteryModel
    private var hovered: HistoryPoint? { model.chartHover }

    private var accent: Color {
        switch metric {
        case .charge: Theme.charge
        case .power: Theme.power
        case .health: Theme.health
        }
    }

    private var usable: [(date: Date, value: Double)] {
        points.compactMap { p in
            guard let v = value(of: p) else { return nil }
            return (Date(timeIntervalSince1970: TimeInterval(p.ts)), v)
        }
    }

    var body: some View {
        if usable.count < 2 {
            Text("Collecting history…")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.quaternary.opacity(0.25),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            chart
        }
    }

    private var chart: some View {
        Chart {
            if metric == .power {
                RuleMark(y: .value("Zero", 0))
                    .foregroundStyle(.tertiary)
                    .lineStyle(StrokeStyle(lineWidth: 1))
            }
            ForEach(events, id: \.ts) { e in
                RuleMark(x: .value("Event", Date(timeIntervalSince1970: TimeInterval(e.ts))))
                    .foregroundStyle(e.type == "plug_in"
                                     ? Theme.charge.opacity(0.30)
                                     : Color.secondary.opacity(0.22))
                    .lineStyle(StrokeStyle(lineWidth: 1))
            }
            ForEach(usable, id: \.date) { p in
                AreaMark(x: .value("Time", p.date),
                         yStart: .value("Base", areaBase),
                         yEnd: .value(metric.rawValue, p.value))
                    .foregroundStyle(
                        LinearGradient(colors: [accent.opacity(0.16), accent.opacity(0.02)],
                                       startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Time", p.date),
                         y: .value(metric.rawValue, p.value))
                    .foregroundStyle(accent)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.monotone)
            }
            if let last = usable.last, hovered == nil {
                PointMark(x: .value("Time", last.date), y: .value(metric.rawValue, last.value))
                    .symbolSize(110)
                    .foregroundStyle(surface)
                PointMark(x: .value("Time", last.date), y: .value(metric.rawValue, last.value))
                    .symbolSize(52)
                    .foregroundStyle(accent)
            }
            if let h = hovered, let v = value(of: h) {
                RuleMark(x: .value("Hover", Date(timeIntervalSince1970: TimeInterval(h.ts))))
                    .foregroundStyle(Color.secondary.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                PointMark(x: .value("Hover", Date(timeIntervalSince1970: TimeInterval(h.ts))),
                          y: .value(metric.rawValue, v))
                    .symbolSize(110)
                    .foregroundStyle(surface)
                PointMark(x: .value("Hover", Date(timeIntervalSince1970: TimeInterval(h.ts))),
                          y: .value(metric.rawValue, v))
                    .symbolSize(52)
                    .foregroundStyle(accent)
            }
        }
        .chartXScale(domain: xDomain)
        .chartYScale(domain: yDomain)
        .chartPlotStyle { $0.clipped() }
        .chartXAxis {
            AxisMarks(values: xTicks) { _ in
                AxisGridLine(stroke: solidHairline).foregroundStyle(gridStyle)
                AxisValueLabel(format: xFormat)
                    .font(.system(size: 9.5))
                    .foregroundStyle(labelStyle)
            }
        }
        .chartYAxis {
            if metric == .charge {
                AxisMarks(position: .trailing, values: [0.0, 50, 100]) { v in
                    AxisGridLine(stroke: solidHairline).foregroundStyle(gridStyle)
                    AxisValueLabel {
                        if let d = v.as(Double.self) { Text(yLabel(d)) }
                    }
                    .font(.system(size: 9.5))
                    .foregroundStyle(labelStyle)
                }
            } else {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { v in
                    AxisGridLine(stroke: solidHairline).foregroundStyle(gridStyle)
                    AxisValueLabel {
                        if let d = v.as(Double.self) { Text(yLabel(d)) }
                    }
                    .font(.system(size: 9.5))
                    .foregroundStyle(labelStyle)
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let pt):
                            guard let plotFrame = proxy.plotFrame else { return }
                            let origin = geo[plotFrame].origin
                            if let date: Date = proxy.value(atX: pt.x - origin.x) {
                                model.chartHover = nearest(to: date)
                            }
                        case .ended:
                            model.chartHover = nil
                        }
                    }
            }
        }
        .overlay(alignment: .topLeading) {
            if let h = hovered, let v = value(of: h) {
                Text("\(readoutTime(h.ts))  ·  \(yLabel(v, precise: true))")
                    .font(.system(size: 10, weight: .medium))
                    .monospacedDigit()
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .padding(.leading, 2)
            }
        }
    }

    // MARK: - Scales & labels

    // Explicit colors: hierarchical styles inside chart axis builders pick up
    // the chart's tint rather than label grays.
    private var labelStyle: Color { Color(nsColor: .secondaryLabelColor) }
    private var gridStyle: Color { Color(nsColor: .separatorColor).opacity(0.6) }
    private var surface: Color { Color(nsColor: .windowBackgroundColor) }
    private var solidHairline: StrokeStyle { StrokeStyle(lineWidth: 1) }

    /// Explicit, calendar-aligned ticks inside the data span — automatic
    /// placement puts a clipped label in the end-padding.
    private var xTicks: [Date] {
        guard let first = usable.first?.date, let last = usable.last?.date else { return [] }
        let step: TimeInterval
        switch range {
        case .h24: step = 6 * 3600
        case .d7: step = 2 * 24 * 3600
        case .d30: step = 7 * 24 * 3600
        case .all: step = max((last.timeIntervalSince(first) / 4).rounded(), 24 * 3600)
        }
        var ticks: [Date] = []
        let tz = TimeInterval(TimeZone.current.secondsFromGMT())
        var t = ((first.timeIntervalSince1970 + tz) / step).rounded(.up) * step - tz
        // Leave the last ~6% of the span unlabeled so an edge tick's text
        // never truncates against the plot boundary.
        let cutoff = last.timeIntervalSince1970 - last.timeIntervalSince(first) * 0.06
        while t <= cutoff {
            ticks.append(Date(timeIntervalSince1970: t))
            t += step
        }
        return ticks
    }

    private var areaBase: Double {
        metric == .health ? yDomain.lowerBound : 0
    }

    /// Breathing room after the newest point so the end-dot isn't clipped
    /// by the plot edge.
    private var xDomain: ClosedRange<Date> {
        let first = usable.first!.date
        let last = usable.last!.date
        let pad = max(last.timeIntervalSince(first) * 0.025, 60)
        return first...last.addingTimeInterval(pad)
    }

    private var yDomain: ClosedRange<Double> {
        switch metric {
        case .charge:
            return 0...100
        case .power:
            let vals = usable.map(\.value)
            let lo = min(vals.min() ?? 0, 0), hi = max(vals.max() ?? 1, 1)
            let pad = (hi - lo) * 0.12
            return (lo - pad)...(hi + pad)
        case .health:
            // Zoomed band — on a 0–100 axis a healthy battery is a flat line.
            let vals = usable.map(\.value)
            var lo = (vals.min() ?? 99) - 0.5, hi = (vals.max() ?? 101) + 0.5
            if hi - lo < 2 {
                let mid = (hi + lo) / 2
                lo = mid - 1
                hi = mid + 1
            }
            return lo...hi
        }
    }

    private func yLabel(_ v: Double, precise: Bool = false) -> String {
        switch metric {
        case .charge: precise ? Fmt.pct(v) : "\(Int(v))"
        case .power: precise ? Fmt.watts(v) : String(format: "%.0f", v)
        case .health: precise ? Fmt.pct(v, decimals: 1) : String(format: "%.1f", v)
        }
    }

    private var xFormat: Date.FormatStyle {
        switch range {
        case .h24: .dateTime.hour()
        case .d7: .dateTime.weekday(.abbreviated)
        case .d30, .all: .dateTime.month(.abbreviated).day()
        }
    }

    private func readoutTime(_ ts: Int) -> String {
        let d = Date(timeIntervalSince1970: TimeInterval(ts))
        switch range {
        case .h24: return d.formatted(date: .omitted, time: .shortened)
        case .d7: return d.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        case .d30, .all: return d.formatted(.dateTime.month(.abbreviated).day())
        }
    }

    private func value(of p: HistoryPoint) -> Double? {
        switch metric {
        case .charge: p.chargePct
        case .power: p.watts
        case .health: p.healthPct
        }
    }

    private func nearest(to date: Date) -> HistoryPoint? {
        let t = Int(date.timeIntervalSince1970)
        return points
            .filter { value(of: $0) != nil }
            .min(by: { abs($0.ts - t) < abs($1.ts - t) })
    }
}
