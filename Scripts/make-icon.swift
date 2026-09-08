// SPDX-FileCopyrightText: 2026 Luca Gibelli
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit

// Generates Idlewild.icns. The mark is the same ECG trace the menu bar uses
// when calm, so the app's identity and its resting state agree.
// Canvas is 1024; the rounded square occupies the Big Sur icon grid (824pt).

let S: CGFloat = 1024
let inset: CGFloat = 100
let side = S - inset * 2
let radius = side * 0.2237          // Apple's continuous-corner ratio

func makeIcon() -> NSImage {
    let img = NSImage(size: NSSize(width: S, height: S))
    img.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else { img.unlockFocus(); return img }

    let rect = CGRect(x: inset, y: inset, width: side, height: side)
    let squircle = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

    ctx.saveGState()
    squircle.addClip()
    // Deep indigo to near-black: quiet, not alarming.
    let colors = [NSColor(srgbRed: 0.13, green: 0.16, blue: 0.30, alpha: 1).cgColor,
                  NSColor(srgbRed: 0.05, green: 0.05, blue: 0.10, alpha: 1).cgColor] as CFArray
    if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: colors, locations: [0, 1]) {
        ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: S),
                               end: CGPoint(x: 0, y: 0), options: [])
    }
    ctx.restoreGState()

    // The ECG trace: flat, one strong beat, flat again.
    let midY = S / 2
    let x0 = inset + side * 0.13
    let x1 = inset + side * 0.87
    let w = x1 - x0
    let p = NSBezierPath()
    p.lineWidth = 46
    p.lineCapStyle = .round
    p.lineJoinStyle = .round
    p.move(to: CGPoint(x: x0, y: midY))
    p.line(to: CGPoint(x: x0 + w * 0.30, y: midY))
    p.line(to: CGPoint(x: x0 + w * 0.38, y: midY + side * 0.20))   // spike up
    p.line(to: CGPoint(x: x0 + w * 0.50, y: midY - side * 0.24))   // spike down
    p.line(to: CGPoint(x: x0 + w * 0.60, y: midY + side * 0.06))
    p.line(to: CGPoint(x: x0 + w * 0.68, y: midY))
    p.line(to: CGPoint(x: x1, y: midY))

    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 40,
                  color: NSColor(srgbRed: 0.45, green: 0.75, blue: 1.0, alpha: 0.85).cgColor)
    NSColor(srgbRed: 0.72, green: 0.88, blue: 1.0, alpha: 1).setStroke()
    p.stroke()
    ctx.restoreGState()

    img.unlockFocus()
    return img
}

func png(_ img: NSImage, _ size: Int) -> Data? {
    let target = NSImage(size: NSSize(width: size, height: size))
    target.lockFocus()
    img.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    target.unlockFocus()
    guard let tiff = target.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff) else { return nil }
    rep.size = NSSize(width: size, height: size)
    return rep.representation(using: .png, properties: [:])
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/Idlewild.iconset"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
let icon = makeIcon()
// The sizes iconutil expects.
let specs: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256),
    ("icon_256x256@2x", 512), ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in specs {
    guard let d = png(icon, px) else { continue }
    try? d.write(to: URL(fileURLWithPath: "\(out)/\(name).png"))
}
print("wrote iconset to \(out)")