import AppKit

/// Finds and draws an Android app's launcher icon: the best raster, or an adaptive icon's layers
/// (raster, colour or vector) composited and masked the way launchers show them.
enum AndroidIcon {
    static let outputSide: CGFloat = 192
    private static let maxImageBytes = 8 << 20

    static func image(manifest: AndroidXMLElement, resources: AndroidResourceTable?, zip: ZIPArchive, prefix: String,
                      deadline: Date) -> NSImage? {
        guard let application = manifest.children(named: "application").first else { return nil }
        var candidates: [AndroidValue] = []
        if let icon = application.attribute("icon") { candidates.append(icon) }
        if let round = application.attribute("roundIcon") { candidates.append(round) }
        // Some apps only set the icon on their launcher activity.
        for activity in application.children where activity.name == "activity" || activity.name == "activity-alias" {
            if let icon = activity.attribute("icon") { candidates.append(icon) }
            if candidates.count > 6 { break }
        }
        let context = Context(resources: resources, zip: zip, prefix: prefix, deadline: deadline)
        for candidate in candidates {
            guard Date() < deadline else { break }
            switch candidate {
            case .reference(let id):
                if let image = context.icon(for: id) { return image }
            case .string(let path):
                if let image = context.raster(path) { return image }
            default:
                continue
            }
        }
        // Last resort: the conventional launcher file names.
        for density in ["xxxhdpi", "xxhdpi", "xhdpi", "hdpi", "mdpi"] {
            for name in ["ic_launcher.png", "ic_launcher.webp", "ic_launcher_round.png", "ic_launcher_round.webp"] {
                for qualifier in ["", "-v4"] {
                    if let image = context.raster("res/mipmap-\(density)\(qualifier)/\(name)") { return image }
                }
            }
        }
        return nil
    }

    struct Context {
        let resources: AndroidResourceTable?
        let zip: ZIPArchive
        let prefix: String
        let deadline: Date

        func data(_ path: String) -> Data? {
            guard !path.isEmpty, path.count < 1_024 else { return nil }
            return zip.contents(of: prefix + path, limit: maxImageBytes) ?? zip.contents(of: path, limit: maxImageBytes)
        }

        func raster(_ path: String, maximumPixels: CGFloat = outputSide) -> NSImage? {
            let lower = path.lowercased()
            guard lower.hasSuffix(".png") || lower.hasSuffix(".webp") || lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg"),
                  !lower.hasSuffix(".9.png"), let data = data(path) else { return nil }
            return AndroidIcon.decode(data, maximumPixels: maximumPixels)
        }

        /// Resolves a mipmap/drawable: prefer the sharpest raster; otherwise draw the adaptive or vector icon.
        func icon(for id: UInt32) -> NSImage? {
            guard let resources else { return nil }
            let files = resources.files(for: id)
            let rasters = files.filter { file in
                let lower = file.path.lowercased()
                return (lower.hasSuffix(".png") || lower.hasSuffix(".webp") || lower.hasSuffix(".jpg")) && !lower.hasSuffix(".9.png")
            }.sorted { realDensity($0.density) > realDensity($1.density) }
            for file in rasters.prefix(4) {
                if let image = raster(file.path) { return image }
            }
            for file in files where file.path.lowercased().hasSuffix(".xml") {
                guard Date() < deadline, let element = xml(file.path) else { continue }
                if element.name == "adaptive-icon", let image = adaptive(element) { return image }
                if element.name == "vector", let image = AndroidVector.render(element, side: outputSide, color: color) {
                    return image
                }
            }
            return nil
        }

        private func realDensity(_ density: Int) -> Int { density >= 0xFFFE ? 1 : (density == 0 ? 160 : density) }

        func xml(_ path: String) -> AndroidXMLElement? {
            guard let data = data(path) else { return nil }
            if let element = try? AndroidBinaryXML.parse(data, deadline: deadline) { return element }
            return try? AndroidProtoXML.parse(data, deadline: deadline)
        }

        /// An ARGB colour from a literal, a colour resource or a "#RRGGBB" string.
        func color(_ value: AndroidValue?) -> NSColor? {
            var current = value
            for _ in 0..<6 {
                switch current {
                case .color(let argb)?:
                    return AndroidIcon.color(argb: argb)
                case .int(let raw)?:
                    return AndroidIcon.color(argb: UInt32(truncatingIfNeeded: raw))
                case .string(let text)?:
                    return AndroidIcon.color(hex: text)
                case .reference(let id)?:
                    current = resources?.values(for: id).first(where: { $0.locale.isEmpty })?.value ?? resources?.values(for: id).first?.value
                default:
                    return nil
                }
            }
            return nil
        }

