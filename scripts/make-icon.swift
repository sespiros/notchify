#!/usr/bin/env swift

// Slice Resources/AppIcon-master.png into the iconset, compile to .icns,
// and write a 1024px PNG preview. Run from the repo root:
//   ./scripts/make-icon.swift

import AppKit
import Foundation

let masterPath = "Resources/AppIcon-master.png"
let iconsetDir = "Resources/AppIcon.iconset"
let icnsPath = "Resources/AppIcon.icns"
let previewPath = "Resources/AppIcon.png"

guard let master = NSImage(contentsOfFile: masterPath) else {
    FileHandle.standardError.write(Data("missing \(masterPath)\n".utf8))
    exit(1)
}

try? FileManager.default.removeItem(atPath: iconsetDir)
try FileManager.default.createDirectory(atPath: iconsetDir, withIntermediateDirectories: true)

func resize(_ src: NSImage, to px: Int) -> NSImage {
    let s = CGFloat(px)
    let img = NSImage(size: NSSize(width: s, height: s))
    img.lockFocus()
    NSGraphicsContext.current?.imageInterpolation = .high
    src.draw(
        in: NSRect(x: 0, y: 0, width: s, height: s),
        from: .zero, operation: .copy, fraction: 1.0
    )
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
    let suffix = e.scale == 1 ? "" : "@2x"
    let path = "\(iconsetDir)/icon_\(e.logical)x\(e.logical)\(suffix).png"
    try savePNG(resize(master, to: pixelSize), to: path)
}

try savePNG(resize(master, to: 1024), to: previewPath)

let proc = Process()
proc.launchPath = "/usr/bin/iconutil"
proc.arguments = ["-c", "icns", iconsetDir, "-o", icnsPath]
try proc.run()
proc.waitUntilExit()

print("wrote \(icnsPath) and \(previewPath)")
