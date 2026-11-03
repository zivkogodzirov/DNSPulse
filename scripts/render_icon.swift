// Renders the DNS Pulse app icon artwork.
// Usage: swift scripts/render_icon.swift <output-folder>
//
// Writes:
//   icon-1024.png         classic macOS icon (rounded square with shadow) used for AppIcon.icns
//   layer-background.png  \
//   layer-gauge.png        |
//   layer-needle.png       |  full-bleed transparent layers for the Icon Composer (.icon) version
//   layer-globe.png        |
//   layer-label.png       /

import AppKit
import CoreGraphics
import Foundation

let canvas = 1024
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

func makeContext() -> CGContext {
    let context = CGContext(
        data: nil, width: canvas, height: canvas, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setShouldAntialias(true)
    context.interpolationQuality = .high
    return context
}

func save(_ context: CGContext, _ name: String) {
    let image = context.makeImage()!
    let rep = NSBitmapImageRep(cgImage: image)
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: outputFolder.appendingPathComponent(name))
    print("wrote \(name)")
}

/// Apple's icon shape is close to a superellipse.
func squircle(_ rect: CGRect, exponent n: Double = 5) -> CGPath {
    let path = CGMutablePath()
    let a = Double(rect.width) / 2, b = Double(rect.height) / 2
    let cx = Double(rect.midX), cy = Double(rect.midY)
    let steps = 720
    for i in 0..<steps {
        let t = Double(i) / Double(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = cx + a * copysign(pow(abs(c), 2 / n), c)
        let y = cy + b * copysign(pow(abs(s), 2 / n), s)
        if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}

/// Maps unit coordinates (0…1, origin bottom-left) into the artwork rectangle.
struct Space {
    let rect: CGRect
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height) }
    func s(_ v: CGFloat) -> CGFloat { v * rect.width }
}

// Geometry shared by every layer.
let center: (CGFloat, CGFloat) = (0.5, 0.485)
let arcRadius: CGFloat = 0.345
let arcWidth: CGFloat = 0.074
let startAngle: CGFloat = 215
let endAngle: CGFloat = -35
let needleAngle: CGFloat = 40
let globeRadius: CGFloat = 0.122

func radians(_ degrees: CGFloat) -> CGFloat { degrees * .pi / 180 }

func lerp(_ a: CGColor, _ b: CGColor, _ t: CGFloat) -> CGColor {
    let ca = a.components!, cb = b.components!
    return CGColor(srgbRed: ca[0] + (cb[0] - ca[0]) * t, green: ca[1] + (cb[1] - ca[1]) * t, blue: ca[2] + (cb[2] - ca[2]) * t, alpha: ca[3] + (cb[3] - ca[3]) * t)
}

func arcColor(_ t: CGFloat) -> CGColor {
    let stops = [color(0x22D3EE), color(0x34D399), color(0xA3E635)]
    let scaled = t * CGFloat(stops.count - 1)
    let index = min(Int(scaled), stops.count - 2)
    return lerp(stops[index], stops[index + 1], scaled - CGFloat(index))
}

func drawBackground(_ ctx: CGContext, _ space: Space) {
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [color(0x2F86FF), color(0x4B5CFA), color(0x6D35E8)] as CFArray, locations: [0, 0.5, 1])!
    ctx.drawLinearGradient(gradient, start: space.p(0.1, 1.0), end: space.p(0.9, 0.0), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    let glow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [color(0xFFFFFF, 0.28), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: space.p(0.3, 0.95), startRadius: 0, endCenter: space.p(0.3, 0.95), endRadius: space.s(0.75), options: [])
    let shade = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [color(0x1A0B5C, 0), color(0x1A0B5C, 0.35)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(shade, start: space.p(0.5, 0.45), end: space.p(0.5, 0.0), options: [])
}

func drawGauge(_ ctx: CGContext, _ space: Space) {
    let c = space.p(center.0, center.1)
    let r = space.s(arcRadius)
    let w = space.s(arcWidth)

    // Unlit track.
    ctx.saveGState()
    ctx.setLineCap(.round)
    ctx.setLineWidth(w)
    ctx.setStrokeColor(color(0xFFFFFF, 0.2))
    ctx.addArc(center: c, radius: r, startAngle: radians(needleAngle), endAngle: radians(endAngle), clockwise: true)
    ctx.strokePath()
    ctx.restoreGState()

    // Lit part, drawn as many short segments to fake a conic gradient, with a soft glow.
    let sweep = startAngle - needleAngle
    let segments = 240
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: space.s(0.045), color: color(0x5EF0C8, 0.75))
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    for i in 0..<segments {
        let t0 = CGFloat(i) / CGFloat(segments)
        let t1 = CGFloat(i + 1) / CGFloat(segments)
        ctx.setStrokeColor(arcColor(t0))
        ctx.setLineWidth(w)
        ctx.setLineCap(i == 0 || i == segments - 1 ? .round : .butt)
        ctx.addArc(center: c, radius: r, startAngle: radians(startAngle - sweep * t0), endAngle: radians(startAngle - sweep * min(1, t1 + 0.002)), clockwise: true)
        ctx.strokePath()
    }
    ctx.endTransparencyLayer()
    ctx.restoreGState()

    // Ticks inside the arc.
    let tickCount = 11
    ctx.saveGState()
    ctx.setLineCap(.round)
    for i in 0..<tickCount {
        let t = CGFloat(i) / CGFloat(tickCount - 1)
        let angle = radians(startAngle - (startAngle - endAngle) * t)
        let major = i % 2 == 0
        let outer = r - w / 2 - space.s(0.03)
        let inner = outer - space.s(major ? 0.05 : 0.03)
        ctx.setLineWidth(space.s(major ? 0.014 : 0.01))
        ctx.setStrokeColor(color(0xFFFFFF, major ? 0.55 : 0.35))
        ctx.move(to: CGPoint(x: c.x + cos(angle) * inner, y: c.y + sin(angle) * inner))
        ctx.addLine(to: CGPoint(x: c.x + cos(angle) * outer, y: c.y + sin(angle) * outer))
        ctx.strokePath()
    }
    ctx.restoreGState()
}

