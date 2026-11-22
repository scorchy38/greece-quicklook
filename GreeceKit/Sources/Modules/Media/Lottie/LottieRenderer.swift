import AppKit

/// Draws one frame of a Lottie animation with Core Graphics, for Finder thumbnails (which have no
/// web view). It covers what most animations are made of: shape layers (rectangles, ellipses,
/// paths, stars), solid and gradient fills and strokes, group and layer transforms with parenting,
/// solids, precomps, embedded images, and masks and mattes as clips. Text, effects, trim paths and
/// expressions are skipped. Every walk is bounded, so hostile files can't hang a thumbnail.
final class LottieRenderer {
    private let root: [String: Any]
    private let width: Double
    private let height: Double
    private let inPoint: Double
    private let outPoint: Double
    private var assets: [String: [String: Any]] = [:]
    private var budget = 0
    private var images: [String: CGImage] = [:]

    init?(json: Data) {
        guard json.count <= LottiePreview.jsonLimit,
              let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let width = Self.number(root["w"]), let height = Self.number(root["h"]), width > 0, height > 0, width < 100_000, height < 100_000,
              let inPoint = Self.number(root["ip"]), let outPoint = Self.number(root["op"]), outPoint > inPoint,
              root["layers"] is [Any] else { return nil }
        self.root = root
        self.width = width
        self.height = height
        self.inPoint = inPoint
        self.outPoint = outPoint
        for asset in (root["assets"] as? [[String: Any]] ?? []).prefix(2000) {
            if let id = asset["id"] as? String { assets[id] = asset }
        }
    }

    // MARK: - Choosing a frame

    /// The frame that shows the most of the animation: intros and outros often start or end empty.
    func representativeFrame() -> Double? {
        var best: (frame: Double, coverage: Double)?
        for fraction in [0.5, 0.35, 0.65, 0.2, 0.8, 0.0] {
            let frame = (inPoint + (outPoint - inPoint) * fraction).rounded(.down)
            let coverage = self.coverage(at: frame)
            if coverage > (best?.coverage ?? 0) * 1.15 { best = (frame, coverage) }
        }
        guard let best, best.coverage > 0 else { return nil }
        return best.frame
    }

    private func coverage(at frame: Double) -> Double {
        let side = 40
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
        draw(frame: frame, in: CGRect(x: 0, y: 0, width: side, height: side), context: context)
        guard let data = context.data else { return 0 }
        let pixels = data.bindMemory(to: UInt8.self, capacity: side * side * 4)
        var total = 0
        for index in 0..<(side * side) { total += Int(pixels[index * 4 + 3]) }
        return Double(total) / Double(side * side * 255)
    }

    // MARK: - Drawing

