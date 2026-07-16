import Foundation
import Combine

enum ChartRange: String, CaseIterable, Identifiable {
    case h24 = "24H", d7 = "7D", d30 = "30D", all = "ALL"
    var id: String { rawValue }

    var seconds: Int? {
        switch self {
        case .h24: 24 * 3600
        case .d7: 7 * 24 * 3600
        case .d30: 30 * 24 * 3600
        case .all: nil
        }
    }
}

enum ChartMetric: String, CaseIterable, Identifiable {
    case charge = "Charge", power = "Power", health = "Health"
    var id: String { rawValue }
}

struct DerivedStats {
    var estFullRuntimeMin: Double?      // medium-term (4h window), short-term fallback
    var estIsShortTerm = false
    var sinceFull: (elapsedMin: Double, pctUsed: Double)?
    var currentSession: DischargeSession?
    var lastSession: DischargeSession?
    var capacityTrendMAhPerMonth: Double?
    var lastCharge: ChargeDone?
    /// Open charge session (plugged in, no unplug since): when and at what %
    /// the charger went in — feeds the live "Charging for" row.
    var chargeStart: (ts: Int, pct: Double?)?
}

/// Single observable source of truth for the status item and the popover.
/// Live snapshots are pushed by the recorder / power-source notifications;
/// derived stats and chart data are pulled from the store off the main thread.
@MainActor
final class BatteryModel: ObservableObject {
    @Published var live: BatterySnapshot?
    @Published var derived = DerivedStats()
    @Published var chartPoints: [HistoryPoint] = []
    @Published var chartEvents: [EventRow] = []
    @Published var chartRange: ChartRange = .h24 { didSet { reloadChart() } }
    @Published var chartMetric: ChartMetric = .charge
    /// Hover scrub position for the history chart. Lives here rather than in
    /// view @State because the CLT toolchain lacks SwiftUI's macro plugin.
    @Published var chartHover: HistoryPoint?

    /// True while a Low Power Mode switch is in flight (the Shortcuts route
    /// can take a few seconds cold) — the header glyph dims meanwhile.
    @Published var lpmSwitching = false

    /// End of the current high-resolution logging window, nil when off.
    @Published var hiResUntil: Date?
    /// Wired by the recorder; true = start an hour of 10 s sampling, false = stop.
    var hiResHandler: ((Bool) -> Void)?

    func toggleHiRes() {
        hiResHandler?(hiResUntil == nil)
    }

    let store: Store
    private var liveTimer: Timer?

    init(store: Store) {
        self.store = store
    }

    func updateLive() {
        if let snap = BatteryReader.read() { live = snap }
    }

    /// Flip Low Power Mode from the header battery glyph. The set side goes
    /// through PowerMode's password-free route chain; a cancelled or failed
    /// switch simply leaves the real state unchanged.
    func toggleLowPower() {
        guard !lpmSwitching else { return }
        let target = !(live?.lowPowerMode ?? ProcessInfo.processInfo.isLowPowerModeEnabled)
        lpmSwitching = true
        PowerMode.setLowPower(target) { [weak self] ok in
            self?.lpmSwitching = false
            if ok { self?.updateLive() }
        }
    }

    /// 2s cadence while (and only while) the popover is open.
    func beginLiveUpdates() {
        updateLive()
        reloadDerived()
        reloadChart()
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateLive() }
        }
        t.tolerance = 0.5
        RunLoop.main.add(t, forMode: .common)
        liveTimer = t
    }

    func endLiveUpdates() {
        liveTimer?.invalidate()
        liveTimer = nil
    }

    var popoverIsLive: Bool { liveTimer != nil }

    func reloadDerived() {
        let store = self.store
        DispatchQueue.global(qos: .userInitiated).async {
            let now = Int(Date().timeIntervalSince1970)
            let fullTs = store.lastEventTs(type: "full_charge")
            let weekAgo = now - 7 * 24 * 3600
            let rows = store.rows(since: min(weekAgo, fullTs ?? weekAgo))
            let weekRows = rows.filter { $0.ts >= weekAgo }

            var d = DerivedStats()
            d.sinceFull = Analytics.sinceFullCharge(rows, fullChargeTs: fullTs)
            let sessions = Analytics.sessions(weekRows)
            d.currentSession = sessions.last?.open == true ? sessions.last : nil
            d.lastSession = sessions.last(where: { !$0.open })

            // Runtime projection only from rows inside a single discharge
            // session — a window straddling a charge stretch nets out to a
            // near-zero rate and projects absurd runtimes.
            if let cur = d.currentSession {
                let sessionRows = weekRows.filter { $0.ts >= cur.startTs && $0.charging == 0 }
                if let est = Analytics.fullRuntimeEstimate(sessionRows, windowS: 4 * 3600) {
                    d.estFullRuntimeMin = est
                } else if let est = Analytics.fullRuntimeEstimate(sessionRows, windowS: 30 * 60) {
                    d.estFullRuntimeMin = est
                    d.estIsShortTerm = true
                }
            }
            if d.estFullRuntimeMin == nil, let last = d.lastSession, let rate = last.pctPerHour {
                d.estFullRuntimeMin = 100 / rate * 60
            }
            // Anything projecting past 48h is noise, not a runtime.
            if let est = d.estFullRuntimeMin, est > 48 * 60 { d.estFullRuntimeMin = nil }
            d.lastCharge = store.lastChargeDone().flatMap { now - $0.ts <= 7 * 24 * 3600 ? $0 : nil }
            if let plugTs = store.lastEventTs(type: "plug_in"),
               plugTs > (store.lastEventTs(type: "unplug") ?? 0) {
                d.chargeStart = (plugTs, store.chargePctAt(ts: plugTs))
            }
            if let cap = store.capacityEndpoints(), cap.last.ts - cap.first.ts >= 14 * 24 * 3600 {
                let months = Double(cap.last.ts - cap.first.ts) / (30 * 24 * 3600)
                d.capacityTrendMAhPerMonth = (cap.last.mAh - cap.first.mAh) / months
            }
            DispatchQueue.main.async { self.derived = d }
        }
    }

    func reloadChart() {
        let store = self.store
        let range = chartRange
        DispatchQueue.global(qos: .userInitiated).async {
            let now = Int(Date().timeIntervalSince1970)
            let start: Int
            let bucket: Int
            switch range {
            case .h24: start = now - range.seconds!; bucket = 600
            case .d7: start = now - range.seconds!; bucket = 3600
            case .d30: start = now - range.seconds!; bucket = 3 * 3600
            case .all:
                let first = store.firstSampleTs() ?? now
                start = first
                bucket = max((now - first) / 300, 3600)
            }
            let points = store.history(since: start, bucketSeconds: bucket)
            let events = range == .h24 ? store.events(since: start).filter {
                $0.type == "plug_in" || $0.type == "unplug"
            } : []
            DispatchQueue.main.async {
                self.chartPoints = points
                self.chartEvents = events
            }
        }
    }
}
