// Renders the background of the DNS Pulse installer window: a title, an arrow from the app to the Applications
// folder, and a hint for the first launch.
// Usage: swift scripts/render_dmg_background.swift <output-folder>
//
// Writes dmg-background.png (640 × 380) and dmg-background@2x.png. The layout matches scripts/dmg_settings.py:
// the app's icon is centred at (160, 185) and Applications at (480, 185), measured from the top left. Everything
// important sits in the top 280 points, because Finder's tab bar and path bar, when someone has them switched on,
// take space from the bottom of the window.
//
// Finder draws the icon names in black in light mode and white in dark mode, so the colours stay in the middle
// of the range, where both are readable.

import AppKit
import CoreGraphics
import Foundation

let width: CGFloat = 640
let height: CGFloat = 380
let outputFolder = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".")
try? FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

/// Draws one line of text centred on `centerX`, with its baseline `baseline` points from the top.
func drawText(_ text: String, size: CGFloat, weight: NSFont.Weight, alpha: CGFloat, centerX: CGFloat, baseline: CGFloat, in context: CGContext) {
    let font = NSFont.systemFont(ofSize: size, weight: weight)
    let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(cgColor: color(0xFFFFFF, alpha))!]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -1), blur: 3, color: color(0x15173A, 0.45))
    context.textPosition = CGPoint(x: centerX - bounds.width / 2 - bounds.minX, y: height - baseline)
    CTLineDraw(line, context)
    context.restoreGState()
}

func render(scale: CGFloat, name: String) {
    let context = CGContext(
        data: nil, width: Int(width * scale), height: Int(height * scale), bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setShouldAntialias(true)
    context.interpolationQuality = .high
    context.scaleBy(x: scale, y: scale)

    // Background: a muted indigo, slightly lighter at the top.
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [color(0x7F85B9), color(0x6A6FA4)] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: height), end: CGPoint(x: 0, y: 0), options: [])
    let glow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [color(0xFFFFFF, 0.10), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    context.drawRadialGradient(glow, startCenter: CGPoint(x: width / 2, y: height - 185), startRadius: 0,
                               endCenter: CGPoint(x: width / 2, y: height - 185), endRadius: 300, options: [])

    drawText("Drag DNS Pulse into Applications", size: 21, weight: .semibold, alpha: 1, centerX: width / 2, baseline: 54, in: context)
    drawText("If macOS blocks the first launch: System Settings › Privacy & Security › Open Anyway", size: 11.5, weight: .medium,
             alpha: 0.9, centerX: width / 2, baseline: 78, in: context)

    // Arrow from the app to Applications, level with the icons' centres.
    let y = height - 185
    let start: CGFloat = 252, tip: CGFloat = 388
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -1), blur: 4, color: color(0x15173A, 0.35))
    context.setStrokeColor(color(0xFFFFFF, 0.95))
    context.setLineWidth(6)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.move(to: CGPoint(x: start, y: y))
    context.addLine(to: CGPoint(x: tip - 4, y: y))
    context.move(to: CGPoint(x: tip - 22, y: y + 18))
    context.addLine(to: CGPoint(x: tip, y: y))
    context.addLine(to: CGPoint(x: tip - 22, y: y - 18))
    context.strokePath()
    context.restoreGState()

    drawText("github.com/zivkogodzirov/DNSPulse", size: 11, weight: .regular, alpha: 0.7, centerX: width / 2, baseline: 352, in: context)

    let rep = NSBitmapImageRep(cgImage: context.makeImage()!)
    rep.size = NSSize(width: width, height: height)
    try! rep.representation(using: .png, properties: [:])!.write(to: outputFolder.appendingPathComponent(name))
    print("wrote \(name)")
}

render(scale: 1, name: "dmg-background.png")
render(scale: 2, name: "dmg-background@2x.png")
