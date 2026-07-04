import Foundation
import IOKit
import IOKit.ps

/// One point-in-time reading of the battery, taken straight from the
/// AppleSmartBattery IORegistry node. No subprocesses, no parsing text —
/// a read costs microseconds.
struct BatterySnapshot {
    var ts: Int = Int(Date().timeIntervalSince1970)

    var chargePct: Double?
    var currentMAh: Double?      // raw remaining capacity
    var maxMAh: Double?          // raw full-charge capacity (coconutBattery-style)
    var designMAh: Double?
    var nominalMAh: Double?      // Apple's smoothed capacity basis

    var cycleCount: Int?
    var designCycles: Int?
    var condition: String = "Normal"

    var tempC: Double?
    var voltageV: Double?
    var amperageMA: Double?
    var watts: Double?           // battery power, signed: negative = discharging
    var systemWatts: Double?     // whole-system draw (works even when battery is bypassed on AC)
    var adapterInputWatts: Double?

    var onAC = false
    var isCharging = false
    var fullyCharged = false
    var atCritical = false
    var lowPowerMode = false

    var timeRemainingMin: Int?   // to empty (discharging) or to full (charging)
    var serial: String?
    var adapterDesc: String?
    var adapterRatedWatts: Double?

    /// Raw mAh ratio — may exceed 100% on a fresh battery.
    var healthRawPct: Double? {
        guard let m = maxMAh, let d = designMAh, d > 0 else { return nil }
        return m / d * 100
    }

    /// Apple's smoothed "Maximum Capacity", capped at 100 like System Settings.
    var healthReportedPct: Double? {
        guard let n = nominalMAh, let d = designMAh, d > 0 else { return nil }
        return min(100, n / d * 100)
    }
}

enum BatteryReader {

    static func read() -> BatterySnapshot? {
        guard let props = properties(ofClass: "AppleSmartBattery") else { return nil }
        var s = BatterySnapshot()

        let pct = num(props["CurrentCapacity"])
        let maxBasis = num(props["MaxCapacity"])
        if let p = pct, let basis = maxBasis, basis > 0 {
            s.chargePct = basis == 100 ? p : p / basis * 100
        }

        s.cycleCount = num(props["CycleCount"]).map(Int.init)
        s.designCycles = num(props["DesignCycleCount9C"]).map(Int.init)
        s.onAC = bool(props["ExternalConnected"])
        s.isCharging = bool(props["IsCharging"])
        s.fullyCharged = bool(props["FullyCharged"])
        s.atCritical = bool(props["AtCriticalLevel"])
        s.serial = props["Serial"] as? String

        if let mv = num(props["Voltage"]) { s.voltageV = mv / 1000 }
        if let ma = signedNum(props["Amperage"]) {
            s.amperageMA = ma
            if let v = s.voltageV { s.watts = v * ma / 1000 }
        }

        if let bd = props["BatteryData"] as? [String: Any] {
            s.currentMAh = num(bd["RemainingCapacity"])
            s.maxMAh = num(bd["FullChargeCapacity"])
            s.designMAh = num(bd["DesignCapacity"])
            s.nominalMAh = num(bd["NominalChargeCapacity"])
        }
        s.designMAh = s.designMAh ?? num(props["DesignCapacity"])
        s.maxMAh = s.maxMAh ?? num(props["AppleRawMaxCapacity"])
        s.currentMAh = s.currentMAh ?? num(props["AppleRawCurrentCapacity"])

        if let pt = props["PowerTelemetryData"] as? [String: Any] {
            if let load = num(pt["SystemLoad"]), load > 0 { s.systemWatts = load / 1000 }
            if let inW = num(pt["SystemPowerIn"]), inW > 0 { s.adapterInputWatts = inW / 1000 }
        }

        // Temperature moved off the top-level node on Apple Silicon / recent macOS;
        // the pack child still publishes it (in hundredths of °C).
        if let t = num(props["Temperature"]) ?? num(props["VirtualTemperature"]) {
            s.tempC = t / 100
        } else if let pack = properties(ofClass: "AppleSmartBatteryPack") {
            let packData = pack["BatteryData"] as? [String: Any] ?? [:]
            if let t = num(pack["Temperature"]) ?? num(pack["VirtualTemperature"])
                ?? num(packData["Temperature"]) ?? num(packData["VirtualTemperature"]) {
                s.tempC = t / 100
            }
        }

        // Time estimate: 65535 is the firmware's "unknown" sentinel.
        let toEmpty = num(props["AvgTimeToEmpty"]) ?? num(props["TimeRemaining"])
        let toFull = num(props["AvgTimeToFull"])
        let raw = s.onAC ? toFull : toEmpty
        if let m = raw, m > 0, m < 65535 { s.timeRemainingMin = Int(m) }

        // Adapter details (only populated while plugged in).
        let best = num(props["BestAdapterIndex"]).map(Int.init) ?? 0
        if let adapters = props["AppleRawAdapterDetails"] as? [[String: Any]],
           !adapters.isEmpty {
            let a = adapters.indices.contains(best) ? adapters[best] : adapters[0]
            if let w = num(a["Watts"]), w > 0 { s.adapterRatedWatts = w }
            s.adapterDesc = (a["Name"] as? String) ?? (a["Description"] as? String)
        }

        s.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        s.condition = healthCondition()
        return s
    }

    // MARK: - IOKit plumbing

    private static func properties(ofClass cls: String) -> [String: Any]? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(cls))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var propsRef: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &propsRef, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let props = propsRef?.takeRetainedValue() as? [String: Any] else { return nil }
        return props
    }

    private static func num(_ v: Any?) -> Double? {
        (v as? NSNumber)?.doubleValue
    }

    /// Amperage sometimes surfaces as a 64-bit two's-complement value stored
    /// unsigned; fold it back to a signed milliamp reading.
    private static func signedNum(_ v: Any?) -> Double? {
        guard let n = v as? NSNumber else { return nil }
        let i = n.int64Value
        return Double(i)
    }

    private static func bool(_ v: Any?) -> Bool {
        (v as? NSNumber)?.boolValue ?? false
    }

    /// Battery condition from the power-sources API ("Service Recommended" etc.);
    /// absence of a condition key means the battery is fine.
    private static func healthCondition() -> String {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else {
            return "Normal"
        }
        for ps in list {
            guard let desc = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any] else { continue }
            if let cond = desc[kIOPSBatteryHealthConditionKey] as? String { return cond }
            if let health = desc[kIOPSBatteryHealthKey] as? String, health != "Good" { return health }
        }
        return "Normal"
    }
}
