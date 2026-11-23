import AppKit

/// Draws a compiled VectorDrawable (`<vector>` with groups, paths and clip paths), enough for
/// launcher icons that ship no bitmaps. Gradients fall back to a neutral fill.
enum AndroidVector {
    private static let maxPaths = 2_000
    private static let maxDepth = 16

    static func render(_ vector: AndroidXMLElement, side: CGFloat, color: (AndroidValue?) -> NSColor?) -> NSImage? {
        let width = number(vector.attribute("viewportWidth")) ?? 24
        let height = number(vector.attribute("viewportHeight")) ?? 24
        guard width > 0, height > 0, width < 100_000, height < 100_000, side >= 1, side <= 1_024 else { return nil }
        // Drawn now, at 2x, so the image holds no reference to the package and is safe on any thread.
        return AndroidIcon.bitmap(side: side) { context, pixels in
            context.translateBy(x: 0, y: pixels)
            context.scaleBy(x: 1, y: -1)   // VectorDrawables are y-down
            context.scaleBy(x: pixels / width, y: pixels / height)
            var budget = maxPaths
            draw(vector, in: context, depth: 0, budget: &budget, color: color)
        }
    }

    private static func draw(_ group: AndroidXMLElement, in context: CGContext, depth: Int, budget: inout Int,
                             color: (AndroidValue?) -> NSColor?) {
        guard depth < maxDepth else { return }
        context.saveGState()
        defer { context.restoreGState() }
        for child in group.children {
            guard budget > 0 else { return }
            switch child.name {
            case "group":
                context.saveGState()
                let pivotX = number(child.attribute("pivotX")) ?? 0, pivotY = number(child.attribute("pivotY")) ?? 0
                context.translateBy(x: (number(child.attribute("translateX")) ?? 0) + pivotX,
                                    y: (number(child.attribute("translateY")) ?? 0) + pivotY)
                context.rotate(by: (number(child.attribute("rotation")) ?? 0) * .pi / 180)
                context.scaleBy(x: number(child.attribute("scaleX")) ?? 1, y: number(child.attribute("scaleY")) ?? 1)
                context.translateBy(x: -pivotX, y: -pivotY)
                draw(child, in: context, depth: depth + 1, budget: &budget, color: color)
                context.restoreGState()
            case "clip-path":
                budget -= 1
                if let data = child.string("pathData"), let path = SVGPath.parse(data) {
                    context.addPath(path)
                    context.clip()
                }
            case "path":
                budget -= 1
                guard let data = child.string("pathData"), let path = SVGPath.parse(data) else { continue }
                let evenOdd = child.attribute("fillType")?.int == 1 || child.string("fillType") == "evenOdd"
                if let fillValue = child.attribute("fillColor") {
                    let alpha = number(child.attribute("fillAlpha")) ?? 1
                    let fill = color(fillValue) ?? (fillValue == .null ? nil : NSColor(white: 0.55, alpha: 1))
                    if let fill {
                        context.setFillColor(fill.withAlphaComponent(fill.alphaComponent * alpha).cgColor)
                        context.addPath(path)
                        context.fillPath(using: evenOdd ? .evenOdd : .winding)
                    }
                }
                if let strokeValue = child.attribute("strokeColor"), let stroke = color(strokeValue) {
                    let lineWidth = number(child.attribute("strokeWidth")) ?? 0
                    if lineWidth > 0 {
                        let alpha = number(child.attribute("strokeAlpha")) ?? 1
                        context.setStrokeColor(stroke.withAlphaComponent(stroke.alphaComponent * alpha).cgColor)
                        context.setLineWidth(lineWidth)
                        context.addPath(path)
                        context.strokePath()
                    }
                }
            default:
                continue
            }
        }
    }

    private static func number(_ value: AndroidValue?) -> CGFloat? {
        switch value {
        case .float(let number)?: return number.isFinite ? CGFloat(number) : nil
        case .int(let number)?: return CGFloat(number)
        case .string(let text)?, .other(let text)?:
            let digits = text.prefix { "0123456789.-+eE".contains($0) }
            return Double(digits).map { CGFloat($0) }
        default: return nil
        }
    }
}

/// SVG path data (the `pathData` syntax VectorDrawables share), including arcs.
enum SVGPath {
    static let maxCommands = 100_000

