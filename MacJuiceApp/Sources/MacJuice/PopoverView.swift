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
            BatteryGlyph(pct: snap.chargePct, onAC: snap.onAC, lowPower: snap.lowPowerMode)
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
        var line: String
        if snap.onAC {
            if snap.fullyCharged {
                line = "Full · plugged in"
            } else if snap.isCharging {
                line = snap.timeRemainingMin.map { "Charging · \(Fmt.hm(Double($0))) to full" } ?? "Charging"
            } else {
                line = "On AC · not charging"
            }
        } else {
            line = snap.timeRemainingMin.map { "Discharging · \(Fmt.hm(Double($0))) left" } ?? "Discharging"
        }
        if snap.lowPowerMode { line += " · Low Power" }
        return line
    }
}

/// A miniature system-style battery: outline, proportional fill in the
/// state tone, bolt when on power. The % text beside it carries the value,
/// so color is never the only channel.
private struct BatteryGlyph: View {
    let pct: Double?
    let onAC: Bool
    let lowPower: Bool

    var body: some View {
        HStack(spacing: 1.5) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(.tertiary, lineWidth: 1.5)
                    .frame(width: 46, height: 23)
                // Concentric with the 7pt shell at 3pt inset: 7 − 3 = 4.
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Theme.batteryTone(pct: pct, onAC: onAC, lowPower: lowPower).gradient)
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
        // Concentric with the 26pt panel at 14pt inset: 26 − 14 = 12.
        .background(.quaternary.opacity(0.45),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Chart

private struct ChartSection: View {
    @EnvironmentObject var model: BatteryModel

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                if #available(macOS 26.0, *) {
                    GlassSegmentedControl(selection: $model.chartMetric,
                                          items: ChartMetric.allCases,
                                          segmentWidth: 55)
                    Spacer(minLength: 6)
                    GlassSegmentedControl(selection: $model.chartRange,
                                          items: ChartRange.allCases,
                                          segmentWidth: 37)
                } else {
                    Picker("", selection: $model.chartMetric) {
                        ForEach(ChartMetric.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    .fixedSize()
                    .focusEffectDisabled()
                    Spacer()
                    Picker("", selection: $model.chartRange) {
                        ForEach(ChartRange.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    .fixedSize()
                    .focusEffectDisabled()
                }
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
    @EnvironmentObject var model: BatteryModel
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
            if model.hiResUntil != nil {
                HStack(spacing: 3) {
                    Image(systemName: "waveform.path.ecg")
                        .font(.system(size: 8.5))
                    Text("HI-RES")
                        .font(.system(size: 9, weight: .semibold))
                }
                .foregroundStyle(Theme.power)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Theme.power.opacity(0.13), in: Capsule())
            }
            Spacer()
            Menu {
                Toggle("Low Power Mode", isOn: lowPowerBinding)
                Divider()
                Toggle("Keep on Top", isOn: $settings.pinPanel)
                Toggle("Launch at Login", isOn: $settings.launchAtLogin)
                Picker("Menu Bar Shows", selection: $settings.labelStyle) {
                    ForEach(LabelStyle.allCases) { Text($0.title).tag($0) }
                }
                Menu("Power Moments") {
                    Toggle("Edge Glow", isOn: $settings.effectGlow)
                    Toggle("Battery Pill", isOn: $settings.effectPill)
                }
                Menu("Alerts") {
                    Toggle("Low Battery (20% / 10%)", isOn: $settings.notifyLowBattery)
                    Toggle("Fully Charged", isOn: $settings.notifyFullyCharged)
                    Toggle("High Temperature", isOn: $settings.notifyHighTemp)
                }
                Divider()
                Button(hiResTitle) { model.toggleHiRes() }
                Divider()
                Button("Copy Stats") { copyStats() }
                Button("Export History as CSV…") { exportCSV() }
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
            .focusEffectDisabled()
            .fixedSize()
        }
    }

    /// Setting Low Power Mode goes through pmset-as-root (no public API), so
    /// the set side hands off to PowerMode and lets the next snapshot confirm
    /// the real state — a cancelled password dialog simply changes nothing.
    private var lowPowerBinding: Binding<Bool> {
        let model = self.model
        return Binding(
            get: { model.live?.lowPowerMode ?? ProcessInfo.processInfo.isLowPowerModeEnabled },
            set: { on in
                PowerMode.setLowPower(on) { ok in
                    if ok { model.updateLive() }
                }
            }
        )
    }

    private var hiResTitle: String {
        if let until = model.hiResUntil {
            let mins = max(Int(until.timeIntervalSinceNow / 60), 0)
            return "Stop Verbose Logging (\(mins) min left)"
        }
        return "Verbose Logging"
    }

    private func copyStats() {
        guard let s = model.live else { return }
        let d = model.derived
        var lines: [String] = []
        lines.append("MacJuice — \(Date().formatted(date: .abbreviated, time: .shortened))")

        var charge = "Charge: " + (s.chargePct.map { "\(Int($0.rounded()))%" } ?? "—")
        if let cur = s.currentMAh, let max = s.maxMAh {
            charge += " (\(Fmt.mAh(cur)) of \(Fmt.mAh(max)))"
        }
        charge += s.onAC ? " — on AC" : " — on battery"
        if let t = s.timeRemainingMin {
            charge += s.onAC ? " · \(Fmt.hm(Double(t))) to full" : " · \(Fmt.hm(Double(t))) left"
        }
        lines.append(charge)

        if let w = s.systemWatts ?? s.watts.map({ abs($0) }) {
            var power = "Draw: \(Fmt.watts(w)) system"
            if let b = s.watts { power += String(format: " · battery %+.1f W", b) }
            lines.append(power)
        }
        var health = "Health: "
        health += s.healthReportedPct.map { Fmt.pct($0) } ?? "—"
        if let raw = s.healthRawPct { health += " reported · \(Fmt.pct(raw, decimals: 1)) raw" }
        if let c = s.cycleCount {
            health += " · \(c) cycles" + (s.designCycles.map { " (of \($0))" } ?? "")
        }
        lines.append(health)

        var env: [String] = []
        if let t = s.tempC { env.append(String(format: "Temperature: %.1f °C", t)) }
        if let v = s.voltageV { env.append(String(format: "Voltage: %.2f V", v)) }
        env.append("Condition: \(s.condition)")
        if let serial = s.serial { env.append("Serial: \(serial)") }
        lines.append(env.joined(separator: " · "))

        if let session = d.currentSession {
            var line = "Session: on battery \(Fmt.hm(Double(session.durationS) / 60)) · −\(Fmt.pct(max(session.pctUsed, 0)))"
            if let r = session.pctPerHour { line += String(format: " · %.1f%%/h", r) }
            lines.append(line)
        }
        if let est = d.estFullRuntimeMin {
            lines.append("Full-charge runtime estimate: ≈ \(Fmt.hm(est))")
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "macjuice-history.csv"
        panel.canCreateDirectories = true
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let store = model.store
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let rows = try store.exportCSV(to: url)
                NSLog("MacJuice: exported \(rows) samples to \(url.path)")
            } catch {
                NSLog("MacJuice: CSV export failed: \(error.localizedDescription)")
            }
        }
    }
}
