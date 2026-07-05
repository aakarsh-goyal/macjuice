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
    private var lastCritical = false

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
        settings.$pinPanel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] pinned in self?.applyPinState(pinned) }
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
        let critical = (snap?.chargePct ?? 100) <= 10 && !(snap?.onAC ?? false)
        guard title != lastTitle || critical != lastCritical else { return }
        lastTitle = title
        lastCritical = critical
        guard !title.isEmpty else {
            button.title = ""
            return
        }
        // A plain title lets AppKit own the color completely — white on dark
        // menu bars, black on light ones, dimmed on the inactive display's
        // bar. Any explicit color (even labelColor) opts out of all three,
        // so only critical red uses an attributed title: standing out
        // everywhere is the point.
        if critical {
            button.attributedTitle = NSAttributedString(string: " " + title, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor.systemRed,
                .baselineOffset: 0.5,
            ])
        } else {
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            button.title = " " + title
        }
    }

    private func labelText(_ snap: BatterySnapshot?) -> String {
        guard let snap else { return "" }
        switch settings.labelStyle {
        case .icon:
            return ""
        case .percent:
            return percentText(snap)
        case .watts:
            return wattsText(snap)
        case .both:
            let parts = [percentText(snap), wattsText(snap)].filter { !$0.isEmpty }
            return parts.joined(separator: " | ")
        }
    }

    private func percentText(_ snap: BatterySnapshot) -> String {
        snap.chargePct.map { "\(Int($0.rounded()))%" } ?? ""
    }

    /// On AC the interesting number is what's flowing into the battery;
    /// on battery it's what the system is draining.
    private func wattsText(_ snap: BatterySnapshot) -> String {
        if snap.onAC, let b = snap.watts, b > 0.05 {
            return "+" + Fmt.wattsShort(b)
        }
        guard let w = snap.systemWatts ?? snap.watts.map({ abs($0) }) else { return "" }
        return Fmt.wattsShort(w)
    }

    /// Watts drift without a power-source notification, so that style gets a
    /// slow coalesced refresh; icon/percent styles need none (notifications
    /// cover them).
    private func configureLabelTimer() {
        labelTimer?.invalidate()
        labelTimer = nil
        guard settings.labelStyle.showsWatts else { return }
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
        if panel?.isVisible == true, !settings.pinPanel { closePanel() }
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
        panel.appearance = Self.systemAppearance()
        applyPinState(settings.pinPanel)

        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            panel.animator().alphaValue = 1
        }

        if !settings.pinPanel { installMonitors() }
    }

    /// Transient (default): dismiss on outside click or Esc. Pinned: float
    /// above other windows, follow across Spaces, dismiss only from the
    /// status item or by unpinning.
    private func applyPinState(_ pinned: Bool) {
        guard let panel else { return }
        panel.level = pinned ? .floating : .popUpMenu
        panel.collectionBehavior = pinned
            ? [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            : [.transient, .fullScreenAuxiliary, .ignoresCycle]
        guard panel.isVisible else { return }
        if pinned {
            removeMonitors()
        } else if clickMonitor == nil {
            installMonitors()
        }
    }

    private func installMonitors() {
        // Debug screenshot mode keeps the panel up despite outside clicks.
        guard ProcessInfo.processInfo.environment["MJ_SHOW_PANEL"] == nil,
              clickMonitor == nil else { return }
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

    private func removeMonitors() {
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
    }

    private func closePanel() {
        guard let panel, panel.isVisible else { return }
        model.endLiveUpdates()
        removeMonitors()
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
        // Clip the hosting layer to the glass curve — otherwise its square
        // corners paint a faint ghost outline past the rounded glass edge.
        host.wantsLayer = true
        host.layer?.cornerRadius = 26
        host.layer?.cornerCurve = .continuous
        host.layer?.masksToBounds = true
        // The "ghost outline" while the panel is key is the first responder's
        // focus ring drawn around the hosting view; this is a mouse-first
        // surface, so no rings anywhere.
        host.focusRingType = .none

        let glass = NSGlassEffectView()
        glass.style = .regular
        glass.cornerRadius = 26
        glass.focusRingType = .none
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
        p.appearance = Self.systemAppearance()

        // Clip the ENTIRE hierarchy — glass included — to the rounded shape.
        // The glass view's backdrop region is square; without an ancestor
        // mask its edges bleed past the rounded corners as a ghost outline.
        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 26
        container.layer?.cornerCurve = .continuous
        container.layer?.masksToBounds = true
        container.autoresizingMask = [.width, .height]
        glass.autoresizingMask = [.width, .height]
        p.contentView = container
        container.frame = p.contentLayoutRect
        glass.frame = container.bounds
        host.frame = glass.bounds
        container.addSubview(glass)

        panel = p
        panelHost = host

        // Agent apps don't reliably inherit system theme flips; track them.
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.panel?.appearance = Self.systemAppearance() }
        }
    }

    /// Follow the system theme, read straight from the user preference — an
    /// LSUIElement app's own effectiveAppearance can lag or resolve wrong.
    private static func systemAppearance() -> NSAppearance? {
        let dark = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleInterfaceStyle"] as? String == "Dark"
        return NSAppearance(named: dark ? .darkAqua : .aqua)
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
