import AppKit
import Foundation

guard CommandLine.arguments.count == 3 else {
    fputs("usage: swift normalize_app_icon.swift <input.png> <output.png>\n", stderr)
    exit(2)
}

let inputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])
guard let source = NSImage(contentsOf: inputURL) else {
    fputs("unable to read input image\n", stderr)
    exit(1)
}

let pixels = 1024
guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: pixels,
    pixelsHigh: pixels,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bitmapFormat: [],
    bytesPerRow: pixels * 4,
    bitsPerPixel: 32
), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fputs("unable to create output bitmap\n", stderr)
    exit(1)
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.imageInterpolation = .high
let canvas = NSRect(x: 0, y: 0, width: pixels, height: pixels)
NSColor.clear.setFill()
canvas.fill(using: .copy)

let iconBounds = NSRect(x: 108, y: 108, width: 808, height: 808)
NSBezierPath(roundedRect: iconBounds, xRadius: 176, yRadius: 176).addClip()
source.draw(in: canvas, from: .zero, operation: .sourceOver, fraction: 1)
NSGraphicsContext.restoreGraphicsState()

guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fputs("unable to encode output PNG\n", stderr)
    exit(1)
}
try png.write(to: outputURL, options: .atomic)
