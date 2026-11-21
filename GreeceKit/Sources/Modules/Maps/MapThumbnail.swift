import AppKit
import ImageIO

/// The bundled Natural Earth basemap (see Fixtures/maps/scripts/build_basemap.py for the format).
enum Basemap {
    struct Feature {
        let rank: UInt8
        let parts: [[GeoPoint]]
        let bounds: GeoBounds
    }
    struct Layer {
        let name: String
        let kind: UInt8
        let features: [Feature]
    }

    static let layers: [String: Layer] = {
        guard let url = WebAssets.url("modules/maps-basemap.bin"), let data = try? Data(contentsOf: url) else { return [:] }
        return decode(data)
    }()

    static func decode(_ data: Data) -> [String: Layer] {
        let b = [UInt8](data)
        guard b.count > 6, b.starts(with: Array("GRBM".utf8)), b[4] == 1 else { return [:] }
        var pos = 6
        func varint() -> Int? {
            var result = 0, shift = 0
            while pos < b.count, shift < 63 {
                let byte = b[pos]
                pos += 1
                result |= Int(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return result }
                shift += 7
            }
            return nil
        }
        func zigzag() -> Int? { varint().map { ($0 >> 1) ^ -($0 & 1) } }
        var layers: [String: Layer] = [:]
        for _ in 0..<Int(b[5]) {
            guard pos < b.count else { break }
            let nameLength = Int(b[pos]); pos += 1
            guard pos + nameLength + 1 <= b.count else { break }
            let name = String(decoding: b[pos..<(pos + nameLength)], as: UTF8.self)
            pos += nameLength
            let kind = b[pos]; pos += 1
            guard let count = varint(), count < 1_000_000 else { break }
            var features: [Feature] = []
            features.reserveCapacity(count)
            for _ in 0..<count {
                guard pos < b.count else { break }
                let rank = b[pos]; pos += 1
                if kind == 3 {
                    guard let length = varint(), pos + length <= b.count else { break }
                    pos += length
                    guard let x = zigzag(), let y = zigzag() else { break }
                    let p = GeoPoint(Double(x) / 1000, Double(y) / 1000)
                    var bounds = GeoBounds(); bounds.extend(p)
                    features.append(Feature(rank: rank, parts: [[p]], bounds: bounds))
                    continue
                }
                guard let partCount = varint(), partCount < 100_000 else { break }
                var x = 0, y = 0
                var parts: [[GeoPoint]] = []
                var bounds = GeoBounds()
                for _ in 0..<partCount {
                    guard let n = varint(), n < 1_000_000 else { break }
                    var part: [GeoPoint] = []
                    part.reserveCapacity(n)
                    for _ in 0..<n {
                        guard let dx = zigzag(), let dy = zigzag() else { break }
                        x += dx; y += dy
                        let p = GeoPoint(Double(x) / 1000, Double(y) / 1000)
                        part.append(p)
                        bounds.extend(p)
                    }
                    parts.append(part)
                }
                features.append(Feature(rank: rank, parts: parts, bounds: bounds))
            }
            layers[name] = Layer(name: name, kind: kind, features: features)
        }
        return layers
    }
}

/// Finder thumbnails: the data drawn natively over the basemap, framed to its extent.
enum MapThumbnail {

    /// Normalised Web Mercator (0…1, y down).
    static func mercator(_ p: GeoPoint) -> CGPoint {
        let lat = max(-85.0511, min(85.0511, p.y))
        let s = sin(lat * .pi / 180)
        return CGPoint(x: (p.x + 180) / 360, y: 0.5 - log((1 + s) / (1 - s)) / (4 * .pi))
    }

