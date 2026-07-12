import AppKit
import SwiftUI

/// The plug-in moment — macOS's answer to the Apple Pencil attach animation
/// on iPad. A green glow blooms along the display edge (running around the
/// notch on machines that have one) while an Apple Pencil-style capsule —
/// device name, percentage, tiny green battery — slides out from under the
/// notch, floats a beat, and retracts.
///
/// Pure overlay theatre: one borderless, transparent, click-through window
/// at screen-saver level that lives for ~3.5 s and is torn down completely —
/// no special permissions, no idle cost.
@MainActor
final class ChargeEffect {
    static let shared = ChargeEffect()
    private var window: NSWindow?
    private var lastPlay = Date.distantPast

    func play(_ snap: BatterySnapshot, title: String) {
        // The bloom wears the battery's state color: red when low, Low Power
        // Mode yellow, otherwise charging green — same rule as the pill glyph.
        let tone: NSColor = {
            if (snap.chargePct ?? 100) <= 20 { return .systemRed }
            if snap.lowPowerMode { return .systemYellow }
            return .systemGreen
        }()
        present(symbol: "macbook.gen2", title: title,
                pct: snap.chargePct.map { Int($0.rounded()) }, showsBattery: true,
                lowPower: snap.lowPowerMode, bolt: snap.onAC, tone: tone,
                showGlow: Settings.shared.effectGlow,
                showPill: Settings.shared.effectPill)
    }

    /// A Bluetooth accessory joined — same notch pill, the device's own
    /// glyph, battery only when the peripheral reports one (AirPods do; most
    /// HID and speakers don't). Pill only: the glow stays the charger's moment.
    func playAccessory(name: String, symbol: String, pct: Int?, isRetry: Bool = false) {
        guard Settings.shared.effectBTPill else { return }
        if window != nil || Date().timeIntervalSince(lastPlay) <= 5 {
            // Stage is busy (charge moment, or two accessories at once) —
            // one polite second attempt, then let it go.
            if !isRetry {
                DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) { [weak self] in
                    self?.playAccessory(name: name, symbol: symbol, pct: pct,
                                        isRetry: true)
                }
            }
            return
        }
        present(symbol: symbol, title: name, pct: pct, showsBattery: pct != nil,
                lowPower: false, bolt: false, tone: .systemGreen,
                showGlow: false, showPill: true)
    }

    private func present(symbol: String, title: String, pct: Int?,
                         showsBattery: Bool, lowPower: Bool, bolt: Bool,
                         tone: NSColor, showGlow: Bool, showPill: Bool) {
        guard showGlow || showPill,
              window == nil,
              Date().timeIntervalSince(lastPlay) > 5 else { return }  // cable jiggle
        lastPlay = Date()
        // The battery lives in the built-in (notched) display; fall back to
        // the main screen in clamshell mode, where the pill drops from the
        // top edge instead.
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 })
                ?? NSScreen.main else { return }

        var notch: CGRect?
        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            notch = CGRect(x: left.width, y: 0,
                           width: screen.frame.width - left.width - right.width,
                           height: screen.safeAreaInsets.top)
        }
        // No public API exposes the panel's physical corner radius (the old
        // private NSScreen key is gone on macOS 27), so: tuned default,
        // user-overridable live via `defaults write com.macjuice.app
        // glowCornerRadius -float N`.
        let stored = UserDefaults.standard.double(forKey: "glowCornerRadius")
        let radius = stored > 0 ? CGFloat(stored) : (notch != nil ? 26 : 14)

        let model = EffectModel()
        let view = ChargeEffectView(model: model, notch: notch, corner: radius,
                                    symbol: symbol, title: title, pct: pct,
                                    showsBattery: showsBattery,
                                    lowPower: lowPower, bolt: bolt,
                                    tone: Color(nsColor: tone),
                                    showGlow: showGlow, showPill: showPill)
        let w = NSWindow(contentRect: screen.frame, styleMask: .borderless,
                         backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.level = .screenSaver
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        w.animationBehavior = .none
        let dark = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
        w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        // Default sizingOptions let NSHostingView shrink the window to the
        // content's ideal size — the full-screen glow collapses to a strip.
        let host = NSHostingView(rootView: view.frame(width: screen.frame.width,
                                                      height: screen.frame.height))
        host.sizingOptions = []
        w.contentView = host
        w.setFrame(screen.frame, display: true)
        w.orderFrontRegardless()
        window = w

        model.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.8) { [weak self] in
            self?.teardown()
        }
    }

    private func teardown() {
        window?.orderOut(nil)
        window?.contentView = nil
        window = nil
    }
}

