import Foundation

struct DischargeSession {
    let startTs: Int
    let endTs: Int
    let pctUsed: Double
    let open: Bool          // still discharging now

    var durationS: Int { max(endTs - startTs, 0) }
    var pctPerHour: Double? {
        guard durationS > 600, pctUsed > 0 else { return nil }
        return pctUsed / (Double(durationS) / 3600)
    }
}

/// Pure derived metrics — a direct port of the Python `analytics.py`, same
/// windows and same guard rails, operating on rows from the shared database.
enum Analytics {

    /// Δ%/hour over a row window; positive only, like the original.
    static func dischargeRate(_ rows: [SampleRow]) -> (pctPerHour: Double?, avgWatts: Double?) {
        let usable = rows.filter { $0.chargePct != nil }
        guard let first = usable.first, let last = usable.last, usable.count >= 2 else { return (nil, nil) }
        let dt = last.ts - first.ts
        guard dt > 0, dt <= 7 * 24 * 3600 else { return (nil, nil) }
        let dpct = first.chargePct! - last.chargePct!
        let watts = usable.compactMap { $0.watts }.map(abs)
        let avg = watts.isEmpty ? nil : watts.reduce(0, +) / Double(watts.count)
        return (dpct >= 0 ? dpct / (Double(dt) / 3600) : nil, avg)
    }

    /// Estimated minutes a full charge would last, from a trailing window.
    static func fullRuntimeEstimate(_ rows: [SampleRow], windowS: Int, minSamples: Int = 5) -> Double? {
        guard let lastTs = rows.last?.ts else { return nil }
        let window = rows.filter { $0.ts >= lastTs - windowS }
        guard window.count >= minSamples else { return nil }
        guard let rate = dischargeRate(window).pctPerHour, rate > 0 else { return nil }
        return 100 / rate * 60
    }

    /// Time elapsed and percent used since the last full-charge event.
    static func sinceFullCharge(_ rows: [SampleRow], fullChargeTs: Int?) -> (elapsedMin: Double, pctUsed: Double)? {
        guard let fullTs = fullChargeTs else { return nil }
        let after = rows.filter { $0.ts >= fullTs && $0.chargePct != nil }
        guard after.count >= 2, let f = after.first, let l = after.last, l.ts > f.ts else { return nil }
        return (Double(l.ts - f.ts) / 60, f.chargePct! - l.chargePct!)
    }

    /// Discharge sessions: a charging→discharging transition opens one, the
    /// reverse closes it; a still-open tail session is included and flagged.
    static func sessions(_ rows: [SampleRow], minDurationS: Int = 120) -> [DischargeSession] {
        let usable = rows.filter { $0.charging != nil && $0.chargePct != nil }
        var out: [DischargeSession] = []
        var start: SampleRow?
        var prev: SampleRow?
        for r in usable {
            if let p = prev {
                if p.charging == 1 && r.charging == 0 {
                    start = r
                } else if p.charging == 0 && r.charging == 1, let s = start {
                    out.append(DischargeSession(startTs: s.ts, endTs: r.ts,
                                                pctUsed: s.chargePct! - r.chargePct!, open: false))
                    start = nil
                }
            }
            prev = r
        }
        if let s = start, let p = prev, p.ts != s.ts {
            out.append(DischargeSession(startTs: s.ts, endTs: p.ts,
                                        pctUsed: s.chargePct! - p.chargePct!, open: true))
        }
        return out.filter { $0.durationS >= minDurationS }
    }
}
