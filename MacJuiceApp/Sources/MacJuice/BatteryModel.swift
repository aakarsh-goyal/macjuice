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
    case charge = "Charge", power = "Power"
    var id: String { rawValue }
}

struct DerivedStats {
    var estFullRuntimeMin: Double?      // medium-term (4h window), short-term fallback
    var estIsShortTerm = false
    var sinceFull: (elapsedMin: Double, pctUsed: Double)?
    var currentSession: DischargeSession?
    var lastSession: DischargeSession?
    var capacityTrendMAhPerMonth: Double?
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

    let store: Store
    private var liveTimer: Timer?

    init(store: Store) {
        self.store = store
    }

    func updateLive() {
        if let snap = BatteryReader.read() { live = snap }
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
            if let est = Analytics.fullRuntimeEstimate(weekRows, windowS: 4 * 3600) {
                d.estFullRuntimeMin = est
            } else if let est = Analytics.fullRuntimeEstimate(weekRows, windowS: 30 * 60) {
                d.estFullRuntimeMin = est
                d.estIsShortTerm = true
            }
            d.sinceFull = Analytics.sinceFullCharge(rows, fullChargeTs: fullTs)
            let sessions = Analytics.sessions(weekRows)
            d.currentSession = sessions.last?.open == true ? sessions.last : nil
            d.lastSession = sessions.last(where: { !$0.open })
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
