// SPDX-License-Identifier: GPL-2.0-or-later
// Run with `swift generate.swift OUTPUT_DIRECTORY`; creates the vector-drawn PNG masters.
import AppKit
let destination = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
for size in [16, 32, 64, 128, 256, 512, 1024] {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    (AffineTransform(scale: CGFloat(size)/1024) as NSAffineTransform).concat()
    func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
        NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }
    let tile = NSBezierPath(roundedRect: NSRect(x: 40, y: 40, width: 944, height: 944), xRadius: 214, yRadius: 214)
    NSGradient(starting: color(0.98, 0.99, 1), ending: color(0.82, 0.88, 0.96))!.draw(in: tile, angle: -70)
    // A slightly heavier mark stays clear at the 16 px Windows title/tray size.
    let weight: CGFloat = size == 16 ? 64 : 48
    let ink = color(0.12, 0.26, 0.45)
    func frame(_ rect: NSRect, _ stroke: NSColor) {
        let line = NSBezierPath(roundedRect: rect, xRadius: 64, yRadius: 64)
        line.lineWidth = weight; stroke.setStroke(); line.stroke()
    }
    frame(NSRect(x: 220, y: 411, width: 366, height: 318), ink)
    let front = NSBezierPath(roundedRect: NSRect(x: 413, y: 268, width: 395, height: 347), xRadius: 80, yRadius: 80)
    color(0.89, 0.93, 0.98).setFill(); front.fill()
    frame(NSRect(x: 438, y: 293, width: 366, height: 318), color(0.10, 0.40, 0.94))
    let bridge = NSBezierPath()
    bridge.move(to: NSPoint(x: 458, y: 505)); bridge.line(to: NSPoint(x: 564, y: 505))
    bridge.lineWidth = weight; bridge.lineCapStyle = .round; ink.setStroke(); bridge.stroke()
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: destination.appendingPathComponent("icon-\(size).png"))
}