/// Drives the animation phases. Lives outside view @State because the CLT
/// toolchain lacks SwiftUI's macro plugin.
@MainActor
private final class EffectModel: ObservableObject {
    @Published var glow: Double = 0
    @Published var pillOut = false

    func run() {
        withAnimation(.easeOut(duration: 0.55)) { glow = 1 }
        after(0.25) { withAnimation(.spring(response: 0.55, dampingFraction: 0.85)) { self.pillOut = true } }
        // One slow breath while it holds.
        after(1.50) { withAnimation(.easeInOut(duration: 0.6)) { self.glow = 0.72 } }
        after(2.10) { withAnimation(.easeInOut(duration: 0.55)) { self.glow = 1 } }
        after(2.85) { withAnimation(.easeIn(duration: 0.34)) { self.pillOut = false } }
        after(2.95) { withAnimation(.easeOut(duration: 0.65)) { self.glow = 0 } }
    }

    private func after(_ s: Double, _ body: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + s) { body() }
    }
}

private struct ChargeEffectView: View {
    @ObservedObject var model: EffectModel
    let notch: CGRect?
    let corner: CGFloat
    let symbol: String
    let title: String
    let pct: Int?
    let showsBattery: Bool
    let lowPower: Bool
    let bolt: Bool
    let tone: Color
    let showGlow: Bool
    let showPill: Bool

    var body: some View {
        GeometryReader { geo in
            let edge = ScreenEdgeShape(notch: notch, corner: corner)
            ZStack(alignment: .top) {
                if showGlow {
                    // An edge vignette (not a flat dim — a sudden brightness
                    // drop across the whole screen is jarring) gives the bloom
                    // contrast on light content while the center never changes.
                    edge.stroke(Color.black.opacity(0.45), lineWidth: 44).blur(radius: 34)
                    // A bloom, not a line: wide soft halos bleeding inward
                    // under progressively tighter, brighter cores.
                    edge.stroke(tone.opacity(0.42), lineWidth: 26).blur(radius: 24)
                    edge.stroke(tone.opacity(0.62), lineWidth: 12).blur(radius: 10)
                    edge.stroke(tone.opacity(0.95), lineWidth: 4).blur(radius: 3)
                    edge.stroke(tone, lineWidth: 1.8)
                        .shadow(color: tone, radius: 5)
                }
                if showPill {
                    pill(in: geo.size)
                }
            }
            .opacity(model.glow)
        }
        .ignoresSafeArea()
    }

    /// The Apple Pencil capsule: device name over percentage + a tiny green
    /// battery, on system material with a soft shadow. It slides out from
    /// under the notch (the clip container's top edge is the notch's bottom,
    /// so it truly emerges from the hardware) and floats detached.
    @ViewBuilder
    private func pill(in size: CGSize) -> some View {
        let clipTop = notch?.height ?? 0
        glassCapsule {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(.primary)
                VStack(spacing: 1) {
                    Text(title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.primary)
                    if showsBattery {
                        HStack(spacing: 5) {
                            if let pct {
                                Text("\(pct)%")
                                    .font(.system(size: 11, weight: .medium))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            MiniBattery(pct: pct ?? 100, lowPower: lowPower,
                                        showBolt: bolt)
                        }
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, showsBattery ? 6 : 10)
            .padding(.bottom, showsBattery ? 7 : 10)
        }
        .shadow(color: .black.opacity(0.24), radius: 13, y: 5)
        .offset(y: model.pillOut ? 10 : -75)
        .frame(maxWidth: .infinity)
        .frame(height: 95, alignment: .top)
        .clipped()
        .offset(y: clipTop)
    }

    /// Liquid Glass on macOS 26+ (real lensing of whatever is behind the
    /// pill; the glass brings its own rim lighting, so no hairline stroke),
    /// frosted material below.
    @ViewBuilder
    private func glassCapsule<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        if #available(macOS 26.0, *) {
            content().glassEffect(.regular, in: Capsule())
        } else {
            content().background(.regularMaterial, in: Capsule())
        }
    }
}

