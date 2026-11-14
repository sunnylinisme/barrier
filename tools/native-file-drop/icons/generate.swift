// SPDX-License-Identifier: GPL-2.0-or-later
// Run with `swift generate.swift OUTPUT_DIRECTORY`; resize the approved PNG master.
import AppKit
let destination = URL(fileURLWithPath: CommandLine.arguments[1])
let master = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("BarrierShare.png")
guard let source = NSImage(contentsOf: master) else { fatalError("Missing icon master: \(master.path)") }
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
for size in [16, 32, 64, 128, 256, 512, 1024] {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSGraphicsContext.current!.imageInterpolation = .high
    source.draw(in: NSRect(x: 0, y: 0, width: size, height: size), from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: destination.appendingPathComponent("icon-\(size).png"))
}
