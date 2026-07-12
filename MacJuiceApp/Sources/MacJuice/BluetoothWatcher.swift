import AppKit
import IOBluetooth

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

/// Plays the notch pill when a Bluetooth accessory connects.
///
/// Built to cost nothing at rest: bluetoothd pushes Classic connects to us
/// (IOBluetooth notifications — speakers, AirPods audio, phones — instant,
/// zero polling), and a ~1.5 ms in-process paired-list diff every 10 s
/// catches BLE-only HID that the notification API misses. `system_profiler`
/// (the only home of battery levels) is spawned exactly once per actual
/// connect. The whole watcher stands down while the displays sleep.
@MainActor
final class BluetoothWatcher: NSObject {
    static let shared = BluetoothWatcher()

    private var timer: Timer?
    private var paused = false
    private var known: Set<String> = []
    private var primed = false                   // first poll is baseline only
    private var lastPill: [String: Date] = [:]   // per-device cooldown

    func start() {
        guard timer == nil else { return }
        IOBluetoothDevice.register(forConnectNotifications: self,
                                   selector: #selector(classicConnected(_:device:)))
        schedule()
        // Pills are pointless at a dark display — stop touching bluetoothd.
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.screensDidSleepNotification,
                       object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.pause() }
        }
        nc.addObserver(forName: NSWorkspace.screensDidWakeNotification,
                       object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.resume() }
        }
    }

    private func schedule() {
        poll()
        let t = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        t.tolerance = 5
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func pause() {
        paused = true
        timer?.invalidate()
        timer = nil
    }

    private func resume() {
        guard paused else { return }
        paused = false
        primed = false   // silent re-baseline: sleep-time connects don't pill
        schedule()
    }

    /// bluetoothd's push path — fires the moment a Classic device connects.
    @objc private func classicConnected(_ note: IOBluetoothUserNotification,
                                        device: IOBluetoothDevice) {
        guard !paused, let addr = Self.normalize(device.addressString) else { return }
        known.insert(addr)   // the safety poll shouldn't re-fire for it
        celebrate(addr: addr, fallbackName: device.name)
    }

    /// The safety net: an in-process paired-list diff (~1.5 ms, no subprocess)
    /// for BLE-only devices whose connects the Classic notification misses.
    private func poll() {
        let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
        let current = Set(paired.compactMap { d in
            d.isConnected() ? Self.normalize(d.addressString) : nil
        })
        let fresh = current.subtracting(known)
        known = current
        guard primed else { primed = true; return }
        for d in paired {
            guard let addr = Self.normalize(d.addressString),
                  fresh.contains(addr) else { continue }
            celebrate(addr: addr, fallbackName: d.name)
        }
    }

    /// One system_profiler spawn per actual connect — battery levels and the
    /// device class live only there.
    private func celebrate(addr: String, fallbackName: String?) {
        guard Date().timeIntervalSince(lastPill[addr] ?? .distantPast) > 90
        else { return }   // AirPods flap on case-open / in-ear checks
        lastPill[addr] = Date()
        Task.detached(priority: .utility) {
            // AirPods surface a rotating private address in the topology, so
            // fall back to a name match before giving up on battery data.
            let dev = Self.snapshot()?.first {
                $0.address.lowercased() == addr || $0.name == fallbackName
            }
            await MainActor.run {
                if let dev {
                    ChargeEffect.shared.playAccessory(name: dev.name,
                                                      symbol: dev.symbolName,
                                                      pct: dev.batteryPct)
                } else if let name = fallbackName {
                    let d = BTDevice(address: addr, name: name,
                                     minorType: nil, batteryPct: nil)
                    ChargeEffect.shared.playAccessory(name: name,
                                                      symbol: d.symbolName,
                                                      pct: nil)
                }
            }
        }
    }

    private nonisolated static func normalize(_ s: String?) -> String? {
        s?.lowercased().replacingOccurrences(of: "-", with: ":")
    }

    /// nil = the probe itself failed; empty = genuinely nothing connected.
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
