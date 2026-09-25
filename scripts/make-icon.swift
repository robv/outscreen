#!/usr/bin/env swift
import AppKit
import Foundation

// Render from geometry so every source build includes the same original icon.
guard CommandLine.arguments.count == 2 else {
    fputs("Usage: make-icon.swift <output.png>\n", stderr)
    exit(64)
}

let size = 1024
guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
    isPlanar: false, colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 0
), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fputs("Unable to create the icon drawing context.\n", stderr)
    exit(1)
}

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> NSColor {
    NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
}

func rounded(_ rect: NSRect, radius: CGFloat, fill: NSColor) {
    fill.setFill()
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
}

let charcoal = color(0.12, 0.13, 0.17)
let screenDark = color(0.07, 0.08, 0.11)
let shell = color(0.89, 0.88, 0.96)
let periwinkle = color(0.69, 0.65, 0.92)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.imageInterpolation = .high
context.shouldAntialias = true

rounded(NSRect(x: 96, y: 96, width: 832, height: 832), radius: 184, fill: charcoal)

// The active external monitor sits above and behind the sleeping laptop.
rounded(NSRect(x: 475, y: 302, width: 94, height: 106), radius: 10, fill: shell)
rounded(NSRect(x: 397, y: 284, width: 250, height: 27), radius: 13.5, fill: shell)
rounded(NSRect(x: 268, y: 380, width: 526, height: 370), radius: 36, fill: shell)
rounded(NSRect(x: 289, y: 401, width: 484, height: 328), radius: 19, fill: periwinkle)

// A darker perimeter separates the laptop cleanly from the monitor behind it.
rounded(NSRect(x: 199, y: 243, width: 356, height: 251), radius: 31, fill: charcoal)
rounded(NSRect(x: 210, y: 254, width: 334, height: 229), radius: 22, fill: shell)
rounded(NSRect(x: 227, y: 271, width: 300, height: 195), radius: 9, fill: screenDark)
rounded(NSRect(x: 180, y: 227, width: 394, height: 28), radius: 14, fill: shell)
rounded(NSRect(x: 332, y: 243, width: 90, height: 12), radius: 6, fill: charcoal)

NSGraphicsContext.restoreGraphicsState()
guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fputs("Unable to encode the icon PNG.\n", stderr)
    exit(1)
}
do {
    try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
} catch {
    fputs("Unable to write the icon: \(error.localizedDescription)\n", stderr)
    exit(1)
}
