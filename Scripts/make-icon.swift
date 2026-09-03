#!/usr/bin/env swift
//
// Draws Folio's app icon and packs it into Resources/AppIcon.icns.
//
// The icon is generated rather than checked in so the repository carries no
// binary assets: the vector description below is the source of truth, and both
// AppIcon.iconset/ and AppIcon.icns are build products (see .gitignore).
//
// Usage: swift Scripts/make-icon.swift
//

import AppKit
import Foundation

// MARK: - Palette

private func rgb(_ hex: UInt32) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: 1
    )
}

private let tintTop = rgb(0x8B7CFF)   // lit edge of the tile
private let tintBottom = rgb(0x4B35C7) // shadowed edge
private let pageFill = rgb(0xFFFFFF)
private let foldFill = rgb(0xDAD6F5)   // the underside of the turned corner
private let ruleInk = rgb(0xB9B4D8)
private let headingInk = rgb(0x6D5BF5)

// MARK: - Geometry

/// The rounded tile, matching Apple's icon grid: the art occupies ~80.5% of the
/// canvas, with a corner radius of ~22.5% of the tile.
private func tileRect(canvas: CGFloat) -> NSRect {
    let side = canvas * 0.8047
    let inset = (canvas - side) / 2
    return NSRect(x: inset, y: inset, width: side, height: side)
}

/// A page with its top-right corner turned down.
private func pagePath(in rect: NSRect, fold: CGFloat, radius: CGFloat) -> NSBezierPath {
    let foldRadius = radius * 0.5
    let a = NSPoint(x: rect.minX, y: rect.minY)                    // bottom-left
    let b = NSPoint(x: rect.minX, y: rect.maxY)                    // top-left
    let c = NSPoint(x: rect.maxX - fold, y: rect.maxY)             // top, at the fold
    let d = NSPoint(x: rect.maxX, y: rect.maxY - fold)             // right, at the fold
    let e = NSPoint(x: rect.maxX, y: rect.minY)                    // bottom-right

    let path = NSBezierPath()
    path.move(to: NSPoint(x: rect.minX, y: rect.midY))
    path.appendArc(from: b, to: c, radius: radius)
    path.appendArc(from: c, to: d, radius: foldRadius)
    path.appendArc(from: d, to: e, radius: foldRadius)
    path.appendArc(from: e, to: a, radius: radius)
    path.appendArc(from: a, to: b, radius: radius)
    path.close()
    return path
}

// MARK: - Drawing

private func drawIcon(size: CGFloat) -> NSBitmapImageRep {
    let pixels = Int(size)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .calibratedRGB,
        bytesPerRow: pixels * 4,
        bitsPerPixel: 32
    )!
    rep.size = NSSize(width: size, height: size)

    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high

    let tile = tileRect(canvas: size)
    let tileRadius = size * 0.1811
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: tileRadius, yRadius: tileRadius)

    // Tile shadow. Skipped at the small sizes, where it only reads as grime.
    if size >= 64 {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
        shadow.shadowOffset = NSSize(width: 0, height: -size * 0.012)
        shadow.shadowBlurRadius = size * 0.032
        shadow.set()
        rgb(0x000000).setFill()
        tilePath.fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    // Tile body.
    NSGraphicsContext.saveGraphicsState()
    tilePath.addClip()
    NSGradient(starting: tintTop, ending: tintBottom)!.draw(in: tile, angle: -90)
    // A soft highlight along the top edge keeps the tile from reading as flat.
    if size >= 64 {
        let highlight = NSGradient(
            colors: [NSColor.white.withAlphaComponent(0.22), NSColor.white.withAlphaComponent(0)]
        )!
        highlight.draw(in: NSRect(x: tile.minX, y: tile.midY, width: tile.width, height: tile.height / 2), angle: -90)
    }
    NSGraphicsContext.restoreGraphicsState()

    // The page.
    let pageWidth = tile.width * 0.52
    let pageHeight = pageWidth * 1.26
    let page = NSRect(
        x: tile.midX - pageWidth / 2,
        y: tile.midY - pageHeight / 2,
        width: pageWidth,
        height: pageHeight
    )
    let fold = pageWidth * 0.30
    let pageRadius = pageWidth * 0.075

    if size >= 64 {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(srgbRed: 0.13, green: 0.08, blue: 0.38, alpha: 0.34)
        shadow.shadowOffset = NSSize(width: 0, height: -size * 0.008)
        shadow.shadowBlurRadius = size * 0.022
        shadow.set()
        pageFill.setFill()
        pagePath(in: page, fold: fold, radius: pageRadius).fill()
        NSGraphicsContext.restoreGraphicsState()
    } else {
        pageFill.setFill()
        pagePath(in: page, fold: fold, radius: pageRadius).fill()
    }

    // The turned corner, drawn as the sheet's underside.
    let foldPath = NSBezierPath()
    foldPath.move(to: NSPoint(x: page.maxX - fold, y: page.maxY))
    foldPath.line(to: NSPoint(x: page.maxX - fold, y: page.maxY - fold))
    foldPath.line(to: NSPoint(x: page.maxX, y: page.maxY - fold))
    foldPath.close()
    foldFill.setFill()
    foldPath.fill()

    // Ruled lines. Below 64px these collapse into a smear, so the page stays blank.
    if size >= 64 {
        let margin = pageWidth * 0.15
        let lineX = page.minX + margin
        let fullWidth = page.width - margin * 2
        let lineHeight = pageHeight * 0.052
        let gap = pageHeight * 0.086
        var lineY = page.maxY - fold - pageHeight * 0.10

        // A heading rule in the brand tint, then body rules in muted ink.
        headingInk.setFill()
        NSBezierPath(
            roundedRect: NSRect(x: lineX, y: lineY, width: fullWidth * 0.62, height: lineHeight),
            xRadius: lineHeight / 2,
            yRadius: lineHeight / 2
        ).fill()

        ruleInk.setFill()
        for width in [1.0, 0.88, 1.0, 0.54] as [CGFloat] {
            lineY -= gap
            NSBezierPath(
                roundedRect: NSRect(x: lineX, y: lineY, width: fullWidth * width, height: lineHeight),
                xRadius: lineHeight / 2,
                yRadius: lineHeight / 2
            ).fill()
        }
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

// MARK: - Output

private let repoRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
private let resources = repoRoot.appendingPathComponent("Resources", isDirectory: true)
private let iconset = resources.appendingPathComponent("AppIcon.iconset", isDirectory: true)
private let icns = resources.appendingPathComponent("AppIcon.icns")

guard FileManager.default.fileExists(atPath: resources.path) else {
    FileHandle.standardError.write(Data("make-icon: run from the repository root\n".utf8))
    exit(1)
}

try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

/// Pixel size paired with every iconset name that wants it.
let variants: [(CGFloat, [String])] = [
    (16, ["icon_16x16"]),
    (32, ["icon_16x16@2x", "icon_32x32"]),
    (64, ["icon_32x32@2x"]),
    (128, ["icon_128x128"]),
    (256, ["icon_128x128@2x", "icon_256x256"]),
    (512, ["icon_256x256@2x", "icon_512x512"]),
    (1024, ["icon_512x512@2x"]),
]

for (size, names) in variants {
    let rep = drawIcon(size: size)
    guard let png = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write(Data("make-icon: could not encode \(Int(size))px\n".utf8))
        exit(1)
    }
    for name in names {
        try png.write(to: iconset.appendingPathComponent("\(name).png"))
    }
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["--convert", "icns", iconset.path, "--output", icns.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { exit(iconutil.terminationStatus) }

print("make-icon: wrote \(icns.path)")
