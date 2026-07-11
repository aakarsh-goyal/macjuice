import AppKit
import Foundation
import IOKit.ps

/// The native replacement for the Python collector daemon.
///
/// Power budget: a system-coalesced background activity every ~120s does one
/// IORegistry read and one SQLite row insert (microseconds of CPU), and the
/// power-sources runloop callback fires only when macOS itself detects a
/// change (percent step, plug/unplug). No polling loops, no subprocesses,
/// no power assertions — the Mac sleeps exactly as it would without us.
@MainActor
final class Recorder {
    static let sampleInterval: TimeInterval = 120

    private let store: Store
    private let model: BatteryModel
    private let alerts = AlertEngine()
    private var scheduler: NSBackgroundActivityScheduler?
    private var powerSource: CFRunLoopSource?
    private var hiResTimer: Timer?
    private var prevPct: Double?
    private var prevCharging: Int?
    private var cachedModelName: String?

    init(store: Store, model: BatteryModel) {
        self.store = store
        self.model = model
    }

    func start() {
        if let last = store.latestState() {
            prevPct = last.chargePct
            prevCharging = last.charging
        }
        resolveModelName()
        recordSample()

        let s = NSBackgroundActivityScheduler(identifier: "com.macjuice.app.sample")
        s.repeats = true
        s.interval = Self.sampleInterval
        s.tolerance = Self.sampleInterval / 2
        s.qualityOfService = .utility
        s.schedule { [weak self] completion in
            DispatchQueue.main.async {
                self?.recordSample()
                completion(.finished)
            }
        }
        scheduler = s

        // Instant UI + precise event timestamps on plug/unplug/percent changes.
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        if let src = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let me = Unmanaged<Recorder>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { me.powerSourcesChanged() }
        }, ctx)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
            powerSource = src
        }

        // Low Power Mode toggles don't fire a power-source callback; refresh
        // the UI (glyph tint, state line) the moment the mode changes.
        NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            self?.model.updateLive()
        }

        model.hiResHandler = { [weak self] on in self?.setHiRes(on) }
        alerts.start()
    }

    /// High-resolution logging: one sample every 10 s for an hour (or until
    /// stopped). An opt-in trade of a little power for benchmark-grade data.
    func setHiRes(_ on: Bool) {
        hiResTimer?.invalidate()
        hiResTimer = nil
        guard on else {
            model.hiResUntil = nil
            return
        }
        let end = Date().addingTimeInterval(3600)
        model.hiResUntil = end
        let t = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if Date() >= end {
                    self.setHiRes(false)
                } else if let snap = BatteryReader.read() {
                    self.model.live = snap
                    self.record(snap, source: "hires")
                }
            }
        }
        t.tolerance = 1
        RunLoop.main.add(t, forMode: .common)
        hiResTimer = t
    }

    private func powerSourcesChanged() {
        guard let snap = BatteryReader.read() else { return }
        model.live = snap
        alerts.process(snap, settings: .shared)
        let charging = snap.onAC ? 1 : 0
        // A state transition gets persisted immediately so plug/unplug/full
        // events carry exact timestamps; plain percent ticks wait for the
        // 120s cadence.
        if charging != prevCharging || crossedFull(snap) {
            record(snap)
        }
    }

    private func recordSample() {
        guard let snap = BatteryReader.read() else { return }
        model.live = snap
        alerts.process(snap, settings: .shared)
        record(snap)
        if model.popoverIsLive { model.reloadDerived() }
    }

    private func record(_ snap: BatterySnapshot, source: String = "live") {
        for event in transitions(to: snap) {
            store.insertEvent(ts: snap.ts, type: event)
            if event == "plug_in", Settings.shared.chargeEffect {
                ChargeEffect.shared.play(snap, title: cachedModelName ?? "MacBook")
            }
        }
        store.insert(snap, model: cachedModelName, source: source)
        prevPct = snap.chargePct
        prevCharging = snap.onAC ? 1 : 0
    }

    /// Port of the Python collector's `diff_events`.
    private func transitions(to snap: BatterySnapshot) -> [String] {
        var events: [String] = []
        let charging = snap.onAC ? 1 : 0
        if prevCharging == 0 && charging == 1 { events.append("plug_in") }
        if prevCharging == 1 && charging == 0 { events.append("unplug") }
        if crossedFull(snap) { events.append("full_charge") }
        return events
    }

    private func crossedFull(_ snap: BatterySnapshot) -> Bool {
        guard let pct = snap.chargePct, let prev = prevPct else { return false }
        return prev < 100 && pct >= 100
    }

    /// Friendly model name ("MacBook Air"): cached in meta after one
    /// system_profiler call on first launch — never again after that.
    private func resolveModelName() {
        if let m = store.meta("model_name") ?? store.lastKnownModel() {
            cachedModelName = m
            if store.meta("model_name") == nil { store.setMeta("model_name", m) }
            return
        }
        let store = self.store
        DispatchQueue.global(qos: .utility).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
            p.arguments = ["SPHardwareDataType", "-json"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = Pipe()
            guard (try? p.run()) != nil else { return }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let hw = (json["SPHardwareDataType"] as? [[String: Any]])?.first,
                let name = hw["machine_name"] as? String
            else { return }
            store.setMeta("model_name", name)
            DispatchQueue.main.async { self.cachedModelName = name }
        }
    }
}
