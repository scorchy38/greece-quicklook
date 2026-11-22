// Draws the images the archive fixtures use: package icons and the pages of a short comic.
// Everything is generated (SF Symbols and Core Graphics), so there's nothing to license.
//   swift Fixtures/archives/make-images.swift <out dir>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(_ size: NSSize, scale: CGFloat = 1, _ draw: (CGRect) -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(CGRect(origin: .zero, size: size))
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func symbol(_ name: String, size: CGFloat, color: NSColor, in rect: CGRect) {
    guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: size, weight: .semibold)) else { return }
    let tinted = NSImage(size: image.size, flipped: false) { bounds in
        image.draw(in: bounds)
        color.set()
        bounds.fill(using: .sourceAtop)
        return true
    }
    let s = tinted.size
    tinted.draw(in: CGRect(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2, width: s.width, height: s.height))
}

func save(_ rep: NSBitmapImageRep, _ name: String, jpeg: Bool = false) {
    let data = jpeg ? rep.representation(using: .jpeg, properties: [.compressionFactor: 0.6])! : rep.representation(using: .png, properties: [:])!
    try! data.write(to: out.appendingPathComponent(name))
}

// MARK: - Icons

let icons: [(String, String, NSColor, NSColor)] = [
    ("icon-sailboat.png", "sailboat.fill", NSColor(srgbRed: 0.18, green: 0.55, blue: 0.95, alpha: 1), NSColor(srgbRed: 0.05, green: 0.3, blue: 0.75, alpha: 1)),
    ("icon-sun.png", "sun.horizon.fill", NSColor(srgbRed: 1.0, green: 0.62, blue: 0.2, alpha: 1), NSColor(srgbRed: 0.93, green: 0.33, blue: 0.2, alpha: 1)),
    ("icon-ferry.png", "ferry.fill", NSColor(srgbRed: 0.2, green: 0.78, blue: 0.75, alpha: 1), NSColor(srgbRed: 0.05, green: 0.5, blue: 0.6, alpha: 1)),
    ("icon-waves.png", "water.waves", NSColor(srgbRed: 0.45, green: 0.42, blue: 0.95, alpha: 1), NSColor(srgbRed: 0.25, green: 0.2, blue: 0.7, alpha: 1)),
]
for (name, glyph, top, bottom) in icons {
    save(render(NSSize(width: 128, height: 128)) { rect in
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: 4, dy: 4), xRadius: 28, yRadius: 28)
        NSGradient(starting: top, ending: bottom)?.draw(in: path, angle: -90)
        symbol(glyph, size: 56, color: .white, in: rect)
    }, name)
}

// MARK: - Comic pages

let ink = NSColor(srgbRed: 0.1, green: 0.1, blue: 0.14, alpha: 1)
let paper = NSColor(srgbRed: 0.99, green: 0.97, blue: 0.92, alpha: 1)
let palettes: [(NSColor, NSColor)] = [
    (NSColor(srgbRed: 0.98, green: 0.78, blue: 0.45, alpha: 1), NSColor(srgbRed: 0.35, green: 0.62, blue: 0.9, alpha: 1)),
    (NSColor(srgbRed: 0.55, green: 0.8, blue: 0.98, alpha: 1), NSColor(srgbRed: 0.1, green: 0.35, blue: 0.65, alpha: 1)),
    (NSColor(srgbRed: 0.98, green: 0.6, blue: 0.5, alpha: 1), NSColor(srgbRed: 0.45, green: 0.25, blue: 0.55, alpha: 1)),
    (NSColor(srgbRed: 0.2, green: 0.2, blue: 0.4, alpha: 1), NSColor(srgbRed: 0.05, green: 0.08, blue: 0.2, alpha: 1)),
]
let art = ["sailboat.fill", "sun.max.fill", "fish.fill", "moon.stars.fill", "bird.fill", "cloud.sun.fill", "tortoise.fill", "wind", "ferry.fill", "building.columns.fill"]
let lines = ["The wind turned at dawn.", "“Naxos by noon,” said the captain.", "Dolphins kept pace with the bow.",
             "Night fell over the Cyclades.", "A gull stole the bread.", "Calm seas, at last.", "The old harbour slept.", "Home."]