/// The iOS-style battery glyph, 21 pt wide, filled in the battery's state
/// tone — red when low, Low Power Mode yellow, otherwise charging green —
/// with the system's white charging bolt over it.
private struct MiniBattery: View {
    let pct: Int
    let lowPower: Bool
    let showBolt: Bool

    private var tone: Color {
        if pct <= 20 { return Color(nsColor: .systemRed) }
        if lowPower { return Color(nsColor: .systemYellow) }
        return Color(nsColor: .systemGreen)
    }

    var body: some View {
        HStack(spacing: 1) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(.secondary.opacity(0.6), lineWidth: 1)
                    .frame(width: 21, height: 11)
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(tone)
                    .frame(width: max(2.5, 17 * CGFloat(pct) / 100), height: 7)
                    .padding(.leading, 2)
                if showBolt {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.55), radius: 0.6, y: 0.4)
                        .frame(width: 21)
                }
            }
            RoundedRectangle(cornerRadius: 0.8)
                .fill(.secondary.opacity(0.6))
                .frame(width: 1.5, height: 4)
        }
        .accessibilityHidden(true)
    }
}

/// The display's usable border: a rounded rect that detours around the notch
/// cutout, with small outward flares where the notch meets the top edge —
/// the same curve language as the hardware.
private struct ScreenEdgeShape: Shape {
    let notch: CGRect?
    let corner: CGFloat

    func path(in rect: CGRect) -> Path {
        let i: CGFloat = 1.0      // inset so the stroke hugs the physical edge
        let r = corner
        let f: CGFloat = 6        // notch top flare
        let n: CGFloat = 9        // notch bottom corner radius
        let (x0, y0) = (rect.minX + i, rect.minY + i)
        let (x1, y1) = (rect.maxX - i, rect.maxY - i)
        var p = Path()
        p.move(to: CGPoint(x: x0 + r, y: y0))
        if let notch {
            let (nl, nr, nb) = (notch.minX, notch.maxX, y0 + notch.height)
            p.addLine(to: CGPoint(x: nl - f, y: y0))
            p.addQuadCurve(to: CGPoint(x: nl, y: y0 + f), control: CGPoint(x: nl, y: y0))
            p.addLine(to: CGPoint(x: nl, y: nb - n))
            p.addQuadCurve(to: CGPoint(x: nl + n, y: nb), control: CGPoint(x: nl, y: nb))
            p.addLine(to: CGPoint(x: nr - n, y: nb))
            p.addQuadCurve(to: CGPoint(x: nr, y: nb - n), control: CGPoint(x: nr, y: nb))
            p.addLine(to: CGPoint(x: nr, y: y0 + f))
            p.addQuadCurve(to: CGPoint(x: nr + f, y: y0), control: CGPoint(x: nr, y: y0))
        }
        p.addLine(to: CGPoint(x: x1 - r, y: y0))
        p.addQuadCurve(to: CGPoint(x: x1, y: y0 + r), control: CGPoint(x: x1, y: y0))
        p.addLine(to: CGPoint(x: x1, y: y1 - r))
        p.addQuadCurve(to: CGPoint(x: x1 - r, y: y1), control: CGPoint(x: x1, y: y1))
        p.addLine(to: CGPoint(x: x0 + r, y: y1))
        p.addQuadCurve(to: CGPoint(x: x0, y: y1 - r), control: CGPoint(x: x0, y: y1))
        p.addLine(to: CGPoint(x: x0, y: y0 + r))
        p.addQuadCurve(to: CGPoint(x: x0 + r, y: y0), control: CGPoint(x: x0, y: y0))
        p.closeSubpath()
        return p
    }
}
