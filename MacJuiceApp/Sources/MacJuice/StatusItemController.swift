import AppKit
import Combine
import SwiftUI

/// Borderless panel that can take keyboard focus without activating the app —
/// the same behavior as Control Center's panels.
private final class GlassPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Owns the NSStatusItem and the dashboard surface. On macOS 26+ the surface
/// is a floating Liquid Glass panel (real lensing via NSGlassEffectView);
/// older systems fall back to a classic NSPopover. The menu bar label
/// re-renders only when its string actually changes, and the label-refresh
/// timer pauses while the displays are asleep.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let model: BatteryModel
    private let settings: Settings
    private let item: NSStatusItem
    private var cancellables = Set<AnyCancellable>()
    private var labelTimer: Timer?
    private var lastTitle = "\u{0}"   // sentinel so the first update always applies

    private var popover: NSPopover?
    private var panel: NSPanel?
    private var panelHost: NSView?
    private var clickMonitor: Any?
    private var keyMonitor: Any?

    private var glassAvailable: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    init(model: BatteryModel, settings: Settings) {
        self.model = model
        self.settings = settings
        self.item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = item.button {
            let config = NSImage.SymbolConfiguration(pointSize: 12.5, weight: .medium)
            let image = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: "MacJuice")?
                .withSymbolConfiguration(config)
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(toggleUI)
        }

        model.$live
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snap in self?.refreshLabel(snap) }
            .store(in: &cancellables)
        settings.$labelStyle
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.refreshLabel(self.model.live)
                self.configureLabelTimer()
            }
            .store(in: &cancellables)
        // Content height changes (insight rows appearing) resize the panel.
        model.$derived
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updatePanelFrame() }
            .store(in: &cancellables)

        let wsc = NSWorkspace.shared.notificationCenter
        wsc.addObserver(self, selector: #selector(screensSlept),
                        name: NSWorkspace.screensDidSleepNotification, object: nil)
        wsc.addObserver(self, selector: #selector(screensWoke),
                        name: NSWorkspace.screensDidWakeNotification, object: nil)
        configureLabelTimer()
    }

    private func dashboardView() -> some View {
        PopoverView()
            .environmentObject(model)
            .environmentObject(settings)
    }

    // MARK: - Label

    private func refreshLabel(_ snap: BatterySnapshot?) {
        guard let button = item.button else { return }
        let title = labelText(snap)
        guard title != lastTitle else { return }
        lastTitle = title
        guard !title.isEmpty else {
            button.attributedTitle = NSAttributedString(string: "")
            return
        }
        let critical = (snap?.chargePct ?? 100) <= 10 && !(snap?.onAC ?? false)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: critical ? NSColor.systemRed : NSColor.labelColor,
            .baselineOffset: 0.5,
        ]
        button.attributedTitle = NSAttributedString(string: " " + title, attributes: attrs)
    }

    private func labelText(_ snap: BatterySnapshot?) -> String {
        guard let snap else { return "" }
        switch settings.labelStyle {
        case .icon:
            return ""
        case .percent:
            guard let pct = snap.chargePct else { return "" }
            return "\(Int(pct.rounded()))%"
        case .watts:
            // On AC the interesting number is what's flowing into the battery;
            // on battery it's what the system is draining.
            if snap.onAC, let b = snap.watts, b > 0.05 {
                return "+" + Fmt.wattsShort(b)
            }
            guard let w = snap.systemWatts ?? snap.watts.map({ abs($0) }) else { return "" }
            return Fmt.wattsShort(w)
        }
    }

    /// Watts drift without a power-source notification, so that style gets a
    /// slow coalesced refresh; icon/percent styles need none (notifications
    /// cover them).
    private func configureLabelTimer() {
        labelTimer?.invalidate()
        labelTimer = nil
        guard settings.labelStyle == .watts else { return }
        let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.model.popoverIsLive else { return }
                self.model.updateLive()
            }
        }
        t.tolerance = 10
        RunLoop.main.add(t, forMode: .common)
        labelTimer = t
    }

    @objc private func screensSlept() {
        labelTimer?.invalidate()
        labelTimer = nil
        if panel?.isVisible == true { closePanel() }
    }

    @objc private func screensWoke() {
        model.updateLive()
        configureLabelTimer()
    }

    // MARK: - Toggle

    @objc private func toggleUI() {
        if glassAvailable {
            if #available(macOS 26.0, *) {
                panel?.isVisible == true ? closePanel() : showPanel()
            }
        } else {
            togglePopover()
        }
    }

    func debugShowPanel() {
        toggleUI()
    }

    // MARK: - Liquid Glass panel (macOS 26+)

    @available(macOS 26.0, *)
    private func showPanel() {
        if panel == nil { buildPanel() }
        guard let panel, let host = panelHost,
              let button = item.button, let buttonWindow = button.window else { return }

        model.beginLiveUpdates()
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = buttonWindow.screen ?? NSScreen.main
        var x = anchor.midX - size.width / 2
        if let frame = screen?.visibleFrame {
            x = min(max(x, frame.minX + 8), frame.maxX - size.width - 8)
        }
        let frame = NSRect(x: x, y: anchor.minY - 6 - size.height,
                           width: size.width, height: size.height)
        panel.setFrame(frame, display: false)
        panel.appearance = Self.adaptiveAppearance(for: screen, under: frame)

        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            panel.animator().alphaValue = 1
        }

        // Click anywhere outside the app dismisses; Esc dismisses. (Debug
        // screenshot mode keeps the panel up despite outside clicks.)
        guard ProcessInfo.processInfo.environment["MJ_SHOW_PANEL"] == nil else { return }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.closePanel() }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {   // Esc
                Task { @MainActor in self?.closePanel() }
                return nil
            }
            return event
        }
    }

    private func closePanel() {
        guard let panel, panel.isVisible else { return }
        model.endLiveUpdates()
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
        })
    }

    @available(macOS 26.0, *)
    private func buildPanel() {
        let host = NSHostingView(rootView: dashboardView())
        host.autoresizingMask = [.width, .height]

        let glass = NSGlassEffectView()
        glass.style = .regular
        glass.cornerRadius = 26
        if #available(macOS 27.0, *) {
            glass.effectIsInteractive = true
        }
        glass.contentView = host
        glass.autoresizingMask = [.width, .height]

        let p = GlassPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 400),
                           styleMask: [.borderless, .nonactivatingPanel],
                           backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        // The window shadow is computed for the rectangular window bounds and
        // draws an ugly dark rim around the rounded glass; the glass supplies
        // its own edge treatment.
        p.hasShadow = false
        p.level = .popUpMenu
        p.collectionBehavior = [.transient, .fullScreenAuxiliary, .ignoresCycle]
        p.isMovable = false
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.animationBehavior = .none
        p.appearance = Self.adaptiveAppearance(for: nil, under: .zero)
        glass.frame = p.contentLayoutRect
        host.frame = glass.bounds
        p.contentView = glass

        panel = p
        panelHost = host

        // Agent apps don't reliably inherit system theme flips; track them.
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, let panel = self.panel else { return }
                panel.appearance = Self.adaptiveAppearance(for: panel.screen, under: panel.frame)
            }
        }
    }

    /// Control Center behavior: the glass matches the *backdrop*, not just the
    /// theme. Light mode is always light; dark mode goes light when the
    /// wallpaper under the panel is bright. (The user preference is read
    /// directly because an LSUIElement app's effectiveAppearance can lag.)
    private static func adaptiveAppearance(for screen: NSScreen?, under rect: NSRect) -> NSAppearance? {
        let dark = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleInterfaceStyle"] as? String == "Dark"
        guard dark else { return NSAppearance(named: .aqua) }
        if let screen, wallpaperIsLight(on: screen, under: rect) == true {
            return NSAppearance(named: .aqua)
        }
        return NSAppearance(named: .darkAqua)
    }

    /// Average luminance of the wallpaper region a rect covers (aspect-fill
    /// mapping), by downsampling the crop to a single pixel.
    private static func wallpaperIsLight(on screen: NSScreen, under rect: NSRect) -> Bool? {
        guard let url = NSWorkspace.shared.desktopImageURL(for: screen),
              let image = NSImage(contentsOf: url),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              cg.width > 0, cg.height > 0 else { return nil }

        let sf = screen.frame
        let scale = max(CGFloat(cg.width) / sf.width, CGFloat(cg.height) / sf.height)
        let offsetX = (CGFloat(cg.width) - sf.width * scale) / 2
        let offsetY = (CGFloat(cg.height) - sf.height * scale) / 2
        let topDistance = sf.maxY - rect.maxY
        var crop = CGRect(x: offsetX + (rect.minX - sf.minX) * scale,
                          y: offsetY + topDistance * scale,
                          width: rect.width * scale,
                          height: rect.height * scale)
        crop = crop.intersection(CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        guard !crop.isEmpty, let cropped = cg.cropping(to: crop) else { return nil }

        var px = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8,
                                  bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let lum = 0.2126 * Double(px[0]) + 0.7152 * Double(px[1]) + 0.0722 * Double(px[2])
        return lum / 255 > 0.55
    }

    /// Re-fit the panel to its content, keeping the top edge pinned under
    /// the menu bar.
    private func updatePanelFrame() {
        guard let panel, panel.isVisible, let host = panelHost else { return }
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        guard abs(size.height - panel.frame.height) > 0.5 else { return }
        var frame = panel.frame
        frame.origin.y = frame.maxY - size.height
        frame.size = size
        panel.setFrame(frame, display: true)
    }

    // MARK: - NSPopover fallback (pre-macOS 26)

    private func togglePopover() {
        if popover == nil {
            let p = NSPopover()
            p.behavior = .transient
            p.animates = true
            p.delegate = self
            p.contentViewController = NSHostingController(rootView: dashboardView())
            popover = p
        }
        guard let popover else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else if let button = item.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    nonisolated func popoverWillShow(_ notification: Notification) {
        Task { @MainActor in self.model.beginLiveUpdates() }
    }

    nonisolated func popoverDidClose(_ notification: Notification) {
        Task { @MainActor in self.model.endLiveUpdates() }
    }
}