        /// One adaptive layer as an image filling the 108 dp canvas (nil if it can't be drawn).
        private func layer(_ element: AndroidXMLElement?) -> (image: NSImage?, color: NSColor?)? {
            guard let element else { return nil }
            var value = element.attribute("drawable")
            if value == nil, let inner = element.children.first {
                // An inline drawable: <inset>, <bitmap>, <vector> or <color>.
                if inner.name == "vector" { return (AndroidVector.render(inner, side: outputSide * 1.5, color: color), nil) }
                if inner.name == "color" { return (nil, color(inner.attribute("color"))) }
                value = inner.attribute("drawable") ?? inner.attribute("src")
            }
            guard let value else { return nil }
            if let solid = color(value) { return (nil, solid) }
            guard case .reference(let id) = value, let resources else { return nil }
            let files = resources.files(for: id)
            let rasters = files.filter { ["png", "webp", "jpg"].contains(($0.path as NSString).pathExtension.lowercased()) }
                .sorted { realDensity($0.density) > realDensity($1.density) }
            if let first = rasters.first, let image = raster(first.path, maximumPixels: outputSide * 1.5) { return (image, nil) }
            for file in files where file.path.lowercased().hasSuffix(".xml") {
                guard let element = xml(file.path) else { continue }
                if element.name == "vector" { return (AndroidVector.render(element, side: outputSide * 1.5, color: color), nil) }
                if element.name == "inset" || element.name == "bitmap",
                   let inner = element.attribute("drawable") ?? element.attribute("src"),
                   case .reference(let innerID) = inner,
                   let innerFile = resources.files(for: innerID).first(where: { !$0.path.hasSuffix(".xml") }),
                   let image = raster(innerFile.path, maximumPixels: outputSide * 1.5) {
                    return (image, nil)
                }
            }
            return nil
        }

        func adaptive(_ element: AndroidXMLElement) -> NSImage? {
            let background = layer(element.children(named: "background").first)
            guard let foreground = layer(element.children(named: "foreground").first), foreground.image != nil || foreground.color != nil else {
                return nil
            }
            return AndroidIcon.bitmap(side: outputSide) { context, pixels in
                let rect = CGRect(x: 0, y: 0, width: pixels, height: pixels)
                context.addEllipse(in: rect)
                context.clip()
                // Layers are 108 dp; launchers show the middle 72 dp.
                let canvas = rect.insetBy(dx: -pixels / 4, dy: -pixels / 4)
                context.setFillColor((background?.color ?? .white).cgColor)
                context.fill(rect)
                background?.image?.draw(in: canvas)
                if let color = foreground.color {
                    context.setFillColor(color.cgColor)
                    context.fill(rect)
                }
                foreground.image?.draw(in: canvas)
            }
        }
    }

    /// Decodes a PNG, WebP or JPEG through ImageIO, downsampled while decoding, so a hostile
    /// "50,000 × 50,000" header can never allocate a giant bitmap.
    static func decode(_ data: Data, maximumPixels: CGFloat = outputSide) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0, width <= 16_384, height <= 16_384 else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maximumPixels),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        // Points match the output size whatever the bitmap's resolution, so every icon lays out alike.
        let scale = maximumPixels / CGFloat(max(image.width, image.height))
        return NSImage(cgImage: image, size: NSSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale))
    }

    /// Draws into a fresh 2x bitmap off the main thread; `body` gets the context and the side in pixels.
    static func bitmap(side: CGFloat, _ body: (CGContext, CGFloat) -> Void) -> NSImage? {
        let pixels = Int(side * 2)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let graphics = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        rep.size = NSSize(width: side, height: side)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        graphics.imageInterpolation = .high
        body(graphics.cgContext, CGFloat(pixels))
        graphics.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }

    static func color(argb: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((argb >> 16) & 0xFF) / 255, green: CGFloat((argb >> 8) & 0xFF) / 255,
                blue: CGFloat(argb & 0xFF) / 255, alpha: CGFloat((argb >> 24) & 0xFF) / 255)
    }

    /// "#RGB", "#ARGB", "#RRGGBB" or "#AARRGGBB".
    static func color(hex text: String) -> NSColor? {
        guard text.hasPrefix("#") else { return nil }
        let digits = String(text.dropFirst())
        guard let value = UInt32(digits, radix: 16) else { return nil }
        switch digits.count {
        case 3: return color(argb: 0xFF00_0000 | expand(value, 3))
        case 4: return color(argb: expand(value, 4))
        case 6: return color(argb: 0xFF00_0000 | value)
        case 8: return color(argb: value)
        default: return nil
        }
    }

    private static func expand(_ value: UInt32, _ nibbles: Int) -> UInt32 {
        var result: UInt32 = 0
        for index in (0..<nibbles).reversed() {
            let nibble = (value >> (UInt32(index) * 4)) & 0xF
            result = result << 8 | (nibble << 4 | nibble)
        }
        return result
    }
}