func drawNeedle(_ ctx: CGContext, _ space: Space) {
    let c = space.p(center.0, center.1)
    let angle = radians(needleAngle)
    let length = space.s(0.285)
    let base = space.s(0.03)
    let tip = space.s(0.008)
    let dir = CGPoint(x: cos(angle), y: sin(angle))
    let normal = CGPoint(x: -dir.y, y: dir.x)
    let end = CGPoint(x: c.x + dir.x * length, y: c.y + dir.y * length)

    let path = CGMutablePath()
    path.move(to: CGPoint(x: c.x + normal.x * base, y: c.y + normal.y * base))
    path.addLine(to: CGPoint(x: end.x + normal.x * tip, y: end.y + normal.y * tip))
    path.addArc(center: end, radius: tip, startAngle: angle + .pi / 2, endAngle: angle - .pi / 2, clockwise: true)
    path.addLine(to: CGPoint(x: c.x - normal.x * base, y: c.y - normal.y * base))
    path.closeSubpath()

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -space.s(0.01)), blur: space.s(0.03), color: color(0x10083A, 0.45))
    ctx.addPath(path)
    ctx.setFillColor(color(0xFFFFFF))
    ctx.fillPath()
    ctx.restoreGState()
}

func drawGlobe(_ ctx: CGContext, _ space: Space) {
    let c = space.p(center.0, center.1)
    let r = space.s(globeRadius)
    let circle = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -space.s(0.012)), blur: space.s(0.035), color: color(0x10083A, 0.5))
    ctx.setFillColor(color(0xFFFFFF))
    ctx.fillEllipse(in: circle)
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addEllipse(in: circle)
    ctx.clip()
    let fill = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [color(0xFFFFFF), color(0xDCE5FF)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(fill, start: CGPoint(x: c.x, y: c.y + r), end: CGPoint(x: c.x, y: c.y - r), options: [])

    let line = space.s(0.0135)
    ctx.setStrokeColor(color(0x4357F0))
    ctx.setLineWidth(line)
    ctx.setLineCap(.round)
    // Meridians.
    ctx.strokeEllipse(in: CGRect(x: c.x - r * 0.46, y: c.y - r, width: r * 0.92, height: r * 2))
    ctx.move(to: CGPoint(x: c.x, y: c.y - r)); ctx.addLine(to: CGPoint(x: c.x, y: c.y + r)); ctx.strokePath()
    // Parallels.
    for offset in [-0.5, 0.0, 0.5] as [CGFloat] {
        let y = c.y + r * offset
        let half = sqrt(max(0, r * r - (r * offset) * (r * offset)))
        ctx.move(to: CGPoint(x: c.x - half, y: y)); ctx.addLine(to: CGPoint(x: c.x + half, y: y)); ctx.strokePath()
    }
    ctx.restoreGState()

    ctx.setStrokeColor(color(0x4357F0))
    ctx.setLineWidth(line)
    ctx.strokeEllipse(in: circle.insetBy(dx: line / 2, dy: line / 2))
}

func drawLabel(_ ctx: CGContext, _ space: Space) {
    let size = space.s(0.145)
    let base = NSFont.systemFont(ofSize: size, weight: .heavy)
    let font = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? base
    let text = NSAttributedString(string: "DNS", attributes: [
        .font: font,
        .foregroundColor: NSColor.white.withAlphaComponent(0.96),
        .kern: size * 0.06,
    ])
    let bounds = text.size()
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -space.s(0.006)), blur: space.s(0.02), color: color(0x10083A, 0.35))
    let origin = space.p(0.5, 0.105)
    text.draw(at: CGPoint(x: origin.x - bounds.width / 2 + size * 0.03, y: origin.y))
    ctx.restoreGState()
    NSGraphicsContext.restoreGraphicsState()
}

// Classic icon: 824 pt body inside a 1024 canvas, per Apple's macOS template.
do {
    let ctx = makeContext()
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = squircle(body)
    let space = Space(rect: body)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.32))
    ctx.addPath(shape)
    ctx.setFillColor(color(0x4B5CFA))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    drawBackground(ctx, space)
    drawGauge(ctx, space)
    drawNeedle(ctx, space)
    drawGlobe(ctx, space)
    drawLabel(ctx, space)
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.setStrokeColor(color(0xFFFFFF, 0.18))
    ctx.setLineWidth(3)
    ctx.strokePath()
    ctx.restoreGState()

    save(ctx, "icon-1024.png")
}

// Separate full-bleed layers for Icon Composer, so macOS can add its glass effects.
let fullBleed = Space(rect: CGRect(x: 0, y: 0, width: canvas, height: canvas))
for (name, draw) in [("layer-background.png", drawBackground), ("layer-gauge.png", drawGauge), ("layer-needle.png", drawNeedle), ("layer-globe.png", drawGlobe), ("layer-label.png", drawLabel)] as [(String, (CGContext, Space) -> Void)] {
    let ctx = makeContext()
    draw(ctx, fullBleed)
    save(ctx, name)
}
