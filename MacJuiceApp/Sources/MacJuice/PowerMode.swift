import Foundation

/// Switches macOS Low Power Mode. Apple exposes no public API for third-party
/// apps to *set* it (reading via ProcessInfo is free), so the only path is
/// `pmset -a lowpowermode`, which must run as root:
///
///   1. `sudo -n` first — succeeds silently if the user has a NOPASSWD
///      sudoers rule for pmset (see README), costs nothing otherwise.
///   2. AppleScript `with administrator privileges` — the standard macOS
///      admin-password dialog, branded via the prompt text.
///
/// A cancelled dialog is a clean no-op: pmset never runs, the next snapshot
/// re-reads the real state.
enum PowerMode {
    private static let lock = NSLock()
    private static var inFlight = false

    static func setLowPower(_ on: Bool, completion: @escaping @MainActor (Bool) -> Void) {
        lock.lock()
        if inFlight { lock.unlock(); return }
        inFlight = true
        lock.unlock()
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = runSilently(on) || runWithAdminPrompt(on)
            lock.lock(); inFlight = false; lock.unlock()
            Task { @MainActor in completion(ok) }
        }
    }

    private static func runSilently(_ on: Bool) -> Bool {
        run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "lowpowermode", on ? "1" : "0"]) == 0
    }

    private static func runWithAdminPrompt(_ on: Bool) -> Bool {
        let script = "do shell script \"/usr/bin/pmset -a lowpowermode \(on ? 1 : 0)\""
            + " with prompt \"MacJuice needs an administrator password to turn Low Power Mode \(on ? "on" : "off").\""
            + " with administrator privileges"
        return run("/usr/bin/osascript", ["-e", script]) == 0
    }

    private static func run(_ tool: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }
}
