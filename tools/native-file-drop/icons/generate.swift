// SPDX-License-Identifier: GPL-2.0-or-later
// Run with `swift generate.swift OUTPUT_DIRECTORY`; creates the vector-drawn PNG masters.
import AppKit
let destination = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
for size in [16, 32, 64, 128, 256, 512, 1024] {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let transform = AffineTransform(scale: CGFloat(size)/1024)
    (transform as NSAffineTransform).concat()
    let background = NSBezierPath(roundedRect: NSRect(x: 40, y: 40, width: 944, height: 944), xRadius: 214, yRadius: 214)
    NSGradient(starting: NSColor(srgbRed: 0.21, green: 0.49, blue: 1, alpha: 1), ending: NSColor(srgbRed: 0.10, green: 0.23, blue: 0.72, alpha: 1))!.draw(in: background, angle: -70)
    func panel(_ rect: NSRect, _ opacity: CGFloat) {
        NSColor.white.withAlphaComponent(opacity).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 48, yRadius: 48).fill()
        NSColor(srgbRed: 0.18, green: 0.37, blue: 0.85, alpha: 1).setFill()
        NSBezierPath(roundedRect: rect.insetBy(dx: 25, dy: 25), xRadius: 26, yRadius: 26).fill()
    }
    panel(NSRect(x: 188, y: 425, width: 410, height: 320), 0.60)
    panel(NSRect(x: 426, y: 279, width: 410, height: 320), 1)
    func arrow(_ x1: CGFloat, _ x2: CGFloat, _ y: CGFloat) {
        let direction: CGFloat = x2 > x1 ? 1 : -1
        let path = NSBezierPath(); path.lineWidth = 35; path.lineCapStyle = .round; path.lineJoinStyle = .round
        path.move(to: NSPoint(x: x1, y: y)); path.line(to: NSPoint(x: x2, y: y))
        path.move(to: NSPoint(x: x2-direction*55, y: y+55)); path.line(to: NSPoint(x: x2, y: y)); path.line(to: NSPoint(x: x2-direction*55, y: y-55))
        NSColor.white.setStroke(); path.stroke()
    }
    arrow(310, 710, 556); arrow(710, 310, 451)
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: destination.appendingPathComponent("icon-\(size).png"))
}
