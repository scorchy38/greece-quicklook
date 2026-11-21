// Renders Greece's app icon: an Aegean squircle, a page of code, and a glass loupe.
//   swift scripts/make-icon.swift <output-1024.png>
import AppKit
import CoreGraphics

let size: CGFloat = 1024
let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func gradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: locations)!
}

/// Apple's continuous-corner squircle, approximated with a superellipse.
func squircle(_ rect: CGRect, exponent: CGFloat = 5) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2
    let cx = rect.midX, cy = rect.midY
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let ct = cos(t), st = sin(t)
        let x = cx + a * (ct < 0 ? -1 : 1) * pow(abs(ct), 2 / exponent)
        let y = cy + b * (st < 0 ? -1 : 1) * pow(abs(st), 2 / exponent)
        i == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
    }
    path.closeSubpath()
    return path
}

let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.setShouldAntialias(true)
ctx.interpolationQuality = .high

// MARK: Tile

let tileRect = CGRect(x: 100, y: 100, width: 824, height: 824)
let tile = squircle(tileRect)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.28))
ctx.addPath(tile)
ctx.setFillColor(color(0x0B4FA8))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(tile)
ctx.clip()
// Sea: light at the horizon, deep below.
ctx.drawLinearGradient(gradient([color(0x5EC2FF), color(0x1F7AE8), color(0x0A3F9C)], [0, 0.48, 1]),
                       start: CGPoint(x: 300, y: 924), end: CGPoint(x: 724, y: 100),
                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
// Soft sun glow, top left.
ctx.drawRadialGradient(gradient([color(0xFFFFFF, 0.38), color(0xFFFFFF, 0)], [0, 1]),
                       startCenter: CGPoint(x: 260, y: 860), startRadius: 0,
                       endCenter: CGPoint(x: 260, y: 860), endRadius: 520, options: [])
// Gentle wave bands near the bottom.
for (index, offset) in [CGFloat(250), 190, 130].enumerated() {
    let wave = CGMutablePath()
    wave.move(to: CGPoint(x: 80, y: offset))
    for x in stride(from: CGFloat(80), through: 944, by: 8) {
        wave.addLine(to: CGPoint(x: x, y: offset + 14 * sin((x / 120) + CGFloat(index) * 1.3)))
    }
    wave.addLine(to: CGPoint(x: 944, y: 60))
    wave.addLine(to: CGPoint(x: 80, y: 60))
    wave.closeSubpath()
    ctx.addPath(wave)
    ctx.setFillColor(color(0x062E78, 0.22 + CGFloat(index) * 0.08))
    ctx.fillPath()
}
ctx.restoreGState()

// Hairline highlight on the tile edge.
ctx.saveGState()
ctx.addPath(tile)
ctx.setStrokeColor(color(0xFFFFFF, 0.25))
ctx.setLineWidth(3)
ctx.strokePath()
ctx.restoreGState()

// MARK: Page of code

let pageRect = CGRect(x: 0, y: 0, width: 420, height: 540)
let pageTransform = CGAffineTransform(translationX: 455, y: 545).rotated(by: -0.07).translatedBy(x: -210, y: -270)

let syntax: [[(UInt32, CGFloat)]] = [
    [(0xA626A4, 70), (0x0B4F79, 110), (0x9AA3AE, 30)],
    [(0x9AA3AE, 200)],
    [],
    [(0xA626A4, 54), (0x326D74, 96), (0xC41A16, 120)],
    [(0x0B4F79, 80), (0x1C00CF, 40), (0x9AA3AE, 60)],
    [(0xA626A4, 70), (0xC41A16, 150)],
    [(0x326D74, 120), (0x1C00CF, 50)],
    [],
    [(0xA626A4, 60), (0x0B4F79, 140)],
    [(0x9AA3AE, 90), (0xC41A16, 100)],
]
let indents: [CGFloat] = [0, 0, 0, 36, 72, 72, 36, 0, 0, 36]

func drawPage(_ ctx: CGContext) {
    let page = CGPath(roundedRect: pageRect, cornerWidth: 34, cornerHeight: 34, transform: nil)
    ctx.addPath(page)
    ctx.setFillColor(color(0xFFFFFF))
    ctx.fillPath()
    // Folded corner tint.
    ctx.saveGState()
    ctx.addPath(page)
    ctx.clip()
    ctx.drawLinearGradient(gradient([color(0xF4F7FB), color(0xFFFFFF)], [0, 1]),
                           start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: 540), options: [])
    ctx.restoreGState()
    for (row, tokens) in syntax.enumerated() {
        var x: CGFloat = 52 + indents[row]
        let y: CGFloat = 470 - CGFloat(row) * 42
        for (hex, width) in tokens {
            let capsule = CGPath(roundedRect: CGRect(x: x, y: y, width: width, height: 18), cornerWidth: 9, cornerHeight: 9, transform: nil)
            ctx.addPath(capsule)
            ctx.setFillColor(color(hex, 0.92))
            ctx.fillPath()
            x += width + 14
        }
    }
}

