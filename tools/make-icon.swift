// Draws AppIcon.icns: a white headphones glyph on a green squircle.
// Run from the project root after changing the look:
//
//   swift tools/make-icon.swift
//
// build.sh copies the .icns into the bundle, so a rebuild is what applies it.

import AppKit

let iconset = URL(fileURLWithPath: "build/AppIcon.iconset")
let out = URL(fileURLWithPath: "AppIcon.icns")

// Every pixel size iconutil wants, and the names it expects for each.
let files: [Int: [String]] = [
    16: ["icon_16x16.png"],
    32: ["icon_16x16@2x.png", "icon_32x32.png"],
    64: ["icon_32x32@2x.png"],
    128: ["icon_128x128.png"],
    256: ["icon_128x128@2x.png", "icon_256x256.png"],
    512: ["icon_256x256@2x.png", "icon_512x512.png"],
    1024: ["icon_512x512@2x.png"],
]

/// The symbol in white, rendered on its own so tinting can't touch the background.
func glyph(pointSize: CGFloat) -> NSImage? {
    let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
    guard let base = NSImage(systemSymbolName: "headphones", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) else { return nil }
    let size = base.size
    let tinted = NSImage(size: size)
    tinted.lockFocus()
    base.draw(in: NSRect(origin: .zero, size: size))
    NSColor.white.setFill()
    NSRect(origin: .zero, size: size).fill(using: .sourceAtop)
    tinted.unlockFocus()
    return tinted
}

/// Exact pixel dimensions, so nothing gets rendered at the screen's 2x scale.
func render(size: Int) -> Data {
    let s = CGFloat(size)
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                    isPlanar: false, colorSpaceName: .deviceRGB,
                                    bytesPerRow: 0, bitsPerPixel: 0)
    else { fatalError("no bitmap at \(size)") }
    rep.size = NSSize(width: s, height: s)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high

    // macOS icon art sits inside a margin rather than filling the canvas.
    let inset = s * 0.08
    let rect = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = rect.width * 0.225
    let squircle = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    NSGradient(starting: NSColor(srgbRed: 0.22, green: 0.80, blue: 0.45, alpha: 1),
               ending: NSColor(srgbRed: 0.04, green: 0.42, blue: 0.28, alpha: 1))?
        .draw(in: squircle, angle: -90)

    if let symbol = glyph(pointSize: s * 0.54) {
        let g = symbol.size
        symbol.draw(in: NSRect(x: (s - g.width) / 2, y: (s - g.height) / 2,
                               width: g.width, height: g.height))
    }

    NSGraphicsContext.restoreGraphicsState()
    guard let png = rep.representation(using: .png, properties: [:]) else {
        fatalError("no png at \(size)")
    }
    return png
}

try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for (size, names) in files {
    let png = render(size: size)
    for name in names {
        try png.write(to: iconset.appendingPathComponent(name))
    }
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { exit(iconutil.terminationStatus) }
print("wrote \(out.lastPathComponent) from \(files.values.joined().count) pngs")