    func draw(frame: Double, in rect: CGRect, context: CGContext) {
        budget = 150_000
        context.saveGState()
        context.clip(to: rect)
        // Lottie's y axis points down.
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: rect.width / width, y: -rect.height / height)
        drawLayers(root["layers"] as? [[String: Any]] ?? [], time: frame, context: context, depth: 0)
        context.restoreGState()
    }

    private func drawLayers(_ layers: [[String: Any]], time: Double, context: CGContext, depth: Int) {
        guard depth < 8 else { return }
        var byIndex: [Int: [String: Any]] = [:]
        for layer in layers.prefix(1000) { if let index = Self.number(layer["ind"]).map(Int.init) { byIndex[index] = layer } }
        // The first layer is on top: draw from the bottom up.
        let list = Array(layers.prefix(1000))
        for position in list.indices.reversed() {
            guard budget > 0 else { return }
            let layer = list[position]
            if (layer["hd"] as? Bool) == true || Self.number(layer["td"]).map({ $0 != 0 }) == true { continue }
            let start = Self.number(layer["ip"]) ?? -Double.infinity, end = Self.number(layer["op"]) ?? Double.infinity
            guard time >= start, time < end else { continue }
            let stretch = max(Self.number(layer["sr"]) ?? 1, 0.0001)
            let local = (time - (Self.number(layer["st"]) ?? 0)) / stretch

            context.saveGState()
            // A matte is the layer just above this one: approximated as a clip to its filled shapes,
            // built in composition space before this layer's own transform applies.
            if let matte = Self.number(layer["tt"]), matte > 0, position > 0 {
                let source = list[position - 1]
                var clip = CGMutablePath()
                collectFills(source, time: time - (Self.number(source["st"]) ?? 0),
                             transform: worldTransform(source, byIndex: byIndex, time: time), into: &clip)
                if !clip.isEmpty {
                    if matte == 2 || matte == 4 {
                        let outer = CGMutablePath()
                        outer.addRect(CGRect(x: -1e5, y: -1e5, width: 2e5, height: 2e5))
                        outer.addPath(clip)
                        context.addPath(outer)
                        context.clip(using: .evenOdd)
                    } else {
                        context.addPath(clip)
                        context.clip()
                    }
                }
            }
            context.concatenate(worldTransform(layer, byIndex: byIndex, time: time))
            let opacity = (value(transformProperty(layer, "o"), local)?.first ?? 100) / 100
            guard opacity > 0.001 else { context.restoreGState(); continue }
            applyMasks(layer, time: local, context: context)

            context.setAlpha(opacity)
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            switch Self.number(layer["ty"]).map(Int.init) {
            case 4:
                drawShapes(layer["shapes"] as? [[String: Any]] ?? [], time: local, context: context, transform: .identity, styles: [], opacity: 1)
            case 1:
                if let color = (layer["sc"] as? String).flatMap(Self.hexColor), let w = Self.number(layer["sw"]), let h = Self.number(layer["sh"]) {
                    context.setFillColor(color)
                    context.fill(CGRect(x: 0, y: 0, width: w, height: h))
                }
            case 0:
                if let id = layer["refId"] as? String, let nested = assets[id]?["layers"] as? [[String: Any]] {
                    var nestedTime = local
                    if let remap = layer["tm"], let seconds = value(remap, local)?.first {
                        nestedTime = seconds * (Self.number(root["fr"]) ?? 30)
                    }
                    if let w = Self.number(layer["w"]), let h = Self.number(layer["h"]) { context.clip(to: CGRect(x: 0, y: 0, width: w, height: h)) }
                    drawLayers(nested, time: nestedTime, context: context, depth: depth + 1)
                }
            case 2:
                if let id = layer["refId"] as? String, let image = image(id), let asset = assets[id] {
                    let w = Self.number(asset["w"]) ?? Double(image.width), h = Self.number(asset["h"]) ?? Double(image.height)
                    context.saveGState()
                    context.translateBy(x: 0, y: h)
                    context.scaleBy(x: 1, y: -1)
                    context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
                    context.restoreGState()
                }
            default:
                break
            }
            context.endTransparencyLayer()
            context.restoreGState()
        }
    }

    /// The layer's transform in composition space, through its chain of parents.
    private func worldTransform(_ layer: [String: Any], byIndex: [Int: [String: Any]], time: Double) -> CGAffineTransform {
        var transform = localTransform(layer, time: time)
        var current = layer
        var hops = 0
        while let parent = Self.number(current["parent"]).map(Int.init), let next = byIndex[parent], hops < 32 {
            transform = transform.concatenating(localTransform(next, time: time))
            current = next
            hops += 1
        }
        return transform
    }

    private func localTransform(_ layer: [String: Any], time: Double) -> CGAffineTransform {
        let local = (time - (Self.number(layer["st"]) ?? 0)) / max(Self.number(layer["sr"]) ?? 1, 0.0001)
        return transform(layer["ks"] as? [String: Any] ?? [:], time: local)
    }

    private func transformProperty(_ layer: [String: Any], _ key: String) -> Any? {
        (layer["ks"] as? [String: Any])?[key]
    }

    private func transform(_ properties: [String: Any], time: Double) -> CGAffineTransform {
        let anchor = value(properties["a"], time) ?? [0, 0]
        var position = value(properties["p"], time) ?? [0, 0]
        if let split = properties["p"] as? [String: Any], (split["s"] as? Bool) == true || split["x"] != nil {
            position = [value(split["x"], time)?.first ?? 0, value(split["y"], time)?.first ?? 0]
        }
        let scale = value(properties["s"], time) ?? [100, 100]
        let rotation = value(properties["r"] ?? properties["rz"], time)?.first ?? 0
        var result = CGAffineTransform(translationX: position[safe: 0] ?? 0, y: position[safe: 1] ?? 0)
        result = result.rotated(by: rotation * .pi / 180)
        result = result.scaledBy(x: (scale[safe: 0] ?? 100) / 100, y: (scale[safe: 1] ?? scale[safe: 0] ?? 100) / 100)
        result = result.translatedBy(x: -(anchor[safe: 0] ?? 0), y: -(anchor[safe: 1] ?? 0))
        // CGAffineTransform applies right to left when concatenated; Lottie's matrix is anchor, scale, rotate, position.
        return result
    }

    private func applyMasks(_ layer: [String: Any], time: Double, context: CGContext) {
        guard (layer["hasMask"] as? Bool) == true || layer["masksProperties"] != nil,
              let masks = layer["masksProperties"] as? [[String: Any]] else { return }
        let additive = CGMutablePath()
        var subtract = CGMutablePath()
        for mask in masks.prefix(32) {
            guard let shape = path(mask["pt"], time: time) else { continue }
            let inverted = (mask["inv"] as? Bool) == true
            switch mask["mode"] as? String {
            case "a", "i": if !inverted { additive.addPath(shape) } else { subtract.addPath(shape) }
            case "s": subtract.addPath(shape)
            default: break
            }
        }
        if !additive.isEmpty { context.addPath(additive); context.clip() }
        if !subtract.isEmpty {
            let outer = CGMutablePath()
            outer.addRect(CGRect(x: -1e5, y: -1e5, width: 2e5, height: 2e5))
            outer.addPath(subtract)
            subtract = outer
            context.addPath(subtract)
            context.clip(using: .evenOdd)
        }
    }

    // MARK: - Shapes

    /// A fill or stroke collecting every path drawn above it in its group and nested groups.
    private final class Style {
        let item: [String: Any]
        let opacity: Double
        let path = CGMutablePath()
        let scale: Double
        init(item: [String: Any], opacity: Double, scale: Double) { self.item = item; self.opacity = opacity; self.scale = scale }
    }

    private func drawShapes(_ items: [[String: Any]], time: Double, context: CGContext, transform: CGAffineTransform, styles: [Style], opacity: Double) {
        var active = styles
        var order: [Style] = []
        collect(items, time: time, transform: transform, active: &active, order: &order, opacity: opacity, depth: 0)
        for style in order { render(style, time: time, context: context) }
    }

    private func collect(_ items: [[String: Any]], time: Double, transform: CGAffineTransform, active: inout [Style], order: inout [Style], opacity: Double, depth: Int) {
        guard depth < 24 else { return }
        var groupTransform = transform
        var groupOpacity = opacity
        if let tr = items.first(where: { $0["ty"] as? String == "tr" }) {
            groupTransform = self.transform(tr, time: time).concatenating(transform)
            groupOpacity *= (value(tr["o"], time)?.first ?? 100) / 100
        }
        let scale = sqrt(abs(groupTransform.a * groupTransform.d - groupTransform.b * groupTransform.c))
        var local = active
        for item in items.prefix(2000).reversed() {
            budget -= 1
            guard budget > 0 else { return }
            if (item["hd"] as? Bool) == true { continue }
            switch item["ty"] as? String {
            case "fl", "st", "gf", "gs":
                let style = Style(item: item, opacity: groupOpacity, scale: scale)
                local.append(style)
                order.append(style)
            case "gr":
                var nested = local
                collect(item["it"] as? [[String: Any]] ?? [], time: time, transform: groupTransform, active: &nested, order: &order, opacity: groupOpacity, depth: depth + 1)
            case "sh", "rc", "el", "sr":
                guard let shape = geometry(item, time: time) else { continue }
                for style in local { style.path.addPath(shape, transform: groupTransform) }
            default:
                continue
            }
        }
    }

    private func render(_ style: Style, time: Double, context: CGContext) {
        guard !style.path.isEmpty else { return }
        let item = style.item
        let opacity = style.opacity * (value(item["o"], time)?.first ?? 100) / 100
        guard opacity > 0.001 else { return }
        context.saveGState()
        context.setAlpha(opacity)
        switch item["ty"] as? String {
        case "fl":
            context.addPath(style.path)
            context.setFillColor(color(value(item["c"], time)))
            context.fillPath(using: (Self.number(item["r"]) ?? 1) == 2 ? .evenOdd : .winding)
        case "st":
            stroke(style, time: time, context: context)
            context.setStrokeColor(color(value(item["c"], time)))
            context.strokePath()
        case "gf", "gs":
            guard let gradient = gradient(item, time: time) else { break }
            if item["ty"] as? String == "gs" {
                stroke(style, time: time, context: context)
                context.replacePathWithStrokedPath()
                context.clip()
            } else {
                context.addPath(style.path)
                if (Self.number(item["r"]) ?? 1) == 2 { context.clip(using: .evenOdd) } else { context.clip() }
            }
            let start = value(item["s"], time) ?? [0, 0], end = value(item["e"], time) ?? [0, 0]
            let from = CGPoint(x: start[safe: 0] ?? 0, y: start[safe: 1] ?? 0), to = CGPoint(x: end[safe: 0] ?? 0, y: end[safe: 1] ?? 0)
            if (Self.number(item["t"]) ?? 1) == 2 {
                context.drawRadialGradient(gradient, startCenter: from, startRadius: 0, endCenter: from,
                                           endRadius: hypot(to.x - from.x, to.y - from.y), options: [.drawsAfterEndLocation])
            } else {
                context.drawLinearGradient(gradient, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            }
        default:
            break
        }
        context.restoreGState()
    }

    private func stroke(_ style: Style, time: Double, context: CGContext) {
        let item = style.item
        context.addPath(style.path)
        context.setLineWidth(max((value(item["w"], time)?.first ?? 1) * style.scale, 0))
        context.setLineCap([1: .butt, 2: .round, 3: .square][Int(Self.number(item["lc"]) ?? 2)] ?? .round)
        context.setLineJoin([1: .miter, 2: .round, 3: .bevel][Int(Self.number(item["lj"]) ?? 2)] ?? .round)
        context.setMiterLimit(Self.number(item["ml"]) ?? 4)
    }

    private func gradient(_ item: [String: Any], time: Double) -> CGGradient? {
        guard let stops = item["g"] as? [String: Any], let count = Self.number(stops["p"]).map(Int.init), (1...64).contains(count),
              let values = value(stops["k"], time), values.count >= count * 4 else { return nil }
        var colors: [CGColor] = []
        var locations: [CGFloat] = []
        for index in 0..<count {
            let base = index * 4
            var alpha = 1.0
            // Opacity stops, when present, follow the colour stops as offset/alpha pairs.
            let alphaBase = count * 4 + index * 2 + 1
            if values.count > alphaBase { alpha = values[alphaBase] }
            colors.append(CGColor(srgbRed: values[base + 1], green: values[base + 2], blue: values[base + 3], alpha: alpha))
            locations.append(values[base])
        }
        return CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: locations)
    }

    /// Fill paths of a matte layer, in the matted layer's space.
    private func collectFills(_ layer: [String: Any], time: Double, transform: CGAffineTransform, into path: inout CGMutablePath) {
        guard Self.number(layer["ty"]).map(Int.init) == 4 else {
            if Self.number(layer["ty"]).map(Int.init) == 1, let w = Self.number(layer["sw"]), let h = Self.number(layer["sh"]) {
                path.addRect(CGRect(x: 0, y: 0, width: w, height: h), transform: transform)
            }
            return
        }
        var active: [Style] = []
        var order: [Style] = []
        collect(layer["shapes"] as? [[String: Any]] ?? [], time: time, transform: .identity, active: &active, order: &order, opacity: 1, depth: 0)
        for style in order where ["fl", "gf"].contains(style.item["ty"] as? String) {
            path.addPath(style.path, transform: transform)
        }
    }

    private func geometry(_ item: [String: Any], time: Double) -> CGPath? {
        switch item["ty"] as? String {
        case "sh":
            return path(item["ks"], time: time)
        case "rc":
            let center = value(item["p"], time) ?? [0, 0], size = value(item["s"], time) ?? [0, 0]
            let w = size[safe: 0] ?? 0, h = size[safe: 1] ?? 0
            guard w > 0, h > 0 else { return nil }
            let radius = min(value(item["r"], time)?.first ?? 0, min(w, h) / 2)
            let rect = CGRect(x: (center[safe: 0] ?? 0) - w / 2, y: (center[safe: 1] ?? 0) - h / 2, width: w, height: h)
            return CGPath(roundedRect: rect, cornerWidth: max(radius, 0), cornerHeight: max(radius, 0), transform: nil)
        case "el":
            let center = value(item["p"], time) ?? [0, 0], size = value(item["s"], time) ?? [0, 0]
            let w = size[safe: 0] ?? 0, h = size[safe: 1] ?? 0
            guard w > 0, h > 0 else { return nil }
            return CGPath(ellipseIn: CGRect(x: (center[safe: 0] ?? 0) - w / 2, y: (center[safe: 1] ?? 0) - h / 2, width: w, height: h), transform: nil)
        case "sr":
            let points = Int(min(max(value(item["pt"], time)?.first ?? 5, 3), 100))
            let center = value(item["p"], time) ?? [0, 0]
            let outer = value(item["or"], time)?.first ?? 0
            let inner = value(item["ir"], time)?.first ?? outer / 2
            let rotation = (value(item["r"], time)?.first ?? 0) * .pi / 180
            let isStar = (Self.number(item["sy"]) ?? 1) == 1
            let path = CGMutablePath()
            let steps = isStar ? points * 2 : points
            for step in 0..<steps {
                let radius = isStar && step % 2 == 1 ? inner : outer
                let angle = rotation - .pi / 2 + Double(step) * 2 * .pi / Double(steps)
                let point = CGPoint(x: (center[safe: 0] ?? 0) + radius * cos(angle), y: (center[safe: 1] ?? 0) + radius * sin(angle))
                if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            path.closeSubpath()
            return path
        default:
            return nil
        }
    }

    /// A Bézier path from Lottie's vertices and relative tangents.
    private func path(_ property: Any?, time: Double) -> CGPath? {
        guard let shape = shapeValue(property, time: time),
              let vertices = shape["v"] as? [[Any]], !vertices.isEmpty else { return nil }
        let inTangents = shape["i"] as? [[Any]] ?? [], outTangents = shape["o"] as? [[Any]] ?? []
        func point(_ list: [[Any]], _ index: Int) -> CGPoint {
            guard index < list.count, list[index].count >= 2, let x = Self.number(list[index][0]), let y = Self.number(list[index][1]) else { return .zero }
            // Absurd coordinates are pinned well outside any frame rather than handed to Core Graphics.
            return CGPoint(x: min(max(x, -1e6), 1e6), y: min(max(y, -1e6), 1e6))
        }
        let path = CGMutablePath()
        let count = min(vertices.count, 10_000)
        budget -= count
        path.move(to: point(vertices, 0))
        let closed = (shape["c"] as? Bool) == true
        for index in 1..<(closed ? count + 1 : count) where count > 1 || closed {
            let from = (index - 1) % count, to = index % count
            let a = point(vertices, from), b = point(vertices, to)
            let c1 = point(outTangents, from), c2 = point(inTangents, to)
            path.addCurve(to: b, control1: CGPoint(x: a.x + c1.x, y: a.y + c1.y), control2: CGPoint(x: b.x + c2.x, y: b.y + c2.y))
        }
        if closed { path.closeSubpath() }
        return path
    }

    private func shapeValue(_ property: Any?, time: Double) -> [String: Any]? {
        guard let property = property as? [String: Any] else { return nil }
        if let shape = property["k"] as? [String: Any] { return shape }
        guard let frames = property["k"] as? [[String: Any]], !frames.isEmpty else { return nil }
        var chosen = frames[0]
        for frame in frames where (Self.number(frame["t"]) ?? 0) <= time { chosen = frame }
        if let start = chosen["s"] as? [[String: Any]], let shape = start.first { return shape }
        if let start = chosen["s"] as? [String: Any] { return start }
        if let end = chosen["e"] as? [[String: Any]], let shape = end.first { return shape }
        return nil
    }

    // MARK: - Animated values

    /// A property's value at `time`: static, or interpolated between keyframes with their easing.
    private func value(_ property: Any?, _ time: Double) -> [Double]? {
        guard let property = property as? [String: Any] else { return nil }
        let raw = property["k"]
        if let single = Self.number(raw) { return [single] }
        if let array = raw as? [Any], !(array.first is [String: Any]) { return array.compactMap(Self.number) }
        guard let frames = raw as? [[String: Any]], !frames.isEmpty else { return nil }
        func values(_ any: Any?) -> [Double]? {
            if let number = Self.number(any) { return [number] }
            return (any as? [Any])?.compactMap(Self.number)
        }
        var index = 0
        while index + 1 < frames.count, (Self.number(frames[index + 1]["t"]) ?? .infinity) <= time { index += 1 }
        let current = frames[index]
        guard let start = values(current["s"]) ?? values(frames[max(index - 1, 0)]["e"]) else { return nil }
        let t0 = Self.number(current["t"]) ?? 0
        guard time > t0, index + 1 < frames.count, (Self.number(current["h"]) ?? 0) == 0 else { return start }
        let next = frames[index + 1]
        guard let end = values(current["e"]) ?? values(next["s"]), end.count == start.count else { return start }
        let t1 = Self.number(next["t"]) ?? t0
        guard t1 > t0 else { return end }
        let linear = min(max((time - t0) / (t1 - t0), 0), 1)
        let eased = ease(linear, out: current["o"] as? [String: Any], in: current["i"] as? [String: Any])
        return zip(start, end).map { $0 + ($1 - $0) * eased }
    }

    /// Cubic-bezier easing from the keyframe's out and in tangents (the first dimension's).
    private func ease(_ progress: Double, out: [String: Any]?, in incoming: [String: Any]?) -> Double {
        func first(_ any: Any?) -> Double? { Self.number(any) ?? (any as? [Any])?.first.flatMap(Self.number) }
        guard let x1 = first(out?["x"]), let y1 = first(out?["y"]), let x2 = first(incoming?["x"]), let y2 = first(incoming?["y"]) else { return progress }
        func bezier(_ t: Double, _ p1: Double, _ p2: Double) -> Double {
            let u = 1 - t
            return 3 * u * u * t * p1 + 3 * u * t * t * p2 + t * t * t
        }
        var low = 0.0, high = 1.0, t = progress
        for _ in 0..<24 {
            t = (low + high) / 2
            if bezier(t, x1, x2) < progress { low = t } else { high = t }
        }
        return bezier(t, y1, y2)
    }

    // MARK: - Colours and images

    private func color(_ components: [Double]?) -> CGColor {
        guard var c = components, c.count >= 3 else { return CGColor(gray: 0, alpha: 1) }
        // Very old files use 0–255.
        if c.prefix(3).contains(where: { $0 > 1 }) { c = c.map { $0 / 255 } }
        return CGColor(srgbRed: c[0], green: c[1], blue: c[2], alpha: c.count > 3 ? min(max(c[3], 0), 1) : 1)
    }

    private static func hexColor(_ hex: String) -> CGColor? {
        var value = hex.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let number = UInt32(value, radix: 16) else { return nil }
        return CGColor(srgbRed: CGFloat(number >> 16 & 0xFF) / 255, green: CGFloat(number >> 8 & 0xFF) / 255, blue: CGFloat(number & 0xFF) / 255, alpha: 1)
    }

    /// Embedded (data URL) images only: a thumbnail never reads other files.
    private func image(_ id: String) -> CGImage? {
        if let cached = images[id] { return cached }
        guard let path = assets[id]?["p"] as? String, path.hasPrefix("data:image/"), path.count < 24 * 1024 * 1024,
              let comma = path.firstIndex(of: ","), path[..<comma].hasSuffix(";base64"),
              let data = Data(base64Encoded: String(path[path.index(after: comma)...])),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return nil }
        images[id] = image
        return image
    }

    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        return double.isFinite ? double : nil
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