    static func parse(_ text: String) -> CGPath? {
        let bytes = Array(text.utf8.prefix(1 << 20))
        var index = 0
        let path = CGMutablePath()
        var current = CGPoint.zero, start = CGPoint.zero
        var lastControl: CGPoint?, lastQuad: CGPoint?
        var command: UInt8 = 0
        var commands = 0

        func skipSeparators() {
            while index < bytes.count, bytes[index] == 0x20 || bytes[index] == 0x2C || bytes[index] == 0x0A
                    || bytes[index] == 0x0D || bytes[index] == 0x09 { index += 1 }
        }
        func number() -> CGFloat? {
            skipSeparators()
            let begin = index
            if index < bytes.count, bytes[index] == 0x2D || bytes[index] == 0x2B { index += 1 }
            var sawDot = false, sawDigit = false
            while index < bytes.count {
                let byte = bytes[index]
                if byte >= 0x30 && byte <= 0x39 { sawDigit = true; index += 1 }
                else if byte == 0x2E && !sawDot { sawDot = true; index += 1 }
                else if (byte == 0x65 || byte == 0x45) && sawDigit {
                    index += 1
                    if index < bytes.count, bytes[index] == 0x2D || bytes[index] == 0x2B { index += 1 }
                } else { break }
            }
            guard sawDigit, let value = Double(String(decoding: bytes[begin..<index], as: UTF8.self)), value.isFinite else {
                index = begin
                return nil
            }
            return CGFloat(value)
        }
        func flag() -> Bool? {
            skipSeparators()
            guard index < bytes.count, bytes[index] == 0x30 || bytes[index] == 0x31 else { return nil }
            defer { index += 1 }
            return bytes[index] == 0x31
        }

        while true {
            skipSeparators()
            guard index < bytes.count else { break }
            commands += 1
            if commands > maxCommands { break }
            let byte = bytes[index]
            if (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A) {
                command = byte
                index += 1
            } else if command == 0 {
                return path.isEmpty ? nil : path
            }
            let relative = command >= 0x61
            let base = relative ? current : .zero
            switch command | 0x20 {
            case 0x6D: // m
                guard let x = number(), let y = number() else { return path.isEmpty ? nil : path }
                current = CGPoint(x: base.x + x, y: base.y + y)
                start = current
                path.move(to: current)
                command = relative ? 0x6C : 0x4C   // further pairs are line-tos
                lastControl = nil; lastQuad = nil
            case 0x6C: // l
                guard let x = number(), let y = number() else { return path.isEmpty ? nil : path }
                current = CGPoint(x: base.x + x, y: base.y + y)
                if path.isEmpty { path.move(to: current) } else { path.addLine(to: current) }
                lastControl = nil; lastQuad = nil
            case 0x68: // h
                guard let x = number() else { return path.isEmpty ? nil : path }
                current = CGPoint(x: (relative ? current.x : 0) + x, y: current.y)
                path.addLine(to: current)
                lastControl = nil; lastQuad = nil
            case 0x76: // v
                guard let y = number() else { return path.isEmpty ? nil : path }
                current = CGPoint(x: current.x, y: (relative ? current.y : 0) + y)
                path.addLine(to: current)
                lastControl = nil; lastQuad = nil
            case 0x63: // c
                guard let x1 = number(), let y1 = number(), let x2 = number(), let y2 = number(),
                      let x = number(), let y = number() else { return path.isEmpty ? nil : path }
                let c1 = CGPoint(x: base.x + x1, y: base.y + y1), c2 = CGPoint(x: base.x + x2, y: base.y + y2)
                current = CGPoint(x: base.x + x, y: base.y + y)
                path.addCurve(to: current, control1: c1, control2: c2)
                lastControl = c2; lastQuad = nil
            case 0x73: // s
                guard let x2 = number(), let y2 = number(), let x = number(), let y = number() else { return path.isEmpty ? nil : path }
                let c1 = lastControl.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                let c2 = CGPoint(x: base.x + x2, y: base.y + y2)
                current = CGPoint(x: base.x + x, y: base.y + y)
                path.addCurve(to: current, control1: c1, control2: c2)
                lastControl = c2; lastQuad = nil
            case 0x71: // q
                guard let x1 = number(), let y1 = number(), let x = number(), let y = number() else { return path.isEmpty ? nil : path }
                let control = CGPoint(x: base.x + x1, y: base.y + y1)
                current = CGPoint(x: base.x + x, y: base.y + y)
                path.addQuadCurve(to: current, control: control)
                lastQuad = control; lastControl = nil
            case 0x74: // t
                guard let x = number(), let y = number() else { return path.isEmpty ? nil : path }
                let control = lastQuad.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                current = CGPoint(x: base.x + x, y: base.y + y)
                path.addQuadCurve(to: current, control: control)
                lastQuad = control; lastControl = nil
            case 0x61: // a
                guard let rx = number(), let ry = number(), let rotation = number(), let large = flag(), let sweep = flag(),
                      let x = number(), let y = number() else { return path.isEmpty ? nil : path }
                let end = CGPoint(x: base.x + x, y: base.y + y)
                arc(path, from: current, to: end, rx: abs(rx), ry: abs(ry), rotation: rotation, large: large, sweep: sweep)
                current = end
                lastControl = nil; lastQuad = nil
            case 0x7A: // z
                path.closeSubpath()
                current = start
                lastControl = nil; lastQuad = nil
                command = 0   // "z" takes no arguments: a number after it is malformed
            default:
                return path.isEmpty ? nil : path
            }
        }
        return path.isEmpty ? nil : path
    }