ctx.saveGState()
ctx.concatenate(pageTransform)
ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 40, color: color(0x021A4A, 0.45))
ctx.addPath(CGPath(roundedRect: pageRect, cornerWidth: 34, cornerHeight: 34, transform: nil))
ctx.setFillColor(color(0xFFFFFF))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.concatenate(pageTransform)
drawPage(ctx)
ctx.restoreGState()

// MARK: Loupe

let lensCenter = CGPoint(x: 662, y: 382)
let lensRadius: CGFloat = 172
/// The point on the page the loupe is looking at: the densest run of code.
let focus = CGPoint(x: 205, y: 330).applying(pageTransform)
let lens = CGPath(ellipseIn: CGRect(x: lensCenter.x - lensRadius, y: lensCenter.y - lensRadius,
                                    width: lensRadius * 2, height: lensRadius * 2), transform: nil)

// Shadow under the glass.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -16), blur: 36, color: color(0x021A4A, 0.5))
ctx.addPath(lens)
ctx.setFillColor(color(0xEAF4FF))
ctx.fillPath()
ctx.restoreGState()

// Magnified page inside the glass.
ctx.saveGState()
ctx.addPath(lens)
ctx.clip()
ctx.setFillColor(color(0xF2F8FF))
ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
let magnification: CGFloat = 1.8
ctx.translateBy(x: lensCenter.x, y: lensCenter.y)
ctx.scaleBy(x: magnification, y: magnification)
ctx.translateBy(x: -focus.x, y: -focus.y)
ctx.concatenate(pageTransform)
drawPage(ctx)
ctx.restoreGState()

// Glass tint and inner vignette.
ctx.saveGState()
ctx.addPath(lens)
ctx.clip()
ctx.drawRadialGradient(gradient([color(0x7CC4FF, 0.0), color(0x2D7FE0, 0.22)], [0.55, 1]),
                       startCenter: lensCenter, startRadius: 0, endCenter: lensCenter, endRadius: lensRadius, options: [])
// Specular highlight.
let shine = CGMutablePath()
shine.addArc(center: lensCenter, radius: lensRadius - 30, startAngle: .pi * 0.58, endAngle: .pi * 0.98, clockwise: false)
ctx.addPath(shine)
ctx.setLineCap(.round)
ctx.setLineWidth(16)
ctx.setStrokeColor(color(0xFFFFFF, 0.75))
ctx.strokePath()
ctx.restoreGState()

// Rim.
ctx.saveGState()
ctx.addPath(lens)
ctx.setLineWidth(30)
ctx.replacePathWithStrokedPath()
ctx.clip()
ctx.drawLinearGradient(gradient([color(0xFFFFFF), color(0xD5E4F5), color(0x9DB6D3)], [0, 0.5, 1]),
                       start: CGPoint(x: lensCenter.x - lensRadius, y: lensCenter.y + lensRadius),
                       end: CGPoint(x: lensCenter.x + lensRadius, y: lensCenter.y - lensRadius), options: [])
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(CGPath(ellipseIn: CGRect(x: lensCenter.x - lensRadius - 15, y: lensCenter.y - lensRadius - 15,
                                     width: (lensRadius + 15) * 2, height: (lensRadius + 15) * 2), transform: nil))
ctx.setStrokeColor(color(0x0A3F9C, 0.35))
ctx.setLineWidth(2)
ctx.strokePath()
ctx.restoreGState()

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
print("wrote \(output)")
