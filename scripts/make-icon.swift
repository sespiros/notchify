#!/usr/bin/env swift

// Generate AppIcon.icns and a 1024px PNG preview for the README.
// Run from the repo root:
//   ./scripts/make-icon.swift

import AppKit
import CoreGraphics

let sizes = [16, 32, 64, 128, 256, 512, 1024]
let iconsetDir = "Resources/AppIcon.iconset"
let icnsPath = "Resources/AppIcon.icns"
let previewPath = "Resources/AppIcon.png"

try? FileManager.default.removeItem(atPath: iconsetDir)
try FileManager.default.createDirectory(atPath: iconsetDir, withIntermediateDirectories: true)

// Render the icon at a given pixel size.
func render(size px: Int) -> NSImage {
    let s = CGFloat(px)
    let img = NSImage(size: NSSize(width: s, height: s))
    img.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else {
        img.unlockFocus(); return img
    }

    // App-icon "squircle" shape.
    let corner = s * 0.225
    let bgRect = CGRect(x: 0, y: 0, width: s, height: s)
    let bgPath = CGPath(roundedRect: bgRect, cornerWidth: corner, cornerHeight: corner, transform: nil)

    // Background: dark gradient.
    let space = CGColorSpaceCreateDeviceRGB()
    let bgColors = [
        CGColor(red: 0.16, green: 0.18, blue: 0.22, alpha: 1.0),
        CGColor(red: 0.04, green: 0.05, blue: 0.07, alpha: 1.0),
    ]
    let bgGradient = CGGradient(colorsSpace: space, colors: bgColors as CFArray, locations: [0.0, 1.0])!

    // Clip everything we draw to the squircle.
    ctx.saveGState()
    ctx.addPath(bgPath)
    ctx.clip()

    // Background gradient.
    ctx.drawLinearGradient(
        bgGradient,
        start: CGPoint(x: 0, y: s),
        end: CGPoint(x: 0, y: 0),
        options: []
    )

    // Notch: attached flush to the top edge, hanging down with rounded
    // bottom corners. Clipping to the squircle naturally trims its top
    // corners against the icon's rounded top.
    let notchW = s * 0.46
    let notchH = s * 0.13
    let notchTop = s + s * 0.02          // poke slightly past top so corners blend
    let notchX = (s - notchW) / 2
    let notchY = notchTop - notchH
    let notchRadius = s * 0.05
    let notch = CGMutablePath()
    notch.move(to: CGPoint(x: notchX, y: notchTop))
    notch.addLine(to: CGPoint(x: notchX + notchW, y: notchTop))
    notch.addLine(to: CGPoint(x: notchX + notchW, y: notchY + notchRadius))
    notch.addQuadCurve(
        to: CGPoint(x: notchX + notchW - notchRadius, y: notchY),
        control: CGPoint(x: notchX + notchW, y: notchY)
    )
    notch.addLine(to: CGPoint(x: notchX + notchRadius, y: notchY))
    notch.addQuadCurve(
        to: CGPoint(x: notchX, y: notchY + notchRadius),
        control: CGPoint(x: notchX, y: notchY)
    )
    notch.closeSubpath()
    ctx.addPath(notch)
    ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
    ctx.fillPath()

    // White 5-pointed star centered in the lower portion of the icon.
    let centerX = s / 2
    let centerY = s * 0.42
    let outerR = s * 0.20
    let innerR = outerR * 0.42
    ctx.saveGState()
    ctx.translateBy(x: centerX, y: centerY)
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    let star = CGMutablePath()
    let points = 5
    for i in 0..<(points * 2) {
        // Start at top and walk clockwise.
        let r = (i % 2 == 0) ? outerR : innerR
        let angle = CGFloat(i) * .pi / CGFloat(points) - .pi / 2
        let p = CGPoint(x: cos(angle) * r, y: sin(angle) * r)
        if i == 0 { star.move(to: p) } else { star.addLine(to: p) }
    }
    star.closeSubpath()
    ctx.addPath(star)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.restoreGState()

    img.unlockFocus()
    return img
}

func savePNG(_ img: NSImage, to path: String) throws {
    guard let tiff = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "make-icon", code: 1)
    }
    try png.write(to: URL(fileURLWithPath: path))
}

// Iconset filenames follow Apple's convention: icon_<size>x<size>[@2x].png.
struct IconsetEntry { let logical: Int; let scale: Int }
let entries = [
    IconsetEntry(logical: 16, scale: 1),
    IconsetEntry(logical: 16, scale: 2),
    IconsetEntry(logical: 32, scale: 1),
    IconsetEntry(logical: 32, scale: 2),
    IconsetEntry(logical: 128, scale: 1),
    IconsetEntry(logical: 128, scale: 2),
    IconsetEntry(logical: 256, scale: 1),
    IconsetEntry(logical: 256, scale: 2),
    IconsetEntry(logical: 512, scale: 1),
    IconsetEntry(logical: 512, scale: 2),
]

for e in entries {
    let pixelSize = e.logical * e.scale
    let img = render(size: pixelSize)
    let suffix = e.scale == 1 ? "" : "@2x"
    let path = "\(iconsetDir)/icon_\(e.logical)x\(e.logical)\(suffix).png"
    try savePNG(img, to: path)
}

// 1024 preview for the README.
try savePNG(render(size: 1024), to: previewPath)

// Compile to .icns.
let proc = Process()
proc.launchPath = "/usr/bin/iconutil"
proc.arguments = ["-c", "icns", iconsetDir, "-o", icnsPath]
try proc.run()
proc.waitUntilExit()

print("wrote \(icnsPath) and \(previewPath)")
_ = sizes
