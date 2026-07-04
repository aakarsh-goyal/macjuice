import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: BatteryModel!
    private var recorder: Recorder!
    private var statusController: StatusItemController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "--render-preview"), args.count > i + 1 {
            renderPreviews(basePath: args[i + 1])
            exit(0)
        }

        // If a second copy launches (login item + manual open), keep the old one.
        let running = NSRunningApplication.runningApplications(
            withBundleIdentifier: Bundle.main.bundleIdentifier ?? "com.macjuice.app")
        if running.count > 1 {
            NSApp.terminate(nil)
            return
        }

        guard let store = try? Store() else {
            NSLog("MacJuice: cannot open database — quitting")
            NSApp.terminate(nil)
            return
        }
        model = BatteryModel(store: store)
        recorder = Recorder(store: store, model: model)
        statusController = StatusItemController(model: model, settings: .shared)
        recorder.start()
        Settings.shared.autoRegisterLoginItemIfNeeded()
    }

    /// Offscreen render of the popover in both appearances — a development
    /// aid (`MacJuice --render-preview /path/base`), not a user feature.
    private func renderPreviews(basePath: String) {
        guard let store = try? Store() else { return }
        let model = BatteryModel(store: store)
        if let metric = ProcessInfo.processInfo.environment["MJ_PREVIEW_METRIC"]
            .flatMap(ChartMetric.init(rawValue:)) {
            model.chartMetric = metric
        }
        if let range = ProcessInfo.processInfo.environment["MJ_PREVIEW_RANGE"]
            .flatMap(ChartRange.init(rawValue:)) {
            model.chartRange = range
        }
        model.updateLive()
        if ProcessInfo.processInfo.environment["MJ_PREVIEW_LPM"] != nil {
            model.live?.lowPowerMode = true
        }
        model.reloadDerived()
        model.reloadChart()
        // Give the async reloads a beat to land before rendering.
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))

        for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            let view = PopoverView()
                .environmentObject(model)
                .environmentObject(Settings.shared)
                .background(Color(nsColor: .windowBackgroundColor))
            let host = NSHostingView(rootView: view)
            let size = host.fittingSize
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                                  styleMask: .borderless, backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: appearance)
            window.contentView = host
            window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
            window.orderFrontRegardless()
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))

            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: "\(basePath)-\(suffix).png"))
            }
            window.orderOut(nil)
        }
    }
}
