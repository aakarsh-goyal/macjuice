import AppKit

/// A Bluetooth accessory in the system's connected list.
struct BTDevice: Sendable {
    let address: String
    let name: String
    let minorType: String?

    /// "85%" strings; earbuds report Left/Right (surface the weaker bud).
    let batteryPct: Int?

    /// Best glyph for the device: exact Apple models by name first, then the
    /// Bluetooth minor class, each candidate validated against the installed
    /// symbol set so an older macOS quietly falls through to the next one.
    var symbolName: String {
        let n = name.lowercased()
        var candidates: [String] = []
        if n.contains("airpods max") { candidates.append("airpods.max") }
        else if n.contains("airpods pro") { candidates.append("airpods.pro") }
        else if n.contains("airpods") { candidates.append("airpods") }
        else if n.contains("magic keyboard") { candidates.append("magickeyboard") }
        else if n.contains("magic mouse") { candidates.append("magicmouse") }
        else if n.contains("magic trackpad") { candidates.append("magictrackpad.gen2") }
        switch minorType {
        case "Keyboard": candidates.append("keyboard")
        case "Mouse": candidates.append("computermouse")
        case "Speaker": candidates.append("hifispeaker")
        case "Headphones", "Headset": candidates.append("headphones")
        case "Gamepad", "Joystick": candidates.append("gamecontroller")
        case "Smartphone": candidates.append("iphone")
        default: break
        }
        candidates.append("dot.radiowaves.left.and.right")
        for c in candidates
        where NSImage(systemSymbolName: c, accessibilityDescription: nil) != nil {
            return c
        }
        return "circle.dotted"
    }
}

/// Watches the system Bluetooth topology and plays the notch pill when an
/// accessory connects. There is no public notification that covers both
/// Classic and BLE system connections, so this polls `system_profiler
/// SPBluetoothDataType -json` (~80 ms, off the main thread) every 5 s.
@MainActor
final class BluetoothWatcher {
    static let shared = BluetoothWatcher()

    private var timer: Timer?
    private var known: Set<String> = []
    private var primed = false                   // first poll is baseline only
    private var lastPill: [String: Date] = [:]   // per-device cooldown

    func start() {
        guard timer == nil else { return }
        poll()
        let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        t.tolerance = 2
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func poll() {
        Task.detached(priority: .utility) { [weak self] in
            guard let devices = Self.snapshot() else { return }
            await self?.handle(devices)
        }
    }

    private func handle(_ devices: [BTDevice]) {
        let current = Set(devices.map(\.address))
        defer { known = current }
        guard primed else { primed = true; return }
        for d in devices where !known.contains(d.address) {
            // AirPods flap on case-open / in-ear checks; don't re-celebrate.
            guard Date().timeIntervalSince(lastPill[d.address] ?? .distantPast) > 90
            else { continue }
            lastPill[d.address] = Date()
            ChargeEffect.shared.playAccessory(name: d.name, symbol: d.symbolName,
                                              pct: d.batteryPct)
        }
    }

    /// nil = the probe itself failed (don't treat as "everything vanished");
    /// empty = genuinely nothing connected.
    private nonisolated static func snapshot() -> [BTDevice]? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        proc.arguments = ["SPBluetoothDataType", "-json"]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sp = (root["SPBluetoothDataType"] as? [[String: Any]])?.first
        else { return nil }
        var devices: [BTDevice] = []
        for entry in sp["device_connected"] as? [[String: Any]] ?? [] {
            for (name, value) in entry {
                guard let d = value as? [String: Any],
                      let addr = d["device_address"] as? String else { continue }
                devices.append(BTDevice(address: addr, name: name,
                                        minorType: d["device_minorType"] as? String,
                                        batteryPct: battery(d)))
            }
        }
        return devices
    }

    private nonisolated static func battery(_ d: [String: Any]) -> Int? {
        func pct(_ key: String) -> Int? {
            (d[key] as? String)
                .flatMap { Int($0.replacingOccurrences(of: "%", with: "")) }
        }
        if let main = pct("device_batteryLevelMain") { return main }
        return [pct("device_batteryLevelLeft"), pct("device_batteryLevelRight")]
            .compactMap { $0 }.min()
    }
}
