import AppKit
import Combine
import SwiftUI

/// Owns the NSStatusItem and the popover. The menu bar label re-renders only
/// when its string actually changes, and the label-refresh timer pauses while
/// the displays are asleep.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let model: BatteryModel
    private let settings: Settings
    private let item: NSStatusItem
    private let popover = NSPopover()
    private var cancellables = Set<AnyCancellable>()
    private var labelTimer: Timer?
    private var lastTitle = "\u{0}"   // sentinel so the first update always applies

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
            button.action = #selector(togglePopover)
        }

        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = NSHostingController(
            rootView: PopoverView()
                .environmentObject(model)
                .environmentObject(settings)
        )

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

        let wsc = NSWorkspace.shared.notificationCenter
        wsc.addObserver(self, selector: #selector(screensSlept),
                        name: NSWorkspace.screensDidSleepNotification, object: nil)
        wsc.addObserver(self, selector: #selector(screensWoke),
                        name: NSWorkspace.screensDidWakeNotification, object: nil)
        configureLabelTimer()
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
    }

    @objc private func screensWoke() {
        model.updateLive()
        configureLabelTimer()
    }

    // MARK: - Popover

    @objc private func togglePopover() {
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
