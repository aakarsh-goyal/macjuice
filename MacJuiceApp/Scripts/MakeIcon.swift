// Renders AppIcon.icns: an SF Symbols bolt with a white→mint gradient on a
// deep green-slate squircle. Run: swift Scripts/MakeIcon.swift <output-dir>
import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Support"
let canvas: CGFloat = 1024
let square: CGFloat = 824          // Big Sur icon grid: art box centered in canvas
let radius: CGFloat = square * 0.2237

let image = NSImage(size: NSSize(width: canvas, height: canvas))
image.lockFocus()

let inset = (canvas - square) / 2
let box = NSRect(x: inset, y: inset, width: square, height: square)
let squircle = NSBezierPath(roundedRect: box, xRadius: radius, yRadius: radius)

// Background: deep slate-green, lit from the top.
NSGradient(colors: [
    NSColor(srgbRed: 0.10, green: 0.24, blue: 0.19, alpha: 1),
    NSColor(srgbRed: 0.03, green: 0.09, blue: 0.07, alpha: 1),
])!.draw(in: squircle, angle: -90)

// Soft green energy glow behind the bolt.
squircle.addClip()
NSGradient(colors: [
    NSColor(srgbRed: 0.09, green: 0.64, blue: 0.42, alpha: 0.55),
    NSColor(srgbRed: 0.09, green: 0.64, blue: 0.42, alpha: 0.0),
])!.draw(fromCenter: NSPoint(x: canvas / 2, y: canvas / 2 - 40), radius: 30,
         toCenter: NSPoint(x: canvas / 2, y: canvas / 2 - 40), radius: 430,
         options: [])

// Bolt glyph, gradient-filled via source-atop compositing on its own layer.
let config = NSImage.SymbolConfiguration(pointSize: 560, weight: .semibold)
if let bolt = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil)?
    .withSymbolConfiguration(config) {
    let scale = min(430 / bolt.size.width, 500 / bolt.size.height)
    let size = NSSize(width: bolt.size.width * scale, height: bolt.size.height * scale)

    let layer = NSImage(size: NSSize(width: canvas, height: canvas))
    layer.lockFocus()
    let origin = NSPoint(x: (canvas - size.width) / 2, y: (canvas - size.height) / 2)
    bolt.draw(in: NSRect(origin: origin, size: size), from: .zero,
              operation: .sourceOver, fraction: 1)
    NSGradient(colors: [
        NSColor(srgbRed: 0.78, green: 1.0, blue: 0.90, alpha: 1),
        NSColor.white,
    ])!.draw(in: NSRect(x: 0, y: 0, width: canvas, height: canvas), angle: -90)
    // Keep gradient only where the bolt is.
    layer.unlockFocus()

    // Redo with explicit compositing: bolt alpha mask, then gradient atop.
    let boltLayer = NSImage(size: NSSize(width: canvas, height: canvas))
    boltLayer.lockFocus()
    bolt.draw(in: NSRect(origin: origin, size: size), from: .zero,
              operation: .sourceOver, fraction: 1)
    if let ctx = NSGraphicsContext.current?.cgContext {
        ctx.setBlendMode(.sourceAtop)
        let colors = [
            NSColor.white.cgColor,
            NSColor(srgbRed: 0.72, green: 0.98, blue: 0.86, alpha: 1).cgColor,
        ] as CFArray
        if let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                 colors: colors, locations: [0, 1]) {
            ctx.drawLinearGradient(grad,
                                   start: CGPoint(x: canvas / 2, y: canvas),
                                   end: CGPoint(x: canvas / 2, y: 0),
                                   options: [])
        }
    }
    boltLayer.unlockFocus()

    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
    shadow.shadowBlurRadius = 26
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.set()
    boltLayer.draw(in: NSRect(x: 0, y: 0, width: canvas, height: canvas),
                   from: .zero, operation: .sourceOver, fraction: 1)
}
image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fputs("render failed\n", stderr)
    exit(1)
}
let master = "\(outDir)/icon-master.png"
try! png.write(to: URL(fileURLWithPath: master))
print(master)
