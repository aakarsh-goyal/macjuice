import AppKit
import SwiftUI

struct PopoverView: View {
    @EnvironmentObject var model: BatteryModel

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            if let snap = model.live {
                HeaderView(snap: snap)
                StatGrid(snap: snap)
                ChartSection()
                InsightsList(snap: snap)
            } else {
                Text("Reading battery…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            }
            FooterBar(condition: model.live?.condition ?? "Normal")
        }
        .padding(14)
        .frame(width: 360)
    }
}

// MARK: - Header

private struct HeaderView: View {
    let snap: BatterySnapshot

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            BatteryGlyph(pct: snap.chargePct, onAC: snap.onAC)
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(snap.chargePct.map { "\(Int($0.rounded()))" } ?? "—")
                        .font(.system(size: 31, weight: .semibold, design: .rounded))
                    Text("%")
                        .font(.system(size: 17, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                Text(stateLine)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var stateLine: String {
        if snap.onAC {
            if snap.fullyCharged { return "Full · plugged in" }
            if snap.isCharging {
                if let t = snap.timeRemainingMin { return "Charging · \(Fmt.hm(Double(t))) to full" }
                return "Charging"
            }
            return "On AC · not charging"
        }
        if let t = snap.timeRemainingMin { return "Discharging · \(Fmt.hm(Double(t))) left" }
        return "Discharging"
    }
}

/// A miniature system-style battery: outline, proportional fill in the
/// state tone, bolt when on power. The % text beside it carries the value,
/// so color is never the only channel.
private struct BatteryGlyph: View {
    let pct: Double?
    let onAC: Bool

    var body: some View {
        HStack(spacing: 1.5) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(.tertiary, lineWidth: 1.5)
                    .frame(width: 46, height: 23)
                RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                    .fill(Theme.batteryTone(pct: pct, onAC: onAC).gradient)
                    .frame(width: max(4, 40 * (pct ?? 0) / 100), height: 17)
                    .padding(.leading, 3)
                if onAC {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.35), radius: 0.8, y: 0.5)
                        .frame(width: 46)
                }
            }
            RoundedRectangle(cornerRadius: 1.5)
                .fill(.tertiary)
                .frame(width: 2.5, height: 8)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Stat tiles

private struct StatGrid: View {
    let snap: BatterySnapshot

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 7), count: 3),
                  spacing: 7) {
            StatTile(label: "Draw", value: drawValue, sub: drawSub)
            StatTile(label: "Adapter", value: adapterValue, sub: adapterSub)
            StatTile(label: "Temperature", value: tempValue, sub: " ")
            StatTile(label: "Health", value: healthValue, sub: healthSub)
            StatTile(label: "Cycles", value: cyclesValue, sub: cyclesSub)
            StatTile(label: "Charge", value: chargeValue, sub: chargeSub)
        }
    }

    private var drawValue: String {
        if let w = snap.systemWatts ?? snap.watts.map({ abs($0) }) { return Fmt.watts(w) }
        return "—"
    }
    private var drawSub: String {
        if snap.onAC, let b = snap.watts, b > 0.05 { return "+\(Fmt.watts(b)) to battery" }
        return "system"
    }
    private var adapterValue: String {
        guard snap.onAC else { return "—" }
        if let w = snap.adapterRatedWatts { return "\(Int(w)) W" }
        return "AC"
    }
    private var adapterSub: String {
        guard snap.onAC else { return "unplugged" }
        if let inW = snap.adapterInputWatts { return "in \(Fmt.watts(inW))" }
        return " "
    }
    private var tempValue: String {
        snap.tempC.map { String(format: "%.1f°", $0) } ?? "—"
    }
    private var healthValue: String {
        snap.healthReportedPct.map { Fmt.pct($0) } ?? "—"
    }
    private var healthSub: String {
        snap.healthRawPct.map { "raw \(Fmt.pct($0, decimals: 1))" } ?? " "
    }
    private var cyclesValue: String {
        snap.cycleCount.map(String.init) ?? "—"
    }
    private var cyclesSub: String {
        snap.designCycles.map { "of \($0)" } ?? " "
    }
    private var chargeValue: String {
        snap.currentMAh.map { Fmt.mAh($0) } ?? "—"
    }
    private var chargeSub: String {
        snap.maxMAh.map { "of \(Fmt.mAh($0))" } ?? " "
    }
}

