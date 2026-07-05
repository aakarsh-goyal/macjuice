import Foundation

/// Switches macOS Low Power Mode. Apple exposes no public API for third-party
/// apps to *set* it (reading via ProcessInfo is free), so three routes are
/// tried, quietest first:
///
///   1. `sudo -n pmset` — silent if the user has a NOPASSWD sudoers rule.
///   2. A Shortcuts shortcut that toggles Low Power Mode. Shortcuts' "Set Low
///      Power Mode" action is Apple-privileged, so it needs no password —
///      this is the everyday path. Auto-detected from the library by name;
///      override with `defaults write com.macjuice.app lpmShortcut -string X`.
///   3. AppleScript `with administrator privileges` — the standard macOS
///      admin-password dialog. Cancelling is a clean no-op: pmset never runs
///      and the next snapshot re-reads the real state.
enum PowerMode {
    private static let lock = NSLock()
    private static var inFlight = false

    static func setLowPower(_ on: Bool, completion: @escaping @MainActor (Bool) -> Void) {
        lock.lock()
        if inFlight { lock.unlock(); return }
        inFlight = true
        lock.unlock()
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = apply(on)
            lock.lock(); inFlight = false; lock.unlock()
            Task { @MainActor in completion(ok) }
        }
    }

    /// Blocking route chain; also the `--set-lpm` CLI entry point.
    static func apply(_ on: Bool) -> Bool {
        runSudo(on) || runShortcut(on) || runWithAdminPrompt(on)
    }

    // MARK: - Routes

    private static func runSudo(_ on: Bool) -> Bool {
        run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "lowpowermode", on ? "1" : "0"]) == 0
    }

    private static func runShortcut(_ on: Bool) -> Bool {
        guard let name = shortcutName() else { return false }
        guard run("/usr/bin/shortcuts", ["run", name], timeout: 30) == 0 else { return false }
        // Shortcuts are usually *toggles*, so confirm the system actually
        // landed on the requested state (a set-on-only shortcut asked to turn
        // LPM off would leave it unchanged — fall through to the prompt).
        return confirmState(on, within: 4)
    }

    private static func runWithAdminPrompt(_ on: Bool) -> Bool {
        let script = "do shell script \"/usr/bin/pmset -a lowpowermode \(on ? 1 : 0)\""
            + " with prompt \"MacJuice needs an administrator password to turn Low Power Mode \(on ? "on" : "off").\""
            + " with administrator privileges"
        return run("/usr/bin/osascript", ["-e", script], timeout: 600) == 0
    }

    /// The user's Low Power Mode shortcut, if any. An explicit `lpmShortcut`
    /// default wins; otherwise pick from the library by name.
    private static func shortcutName() -> String? {
        if let custom = UserDefaults.standard.string(forKey: "lpmShortcut"),
           !custom.isEmpty { return custom }
        guard let list = runCapturing("/usr/bin/shortcuts", ["list"]) else { return nil }
        let names = list.components(separatedBy: "\n").filter { !$0.isEmpty }
        if let exact = names.first(where: { $0.caseInsensitiveCompare("Low Power Mode") == .orderedSame }) {
            return exact
        }
        return names.first { $0.range(of: "low power", options: .caseInsensitive) != nil }
    }

    // MARK: - Plumbing

    /// Effective Low Power Mode straight from `pmset -g` — authoritative,
    /// unlike the in-process ProcessInfo cache, which can lag a runloop turn.
    private static func systemState() -> Bool? {
        guard let out = runCapturing("/usr/bin/pmset", ["-g"]) else { return nil }
        for line in out.components(separatedBy: "\n") where line.contains("lowpowermode") {
            return line.trimmingCharacters(in: .whitespaces).hasSuffix("1")
        }
        return nil
    }

    private static func confirmState(_ on: Bool, within seconds: Double) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while true {
            if systemState() == on { return true }
            if Date() >= deadline { return false }
            Thread.sleep(forTimeInterval: 0.25)
        }
    }

    private static func run(_ tool: String, _ args: [String], timeout: Double = 60) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do { try p.run() } catch { return -1 }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            return -1
        }
        return p.terminationStatus
    }

    private static func runCapturing(_ tool: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