    /// SVG endpoint arc to cubic Béziers (SVG 1.1, appendix F.6).
    private static func arc(_ path: CGMutablePath, from p0: CGPoint, to p1: CGPoint, rx: CGFloat, ry: CGFloat,
                            rotation: CGFloat, large: Bool, sweep: Bool) {
        guard rx > 0, ry > 0, p0 != p1 else { path.addLine(to: p1); return }
        let phi = rotation * .pi / 180
        let cosPhi = cos(phi), sinPhi = sin(phi)
        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let x1 = cosPhi * dx + sinPhi * dy, y1 = -sinPhi * dx + cosPhi * dy
        var rx = rx, ry = ry
        let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if lambda > 1 { rx *= sqrt(lambda); ry *= sqrt(lambda) }
        let numerator = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
        let denominator = rx * rx * y1 * y1 + ry * ry * x1 * x1
        var factor = denominator == 0 ? 0 : sqrt(max(0, numerator / denominator))
        if large == sweep { factor = -factor }
        let cx1 = factor * rx * y1 / ry, cy1 = -factor * ry * x1 / rx
        let cx = cosPhi * cx1 - sinPhi * cy1 + (p0.x + p1.x) / 2
        let cy = sinPhi * cx1 + cosPhi * cy1 + (p0.y + p1.y) / 2
        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let sign: CGFloat = ux * vy - uy * vx < 0 ? -1 : 1
            let dot = (ux * vx + uy * vy) / max(sqrt(ux * ux + uy * uy) * sqrt(vx * vx + vy * vy), .leastNonzeroMagnitude)
            return sign * acos(min(1, max(-1, dot)))
        }
        let theta1 = angle(1, 0, (x1 - cx1) / rx, (y1 - cy1) / ry)
        var delta = angle((x1 - cx1) / rx, (y1 - cy1) / ry, (-x1 - cx1) / rx, (-y1 - cy1) / ry)
        if !sweep && delta > 0 { delta -= 2 * .pi } else if sweep && delta < 0 { delta += 2 * .pi }
        let segments = max(1, min(16, Int(ceil(abs(delta) / (.pi / 2)))))
        let step = delta / CGFloat(segments)
        let k = 4.0 / 3.0 * tan(step / 4)
        var theta = theta1
        for _ in 0..<segments {
            let cos1 = cos(theta), sin1 = sin(theta), cos2 = cos(theta + step), sin2 = sin(theta + step)
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: cx + rx * x * cosPhi - ry * y * sinPhi, y: cy + rx * x * sinPhi + ry * y * cosPhi)
            }
            path.addCurve(to: point(cos2, sin2), control1: point(cos1 - k * sin1, sin1 + k * cos1),
                          control2: point(cos2 + k * sin2, sin2 - k * cos2))
            theta += step
        }
    }
}