    struct Palette {
        static let water = NSColor(srgbRed: 0.808, green: 0.886, blue: 0.957, alpha: 1)
        static let land = NSColor(srgbRed: 0.965, green: 0.953, blue: 0.929, alpha: 1)
        static let border = NSColor(srgbRed: 0.74, green: 0.70, blue: 0.66, alpha: 1)
        static let blank = NSColor(srgbRed: 0.965, green: 0.965, blue: 0.97, alpha: 1)
        static let accent = NSColor(srgbRed: 0.0, green: 0.478, blue: 1.0, alpha: 1)
        static let layerColors: [NSColor] = [
            NSColor(srgbRed: 0.0, green: 0.478, blue: 1.0, alpha: 1), NSColor(srgbRed: 1.0, green: 0.584, blue: 0.0, alpha: 1),
            NSColor(srgbRed: 1.0, green: 0.176, blue: 0.333, alpha: 1), NSColor(srgbRed: 0.204, green: 0.78, blue: 0.349, alpha: 1),
            NSColor(srgbRed: 0.686, green: 0.322, blue: 0.871, alpha: 1), NSColor(srgbRed: 0.188, green: 0.69, blue: 0.78, alpha: 1),
            NSColor(srgbRed: 0.345, green: 0.337, blue: 0.839, alpha: 1), NSColor(srgbRed: 0.635, green: 0.518, blue: 0.369, alpha: 1),
        ]
    }