func panel(_ rect: CGRect, index: Int) {
    let (sky, sea) = palettes[index % palettes.count]
    NSGradient(starting: sky, ending: sky.blended(withFraction: 0.35, of: .white)!)?.draw(in: rect, angle: 90)
    let horizon = rect.minY + rect.height * 0.38
    NSGradient(starting: sea, ending: sea.blended(withFraction: 0.3, of: .black)!)?.draw(in: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: horizon - rect.minY), angle: -90)
    symbol(art[index % art.count], size: min(rect.width, rect.height) * 0.32, color: ink.withAlphaComponent(0.85), in: rect.offsetBy(dx: 0, dy: rect.height * 0.08))
    // Caption box.
    let caption = lines[index % lines.count]
    let attributes: [NSAttributedString.Key: Any] = [.font: NSFont(name: "Chalkboard SE Bold", size: 22) ?? NSFont.boldSystemFont(ofSize: 22), .foregroundColor: ink]
    let text = NSAttributedString(string: caption, attributes: attributes)
    let box = CGRect(x: rect.minX + 14, y: rect.maxY - 54, width: min(rect.width - 28, text.size().width + 24), height: 40)
    paper.setFill()
    box.fill()
    ink.setStroke()
    let border = NSBezierPath(rect: box)
    border.lineWidth = 3
    border.stroke()
    text.draw(at: CGPoint(x: box.minX + 12, y: box.minY + 8))
    let frame = NSBezierPath(rect: rect)
    frame.lineWidth = 6
    frame.stroke()
}

let pageSize = NSSize(width: 800, height: 1200)
// Cover.
save(render(pageSize, scale: 0.65) { rect in
    NSGradient(colors: [NSColor(srgbRed: 0.98, green: 0.55, blue: 0.3, alpha: 1), NSColor(srgbRed: 0.85, green: 0.25, blue: 0.35, alpha: 1),
                        NSColor(srgbRed: 0.2, green: 0.2, blue: 0.5, alpha: 1)])?.draw(in: rect, angle: -90)
    symbol("sun.max.fill", size: 260, color: NSColor(srgbRed: 1, green: 0.88, blue: 0.5, alpha: 1), in: rect.offsetBy(dx: 0, dy: 120))
    NSColor(srgbRed: 0.08, green: 0.2, blue: 0.42, alpha: 1).setFill()
    CGRect(x: 0, y: 0, width: rect.width, height: 380).fill()
    symbol("sailboat.fill", size: 220, color: paper, in: CGRect(x: 0, y: 330, width: rect.width, height: 260))
    let title = NSAttributedString(string: "AEGEAN\nTALES", attributes: [
        .font: NSFont(name: "Futura-CondensedExtraBold", size: 150) ?? NSFont.systemFont(ofSize: 150, weight: .black),
        .foregroundColor: paper, .strokeColor: ink, .strokeWidth: -3,
    ])
    title.draw(in: CGRect(x: 48, y: 760, width: 720, height: 420))
    let issue = NSAttributedString(string: "No. 1  ·  The Crossing", attributes: [.font: NSFont.systemFont(ofSize: 34, weight: .heavy), .foregroundColor: paper])
    issue.draw(at: CGPoint(x: 52, y: 60))
}, "page-01.jpg", jpeg: true)

for page in 2...8 {
    save(render(pageSize, scale: 0.65) { rect in
        paper.setFill()
        rect.fill()
        let margin: CGFloat = 36, gap: CGFloat = 22
        let inner = rect.insetBy(dx: margin, dy: margin)
        let rows: [[CGFloat]] = page % 2 == 0 ? [[1], [0.5, 0.5], [1]] : [[0.6, 0.4], [1], [0.4, 0.6]]
        let rowHeight = (inner.height - gap * CGFloat(rows.count - 1)) / CGFloat(rows.count)
        var index = page * 3
        for (r, row) in rows.enumerated() {
            var x = inner.minX
            let y = inner.maxY - CGFloat(r + 1) * rowHeight - CGFloat(r) * gap
            for fraction in row {
                let width = (inner.width - gap * CGFloat(row.count - 1)) * fraction
                panel(CGRect(x: x, y: y, width: width, height: rowHeight), index: index)
                x += width + gap
                index += 1
            }
        }
        let number = NSAttributedString(string: "\(page)", attributes: [.font: NSFont.systemFont(ofSize: 18, weight: .semibold), .foregroundColor: ink.withAlphaComponent(0.6)])
        number.draw(at: CGPoint(x: rect.midX - 6, y: 8))
    }, String(format: "page-%02d.jpg", page), jpeg: true)
}
print("ok")
