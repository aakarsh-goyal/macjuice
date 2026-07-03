import AppKit
import Foundation
import ServiceManagement

// Diagnostic modes that need no UI run loop.
let arguments = ProcessInfo.processInfo.arguments
if arguments.contains("--sample") {
    if let s = BatteryReader.read() {
        var out: [String: Any] = [:]
        out["ts"] = s.ts
        out["charge_pct"] = s.chargePct
        out["current_mah"] = s.currentMAh
        out["max_mah"] = s.maxMAh
        out["design_mah"] = s.designMAh
        out["nominal_mah"] = s.nominalMAh
        out["cycle_count"] = s.cycleCount
        out["condition"] = s.condition
        out["temp_c"] = s.tempC
        out["voltage_v"] = s.voltageV
        out["amperage_ma"] = s.amperageMA
        out["watts"] = s.watts
        out["system_watts"] = s.systemWatts
        out["adapter_input_watts"] = s.adapterInputWatts
        out["on_ac"] = s.onAC
        out["is_charging"] = s.isCharging
        out["fully_charged"] = s.fullyCharged
        out["time_remaining_min"] = s.timeRemainingMin
        out["health_raw_pct"] = s.healthRawPct
        out["health_reported_pct"] = s.healthReportedPct
        out["serial"] = s.serial
        out["adapter_desc"] = s.adapterDesc
        out["adapter_rated_watts"] = s.adapterRatedWatts
        let clean = out.compactMapValues { $0 }
        if let data = try? JSONSerialization.data(withJSONObject: clean, options: [.sortedKeys, .prettyPrinted]) {
            print(String(data: data, encoding: .utf8) ?? "{}")
        }
        exit(0)
    }
    FileHandle.standardError.write(Data("no battery found\n".utf8))
    exit(1)
}
if arguments.contains("--login-status") {
    let status = SMAppService.mainApp.status
    let name: String
    switch status {
    case .enabled: name = "enabled"
    case .notRegistered: name = "notRegistered"
    case .requiresApproval: name = "requiresApproval"
    case .notFound: name = "notFound"
    @unknown default: name = "unknown(\(status.rawValue))"
    }
    print(name)
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    // NSApplication.delegate is not retained; anchor it for the app's lifetime.
    objc_setAssociatedObject(app, "macjuice.delegate", delegate, .OBJC_ASSOCIATION_RETAIN)
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