private struct StatTile: View {
    let label: String
    let value: String
    let sub: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 14.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(sub)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(.quaternary.opacity(0.45),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: - Chart

private struct ChartSection: View {
    @EnvironmentObject var model: BatteryModel

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Picker("", selection: $model.chartMetric) {
                    ForEach(ChartMetric.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
                Spacer()
                Picker("", selection: $model.chartRange) {
                    ForEach(ChartRange.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
            }
            HistoryChart(points: model.chartPoints,
                         events: model.chartEvents,
                         metric: model.chartMetric,
                         range: model.chartRange)
                .frame(height: 126)
        }
    }
}

// MARK: - Insights

private struct InsightsList: View {
    @EnvironmentObject var model: BatteryModel
    let snap: BatterySnapshot

    var body: some View {
        let rows = buildRows()
        if !rows.isEmpty {
            VStack(spacing: 6) {
                ForEach(rows, id: \.label) { row in
                    HStack(spacing: 6) {
                        Image(systemName: row.icon)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .frame(width: 14)
                        Text(row.label)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(row.value)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                    }
                }
            }
        }
    }

    private struct Row { let icon: String, label: String, value: String }

    private func buildRows() -> [Row] {
        var rows: [Row] = []
        let d = model.derived
        if let s = d.currentSession, s.open, !snap.onAC {
            var v = "\(Fmt.hm(Double(s.durationS) / 60)) · −\(Fmt.pct(max(s.pctUsed, 0)))"
            if let r = s.pctPerHour { v += " · \(String(format: "%.1f", r))%/h" }
            rows.append(Row(icon: "battery.50percent", label: "On battery", value: v))
        } else if let s = d.lastSession {
            rows.append(Row(icon: "clock.arrow.circlepath", label: "Last session",
                            value: "\(Fmt.hm(Double(s.durationS) / 60)) · −\(Fmt.pct(max(s.pctUsed, 0)))"))
        }
        if let est = d.estFullRuntimeMin {
            rows.append(Row(icon: "gauge.with.needle",
                            label: d.estIsShortTerm ? "Full charge (recent use)" : "Full charge lasts",
                            value: "≈ \(Fmt.hm(est))"))
        }
        if let sf = d.sinceFull, sf.elapsedMin < 48 * 60 {
            rows.append(Row(icon: "bolt.badge.checkmark", label: "Since full charge",
                            value: "\(Fmt.hm(sf.elapsedMin)) · −\(Fmt.pct(max(sf.pctUsed, 0)))"))
        }
        if let trend = d.capacityTrendMAhPerMonth {
            rows.append(Row(icon: "chart.line.downtrend.xyaxis", label: "Capacity trend",
                            value: String(format: "%+.0f mAh/mo", trend)))
        }
        return Array(rows.prefix(4))
    }
}

// MARK: - Footer

private struct FooterBar: View {
    @EnvironmentObject var settings: Settings
    let condition: String

    var body: some View {
        HStack(spacing: 8) {
            Text("MacJuice")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            if condition != "Normal" {
                HStack(spacing: 3) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 8.5))
                    Text(condition)
                        .font(.caption2)
                }
                .foregroundStyle(Theme.warn)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Theme.warn.opacity(0.14), in: Capsule())
            }
            Spacer()
            Menu {
                Toggle("Launch at Login", isOn: $settings.launchAtLogin)
                Picker("Menu Bar Shows", selection: $settings.labelStyle) {
                    ForEach(LabelStyle.allCases) { Text($0.title).tag($0) }
                }
                Divider()
                Button("Quit MacJuice") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .menuIndicator(.hidden)
            .buttonStyle(.borderless)
            .fixedSize()
        }
    }
}
