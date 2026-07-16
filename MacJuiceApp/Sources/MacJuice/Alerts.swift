import Foundation
import UserNotifications

/// Turns the snapshots the recorder already sees into native notifications.
/// Purely event-driven — no extra sampling. Every alert has hysteresis so a
/// value hovering around a threshold can't spam.
@MainActor
final class AlertEngine {
    private var notified20 = false
    private var notified10 = false
    private var notifiedFull = false
    private var notifiedHot = false
    private var prevTempHot = false
    private var lastHotNotify: Date?
    private var available = false

    func start() {
        // Bare-binary dev runs (`swift build` output outside the .app) have no
        // bundle identifier and would crash the notification center.
        guard Bundle.main.bundleIdentifier != nil else { return }
        available = true
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func process(_ s: BatterySnapshot, settings: Settings) {
        guard available else { return }

        // Re-arm on state changes. Actively charging below the top also
        // re-arms "full": a charge held at the 80% limit that later resumes
        // (optimized charging, limit turned off) deserves a second alert
        // when it tops out — but trickle at 100% must not re-arm.
        if s.onAC {
            notified20 = false
            notified10 = false
            if s.isCharging, (s.chargePct ?? 100) < 99 { notifiedFull = false }
        } else {
            notifiedFull = false
        }

        if settings.notifyLowBattery, !s.onAC, let pct = s.chargePct {
            if pct <= 10, !notified10 {
                notified10 = true
                notified20 = true
                post("Battery at 10%",
                     s.timeRemainingMin.map { "About \(Fmt.hm(Double($0))) left — plug in soon." }
                        ?? "Plug in soon.")
            } else if pct <= 20, !notified20 {
                notified20 = true
                post("Battery at 20%",
                     s.timeRemainingMin.map { "About \(Fmt.hm(Double($0))) left." } ?? "Running low.")
            }
        }

        if settings.notifyFullyCharged, s.onAC,
           s.fullyCharged || (s.chargePct ?? 0) >= 100, !notifiedFull {
            notifiedFull = true
            post("Fully charged", "100% — you can unplug.")
        }

        if settings.notifyHighTemp, let t = s.tempC {
            if t > 40 {
                // Two consecutive hot readings = sustained, not a blip.
                if prevTempHot, !notifiedHot,
                   lastHotNotify.map({ Date().timeIntervalSince($0) > 3600 }) ?? true {
                    notifiedHot = true
                    lastHotNotify = Date()
                    post("Battery is hot", String(format: "%.1f °C — consider lightening the load.", t))
                }
                prevTempHot = true
            } else {
                prevTempHot = false
                if t < 38 { notifiedHot = false }
            }
        }
    }

    /// A completed charge with its duration — richer than the plain "Fully
    /// charged" line, and the only alert that fires when the 80% charge limit
    /// stops the charge (fullyCharged never goes true there). Marks the
    /// "full" latch so process() doesn't post a duplicate at 100%.
    func chargeCompleted(_ done: ChargeDone, settings: Settings) {
        guard available, settings.notifyFullyCharged, !notifiedFull else { return }
        notifiedFull = true
        let dur = Fmt.hm(Double(done.secs) / 60)
        if done.toPct >= 99.5 {
            post("Fully charged", "Reached 100% in \(dur) (from \(Int(done.fromPct.rounded()))%) — you can unplug.")
        } else {
            post("Charged to \(Int(done.toPct.rounded()))% limit",
                 "Took \(dur) (from \(Int(done.fromPct.rounded()))%).")
        }
    }

    private func post(_ title: String, _ body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString,
                                        content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
}
