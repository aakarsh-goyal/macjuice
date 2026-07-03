import AppKit
import SwiftUI

/// Chart/status accents validated (OKLCH band, chroma floor, ≥3:1 mark
/// contrast, CVD ΔE) against white and the dark popover surface.
enum Theme {
    static let charge = dynamic(light: "#0d9a66", dark: "#17a26c")
    static let power = dynamic(light: "#2a78d6", dark: "#3d85d1")
    static let warn = dynamic(light: "#b87905", dark: "#c07e00")
    static let critical = dynamic(light: "#e34948", dark: "#d95550")

    static func batteryTone(pct: Double?, onAC: Bool) -> Color {
        guard let pct else { return .secondary }
        if onAC { return charge }
        if pct <= 10 { return critical }
        if pct <= 20 { return warn }
        return charge
    }

    private static func dynamic(light: String, dark: String) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return nsColor(hex: isDark ? dark : light)
        })
    }

    private static func nsColor(hex: String) -> NSColor {
        var v = UInt64(0)
        Scanner(string: String(hex.dropFirst())).scanHexInt64(&v)
        return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
                       green: CGFloat((v >> 8) & 0xFF) / 255,
                       blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}

enum Fmt {
    /// Minutes → "2:18"
    static func hm(_ minutes: Double) -> String {
        let m = max(Int(minutes.rounded()), 0)
        return String(format: "%d:%02d", m / 60, m % 60)
    }

    static func watts(_ w: Double) -> String {
        String(format: abs(w) < 10 ? "%.1f W" : "%.0f W", w)
    }

    static func wattsShort(_ w: Double) -> String {
        String(format: abs(w) < 10 ? "%.1fW" : "%.0fW", w)
    }

    static func pct(_ p: Double, decimals: Int = 0) -> String {
        String(format: "%.\(decimals)f%%", p)
    }

    static func mAh(_ v: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return (f.string(from: NSNumber(value: v)) ?? "\(Int(v))") + " mAh"
    }

    static func clock(_ ts: Int) -> String {
        let d = Date(timeIntervalSince1970: TimeInterval(ts))
        return d.formatted(date: .omitted, time: .shortened)
    }
}