    static func page(_ document: MapDocument, maximumSize: CGSize) -> ThumbnailPage? {
        var extent = document.bounds
        if extent.isEmpty, let b = document.tileSets.first?.info.bounds {
            extent = GeoBounds(minX: b[0], minY: b[1], maxX: b[2], maxY: b[3])
        }
        if extent.isEmpty, !document.tileSets.isEmpty { extent = GeoBounds(minX: -180, minY: -70, maxX: 180, maxY: 80) }
        guard !extent.isEmpty else { return nil }

        // Frame in mercator space with breathing room and a sensible minimum extent.
        let a = mercator(GeoPoint(extent.minX, extent.maxY)), b = mercator(GeoPoint(extent.maxX, extent.minY))
        var frame = CGRect(x: a.x, y: a.y, width: max(b.x - a.x, 0), height: max(b.y - a.y, 0))
        let minimum: CGFloat = document.tileSets.isEmpty ? 1.0 / 4096 : 1.0 / 2048
        if frame.width < minimum { frame = frame.insetBy(dx: -(minimum - frame.width) / 2, dy: 0) }
        if frame.height < minimum { frame = frame.insetBy(dx: 0, dy: -(minimum - frame.height) / 2) }
        frame = frame.insetBy(dx: -frame.width * 0.09, dy: -frame.height * 0.09)
        let aspect = min(max(frame.width / frame.height, 0.78), 1.45)
        if frame.width / frame.height < aspect {
            frame = frame.insetBy(dx: -(frame.height * aspect - frame.width) / 2, dy: 0)
        } else {
            frame = frame.insetBy(dx: 0, dy: -(frame.width / aspect - frame.height) / 2)
        }
        if frame.width > 1 { frame = CGRect(x: 0, y: frame.midY - 0.5 / aspect, width: 1, height: 1 / aspect) }

        var size = CGSize(width: maximumSize.width, height: maximumSize.width / aspect)
        if size.height > maximumSize.height { size = CGSize(width: maximumSize.height * aspect, height: maximumSize.height) }
        size = CGSize(width: max(16, size.width.rounded()), height: max(16, size.height.rounded()))

        // Raster tiles are decoded before drawing, outside the drawing closure.
        let tiles = rasterTiles(document, frame: frame, pixelWidth: size.width * 2)
        let vector = vectorTiles(document, frame: frame, pixelWidth: size.width)

        return ThumbnailPage(size: size, badge: document.format.badge) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return }
            draw(document, in: context, rect: rect, frame: frame, tiles: tiles, vector: vector)
        }
    }

    // MARK: Drawing

    private static func draw(_ document: MapDocument, in context: CGContext, rect: CGRect, frame: CGRect,
                             tiles: [(CGRect, CGImage)], vector: [(CGRect, VectorTile)]) {
        let scale = rect.width / frame.width
        let unit = max(rect.width / 256, 0.5)
        func project(_ p: GeoPoint) -> CGPoint {
            let m = mercator(p)
            return CGPoint(x: rect.minX + (m.x - frame.minX) * scale, y: rect.maxY - (m.y - frame.minY) * scale)
        }
        func path(_ parts: [[GeoPoint]], close: Bool) -> CGPath {
            let path = CGMutablePath()
            for part in parts where part.count > 1 {
                // Skip vertices closer than a third of a pixel: big files stay quick to draw.
                var last = project(part[0])
                path.move(to: last)
                for p in part.dropFirst() {
                    let q = project(p)
                    if abs(q.x - last.x) + abs(q.y - last.y) > 0.33 { path.addLine(to: q); last = q }
                }
                if close { path.closeSubpath() }
            }
            return path
        }
        let view = GeoBounds(minX: frame.minX * 360 - 180, minY: -90, maxX: frame.maxX * 360 - 180, maxY: 90)
        func visible(_ b: GeoBounds) -> Bool { !(b.maxX < view.minX || b.minX > view.maxX) }

        context.saveGState()
        context.setLineJoin(.round)
        context.setLineCap(.round)

        if document.isPlanar {
            context.setFillColor(Palette.blank.cgColor)
            context.fill(rect)
            grid(context, rect: rect, step: rect.width / 8, color: NSColor(white: 0, alpha: 0.05))
        } else {
            context.setFillColor(Palette.water.cgColor)
            context.fill(rect)
            if tiles.isEmpty {
                if let land = Basemap.layers["land"] {
                    let p = CGMutablePath()
                    for f in land.features where visible(f.bounds) { p.addPath(path(f.parts, close: true)) }
                    context.addPath(p)
                    context.setFillColor(Palette.land.cgColor)
                    context.fillPath(using: .evenOdd)
                }
                if let lakes = Basemap.layers["lakes"] {
                    let p = CGMutablePath()
                    for f in lakes.features where visible(f.bounds) && Double(f.rank) / 10 <= 4 + log2(1 / frame.width) { p.addPath(path(f.parts, close: true)) }
                    context.addPath(p)
                    context.setFillColor(Palette.water.cgColor)
                    context.fillPath(using: .evenOdd)
                }
                if let borders = Basemap.layers["borders"] {
                    let p = CGMutablePath()
                    for f in borders.features where visible(f.bounds) { p.addPath(path(f.parts, close: false)) }
                    context.addPath(p)
                    context.setStrokeColor(Palette.border.withAlphaComponent(0.7).cgColor)
                    context.setLineWidth(0.5 * unit)
                    context.strokePath()
                }
            }
            for (target, image) in tiles {
                context.interpolationQuality = .high
                context.draw(image, in: CGRect(x: rect.minX + (target.minX - frame.minX) * scale,
                                               y: rect.maxY - (target.maxY - frame.minY) * scale,
                                               width: target.width * scale, height: target.height * scale))
            }
            graticule(context, rect: rect, frame: frame, project: project)
        }

        drawVectorTiles(vector, context: context, rect: rect, frame: frame, unit: unit)

        // Data: areas, then lines, then points, then track ends on top.
        let total = document.stats.features
        let pointRadius: CGFloat = (total > 2000 ? 1.4 : total > 300 ? 2.2 : 3.2) * unit
        for pass in 0..<3 {
            for (layerIndex, layer) in document.layers.enumerated() where !layer.isHidden {
                let base = Palette.layerColors[layerIndex % Palette.layerColors.count]
                for feature in layer.features {
                    guard let g = feature.geometry else { continue }
                    drawGeometry(g, feature.style, layer.role, base, pass: pass, context: context, unit: unit,
                                 pointRadius: pointRadius, path: path, project: project)
                }
            }
        }
        for track in document.tracks {
            guard let first = track.samples.first, let last = track.samples.last,
                  let x0 = first[3], let y0 = first[4], let x1 = last[3], let y1 = last[4] else { continue }
            marker(context, project(GeoPoint(x0, y0)), color: NSColor(srgbRed: 0.204, green: 0.78, blue: 0.349, alpha: 1), unit: unit)
            marker(context, project(GeoPoint(x1, y1)), color: NSColor(srgbRed: 1, green: 0.231, blue: 0.188, alpha: 1), unit: unit)
        }
        context.restoreGState()
    }

    private static func drawGeometry(_ g: GeoGeometry, _ style: GeoStyle?, _ role: LayerRole, _ base: NSColor, pass: Int,
                                     context: CGContext, unit: CGFloat, pointRadius: CGFloat,
                                     path: ([[GeoPoint]], Bool) -> CGPath, project: (GeoPoint) -> CGPoint) {
        func color(_ hex: String?) -> NSColor? { hex.map { NSColor(hex: $0) } }
        switch g {
        case .polygon(let rings) where pass == 0:
            fillAndStroke(path(rings, true), style, role, base, context: context, unit: unit)
        case .multiPolygon(let polygons) where pass == 0:
            let p = CGMutablePath()
            for rings in polygons { p.addPath(path(rings, true)) }
            fillAndStroke(p, style, role, base, context: context, unit: unit)
        case .lineString(let line) where pass == 1:
            strokeLine(path([line], false), style, role, base, context: context, unit: unit)
        case .multiLineString(let lines) where pass == 1:
            strokeLine(path(lines, false), style, role, base, context: context, unit: unit)
        case .point(let p) where pass == 2:
            dot(context, project(p), radius: pointRadius, color: color(style?.markerColor) ?? base, unit: unit)
        case .multiPoint(let points) where pass == 2:
            for p in points { dot(context, project(p), radius: pointRadius, color: color(style?.markerColor) ?? base, unit: unit) }
        case .collection(let parts):
            for part in parts { drawGeometry(part, style, role, base, pass: pass, context: context, unit: unit, pointRadius: pointRadius, path: path, project: project) }
        default:
            break
        }
    }

    private static func fillAndStroke(_ path: CGPath, _ style: GeoStyle?, _ role: LayerRole, _ base: NSColor, context: CGContext, unit: CGFloat) {
        let fill = style?.fill.map { NSColor(hex: $0) } ?? base
        let fillOpacity = style?.fillOpacity ?? (role == .area ? 1 : 0.22)
        context.addPath(path)
        context.setFillColor(fill.withAlphaComponent(CGFloat(fillOpacity)).cgColor)
        context.fillPath(using: .evenOdd)
        let strokeOpacity = style?.strokeOpacity ?? 1
        guard strokeOpacity > 0 else { return }
        context.addPath(path)
        context.setStrokeColor((style?.stroke.map { NSColor(hex: $0) } ?? base).withAlphaComponent(CGFloat(strokeOpacity) * 0.9).cgColor)
        context.setLineWidth(CGFloat(min(style?.strokeWidth ?? 1.2, 3)) * 0.6 * unit)
        context.strokePath()
    }

    private static func strokeLine(_ path: CGPath, _ style: GeoStyle?, _ role: LayerRole, _ base: NSColor, context: CGContext, unit: CGFloat) {
        let color = (style?.stroke.map { NSColor(hex: $0) } ?? base).withAlphaComponent(CGFloat(style?.strokeOpacity ?? 1))
        let width = CGFloat(style?.strokeWidth ?? (role == .track ? 3 : 1.8)) * (role == .track ? 0.9 : 0.7) * unit
        if role == .track || role == .road {
            context.addPath(path)
            context.setStrokeColor(role == .road ? NSColor(white: 0.78, alpha: 1).cgColor : NSColor.white.cgColor)
            context.setLineWidth(width + (role == .road ? 0.8 : 2) * unit)
            context.strokePath()
        }
        context.addPath(path)
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(max(width, 0.6 * unit))
        context.strokePath()
    }

    private static func dot(_ context: CGContext, _ p: CGPoint, radius: CGFloat, color: NSColor, unit: CGFloat) {
        let r = CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2)
        if radius > 2 * unit {
            context.setFillColor(NSColor.white.cgColor)
            context.fillEllipse(in: r.insetBy(dx: -0.9 * unit, dy: -0.9 * unit))
        }
        context.setFillColor(color.cgColor)
        context.fillEllipse(in: r)
    }

    private static func marker(_ context: CGContext, _ p: CGPoint, color: NSColor, unit: CGFloat) {
        let r = 3.6 * unit
        context.setFillColor(NSColor.white.cgColor)
        context.fillEllipse(in: CGRect(x: p.x - r - 1.2 * unit, y: p.y - r - 1.2 * unit, width: 2 * (r + 1.2 * unit), height: 2 * (r + 1.2 * unit)))
        context.setFillColor(color.cgColor)
        context.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
    }

    /// Meridians and parallels at a round interval, very faint.
    private static func graticule(_ context: CGContext, rect: CGRect, frame: CGRect, project: (GeoPoint) -> CGPoint) {
        let spanDegrees = frame.width * 360
        let steps: [Double] = [0.01, 0.02, 0.05, 0.1, 0.2, 0.5, 1, 2, 5, 10, 15, 30]
        let step = steps.first { spanDegrees / $0 <= 7 } ?? 30
        let west = frame.minX * 360 - 180, east = frame.maxX * 360 - 180
        func lat(_ y: CGFloat) -> Double { atan(sinh(.pi * (1 - 2 * Double(y)))) * 180 / .pi }
        let north = lat(frame.minY), south = lat(frame.maxY)
        let p = CGMutablePath()
        var x = (west / step).rounded(.up) * step
        while x <= east { p.move(to: project(GeoPoint(x, south))); p.addLine(to: project(GeoPoint(x, north))); x += step }
        var y = (south / step).rounded(.up) * step
        while y <= north { p.move(to: project(GeoPoint(west, y))); p.addLine(to: project(GeoPoint(east, y))); y += step }
        context.addPath(p)
        context.setStrokeColor(NSColor(srgbRed: 0.35, green: 0.45, blue: 0.6, alpha: 0.13).cgColor)
        context.setLineWidth(max(rect.width / 512, 0.5))
        context.strokePath()
    }

    private static func grid(_ context: CGContext, rect: CGRect, step: CGFloat, color: NSColor) {
        let p = CGMutablePath()
        var x = rect.minX
        while x <= rect.maxX { p.move(to: CGPoint(x: x, y: rect.minY)); p.addLine(to: CGPoint(x: x, y: rect.maxY)); x += step }
        var y = rect.minY
        while y <= rect.maxY { p.move(to: CGPoint(x: rect.minX, y: y)); p.addLine(to: CGPoint(x: rect.maxX, y: y)); y += step }
        context.addPath(p)
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(max(rect.width / 512, 0.5))
        context.strokePath()
    }

    // MARK: Tiles

    private static func tileRange(_ set: TileSet, frame: CGRect, pixelWidth: CGFloat, maxAcross: Int) -> (z: Int, xs: ClosedRange<Int>, ys: ClosedRange<Int>)? {
        var z = Int((log2(pixelWidth / (frame.width * CGFloat(set.info.tileSize)))).rounded())
        z = max(set.info.minzoom, min(set.info.maxzoom, z))
        while z > set.info.minzoom, CGFloat(1 << z) * frame.width > CGFloat(maxAcross) { z -= 1 }
        let n = CGFloat(1 << z)
        let x0 = max(0, Int(floor(frame.minX * n))), x1 = min(Int(n) - 1, Int(floor(frame.maxX * n)))
        let y0 = max(0, Int(floor(frame.minY * n))), y1 = min(Int(n) - 1, Int(floor(frame.maxY * n)))
        guard x0 <= x1, y0 <= y1, (x1 - x0 + 1) * (y1 - y0 + 1) <= maxAcross * maxAcross + maxAcross else { return nil }
        return (z, x0...x1, y0...y1)
    }

    private static func rasterTiles(_ document: MapDocument, frame: CGRect, pixelWidth: CGFloat) -> [(CGRect, CGImage)] {
        guard let set = document.tileSets.first(where: { $0.info.kind == .raster }),
              let range = tileRange(set, frame: frame, pixelWidth: pixelWidth, maxAcross: 4) else { return [] }
        var result: [(CGRect, CGImage)] = []
        let n = CGFloat(1 << range.z)
        for y in range.ys { for x in range.xs {
            guard let data = set.fetch(range.z, x, y), let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { continue }
            result.append((CGRect(x: CGFloat(x) / n, y: CGFloat(y) / n, width: 1 / n, height: 1 / n), image))
        } }
        return result
    }

    private static func vectorTiles(_ document: MapDocument, frame: CGRect, pixelWidth: CGFloat) -> [(CGRect, VectorTile)] {
        guard let set = document.tileSets.first(where: { $0.info.kind == .vector }),
              let range = tileRange(set, frame: frame, pixelWidth: pixelWidth, maxAcross: 3) else { return [] }
        var result: [(CGRect, VectorTile)] = []
        let n = CGFloat(1 << range.z)
        for y in range.ys { for x in range.xs {
            guard let data = set.fetch(range.z, x, y), let tile = VectorTile.decode(data, maxFeatures: 40_000, withProperties: false) else { continue }
            result.append((CGRect(x: CGFloat(x) / n, y: CGFloat(y) / n, width: 1 / n, height: 1 / n), tile))
        } }
        return result
    }

    private static func drawVectorTiles(_ tiles: [(CGRect, VectorTile)], context: CGContext, rect: CGRect, frame: CGRect, unit: CGFloat) {
        guard !tiles.isEmpty else { return }
        let scale = rect.width / frame.width
        var names: [String] = []
        for (_, tile) in tiles { for layer in tile.layers where !names.contains(layer.name) { names.append(layer.name) } }
        for type in [3, 2, 1] {
            for (target, tile) in tiles {
                context.saveGState()
                let clip = CGRect(x: rect.minX + (target.minX - frame.minX) * scale, y: rect.maxY - (target.maxY - frame.minY) * scale,
                                  width: target.width * scale, height: target.height * scale)
                context.clip(to: clip)
                for layer in tile.layers {
                    let color = Palette.layerColors[(names.firstIndex(of: layer.name) ?? 0) % Palette.layerColors.count]
                    let k = target.width * scale / CGFloat(layer.extent)
                    let p = CGMutablePath()
                    for feature in layer.features where feature.type == type {
                        for part in feature.parts {
                            guard let first = part.first else { continue }
                            if type == 1 {
                                let c = CGPoint(x: clip.minX + CGFloat(first.0) * k, y: clip.maxY - CGFloat(first.1) * k)
                                p.addEllipse(in: CGRect(x: c.x - 1.6 * unit, y: c.y - 1.6 * unit, width: 3.2 * unit, height: 3.2 * unit))
                                continue
                            }
                            p.move(to: CGPoint(x: clip.minX + CGFloat(first.0) * k, y: clip.maxY - CGFloat(first.1) * k))
                            for v in part.dropFirst() { p.addLine(to: CGPoint(x: clip.minX + CGFloat(v.0) * k, y: clip.maxY - CGFloat(v.1) * k)) }
                        }
                    }
                    context.addPath(p)
                    switch type {
                    case 3:
                        context.setFillColor(color.withAlphaComponent(0.2).cgColor)
                        context.fillPath(using: .evenOdd)
                        context.addPath(p)
                        context.setStrokeColor(color.withAlphaComponent(0.8).cgColor)
                        context.setLineWidth(0.6 * unit)
                        context.strokePath()
                    case 2:
                        context.setStrokeColor(color.cgColor)
                        context.setLineWidth(1.1 * unit)
                        context.strokePath()
                    default:
                        context.setFillColor(color.cgColor)
                        context.fillPath()
                    }
                }
                context.restoreGState()
            }
        }
    }
}
