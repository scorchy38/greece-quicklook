import AppKit

enum PaletteFormat: String, Codable {
    case ase, aco, act, clr, gpl, procreate, sketch

    var title: String {
        switch self {
        // Adobe's own names for its formats.
        case .ase: return "Adobe Swatch Exchange"
        case .aco: return String(localized: "Photoshop Swatches", bundle: .greeceKit, comment: "Info bar title: a Photoshop swatch file (.aco)")
        case .act: return "Adobe Color Table"
        case .clr: return String(localized: "Color List", bundle: .greeceKit, comment: "Info bar title: a macOS colour list (.clr), as made in the colour picker")
        case .gpl: return String(localized: "GIMP Palette", bundle: .greeceKit, comment: "Info bar title. GIMP is an app")
        case .procreate: return String(localized: "Procreate Swatches", bundle: .greeceKit, comment: "Info bar title. Procreate is an app")
        case .sketch: return String(localized: "Sketch Palette", bundle: .greeceKit, comment: "Info bar title. Sketch is an app")
        }
    }

    var badge: String {
        switch self {
        case .ase: return "ASE"
        case .aco: return "ACO"
        case .act: return "ACT"
        case .clr: return "CLR"
        case .gpl: return "GPL"
        case .procreate: return "SWATCHES"
        case .sketch: return "PALETTE"
        }
    }

    static func detect(ext: String, probe: FileProbe) -> PaletteFormat? {
        switch ext {
        case "ase": return probe.hasPrefix(Array("ASEF".utf8)) ? .ase : nil
        case "aco":
            let reader = MediaReader(bytes: Array(probe.bytes.prefix(4)))
            guard let version = reader.u16(0), version == 1 || version == 2, let count = reader.u16(2), count > 0 else { return nil }
            return .aco
        case "act": return probe.bytes.count == 768 || probe.bytes.count == 772 ? .act : nil
        case "clr": return probe.hasPrefix(Array("bplist00".utf8)) ? .clr : nil
        case "gpl": return probe.isText && probe.text.drop(while: { $0 == "\u{FEFF}" }).hasPrefix("GIMP Palette") ? .gpl : nil
        case "swatches": return probe.hasPrefix([0x50, 0x4B, 0x03, 0x04]) ? .procreate : nil
        case "sketchpalette": return probe.isText && probe.text.contains("\"colors\"") ? .sketch : nil
        default: return nil
        }
    }
}

struct PaletteColor: Encodable, Equatable {
    var name: String?
    /// sRGB, for display and copying: "#1a2b3c".
    var hex: String
    var alpha: Double
    /// The colour as the file defines it: "RGB", "CMYK", "Lab", "Gray", "HSB", "Display P3".
    var model: String
    var values: [Double]
    /// Adobe's colour types: "Global", "Spot" (nil for process colours and other formats).
    var kind: String?
    /// Rounded sRGB channels, 0–255.
    var rgb: [Int]
    /// True when the colour doesn't fit in sRGB and was clipped for display.
    var clipped = false
}

struct PaletteGroup: Encodable, Equatable {
    var name: String?
    var colors: [PaletteColor]
}

struct Palette: Encodable {
    var name: String?
    var groups: [PaletteGroup]
    var columns: Int?

    var count: Int { groups.reduce(0) { $0 + $1.colors.count } }
    var allColors: [PaletteColor] { groups.flatMap(\.colors) }
}

enum PaletteParser {
    static let colorLimit = 20_000

    static func parse(_ data: Data, format: PaletteFormat) throws -> Palette {
        let palette: Palette
        switch format {
        case .ase: palette = try ase(data)
        case .aco: palette = try aco(data)
        case .act: palette = act(data)
        case .clr: palette = try clr(data)
        case .gpl: palette = gpl(TextFile.decode(data).0)
        case .procreate: palette = try procreate(data)
        case .sketch: palette = try sketch(data)
        }
        guard palette.count > 0 else { throw MediaError.unreadable(String(localized: "This palette has no colors.", bundle: .greeceKit)) }
        return palette
    }

    // MARK: - Colour conversion

    private static let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let extendedSRGB = CGColorSpace(name: CGColorSpace.extendedSRGB)!

    static func color(_ components: [CGFloat], space: CGColorSpace?, name: String?, model: String, values: [Double], kind: String? = nil) -> PaletteColor? {
        guard let space, components.count == space.numberOfComponents + 1, components.allSatisfy(\.isFinite),
              let source = CGColor(colorSpace: space, components: components),
              let converted = source.converted(to: extendedSRGB, intent: .relativeColorimetric, options: nil),
              let channels = converted.components, channels.count >= 3 else { return nil }
        let clipped = channels.prefix(3).contains { $0 < -0.002 || $0 > 1.002 }
        let rgb = channels.prefix(3).map { Int((min(max($0, 0), 1) * 255).rounded()) }
        let alpha = Double(min(max(channels.count > 3 ? channels[3] : 1, 0), 1))
        return PaletteColor(name: clean(name), hex: String(format: "#%02x%02x%02x", rgb[0], rgb[1], rgb[2]), alpha: alpha,
                            model: model, values: values.map { ($0 * 1000).rounded() / 1000 }, kind: kind, rgb: rgb, clipped: clipped)
    }

    static func rgb(_ r: Double, _ g: Double, _ b: Double, alpha: Double = 1, name: String?, space: CGColorSpace? = srgb, model: String = "RGB", values: [Double]? = nil) -> PaletteColor? {
        color([r, g, b, alpha].map { CGFloat(min(max($0, 0), 1)) }, space: space, name: name, model: model, values: values ?? [r, g, b].map { ($0 * 255).rounded() })
    }

    static func cmyk(_ c: Double, _ m: Double, _ y: Double, _ k: Double, name: String?, kind: String? = nil) -> PaletteColor? {
        color([c, m, y, k, 1].map { CGFloat(min(max($0, 0), 1)) }, space: CGColorSpace(name: CGColorSpace.genericCMYK), name: name, model: "CMYK",
              values: [c, m, y, k].map { ($0 * 100).rounded() }, kind: kind)
    }

    static func lab(_ l: Double, _ a: Double, _ b: Double, name: String?, kind: String? = nil) -> PaletteColor? {
        var white: [CGFloat] = [0.9642, 1.0, 0.8249]
        var black: [CGFloat] = [0, 0, 0]
        var range: [CGFloat] = [-128, 127, -128, 127]
        let space = CGColorSpace(labWhitePoint: &white, blackPoint: &black, range: &range)
        return color([CGFloat(l), CGFloat(min(max(a, -128), 127)), CGFloat(min(max(b, -128), 127)), 1], space: space, name: name, model: "Lab",
                     values: [l, a, b].map { ($0 * 10).rounded() / 10 }, kind: kind)
    }

    static func gray(_ white: Double, name: String?, kind: String? = nil) -> PaletteColor? {
        color([CGFloat(min(max(white, 0), 1)), 1], space: CGColorSpace(name: CGColorSpace.genericGrayGamma2_2), name: name, model: "Gray",
              values: [(white * 100).rounded()], kind: kind)
    }

    static func hsb(_ h: Double, _ s: Double, _ v: Double, alpha: Double = 1, name: String?, space: CGColorSpace? = srgb, model: String = "HSB") -> PaletteColor? {
        let (r, g, b) = hsbToRGB(h, s, v)
        return rgb(r, g, b, alpha: alpha, name: name, space: space, model: model,
                   values: [(h * 360).rounded(), (s * 100).rounded(), (v * 100).rounded()])
    }

    static func hsbToRGB(_ h: Double, _ s: Double, _ v: Double) -> (Double, Double, Double) {
        let hue = (h.truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1) * 6
        let sector = Int(hue) % 6, f = hue - floor(hue)
        let p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f))
        switch sector {
        case 0: return (v, t, p)
        case 1: return (q, v, p)
        case 2: return (p, v, t)
        case 3: return (p, q, v)
        case 4: return (t, p, v)
        default: return (v, p, q)
        }
    }

    private static func clean(_ name: String?) -> String? {
        guard let trimmed = name?.replacingOccurrences(of: "\0", with: "").trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed.count > 200 ? String(trimmed.prefix(200)) : trimmed
    }

    // MARK: - Adobe Swatch Exchange (.ase)

    private static func utf16Name(_ reader: MediaReader, at offset: Int) -> (String?, Int)? {
        guard let units = reader.u16(offset), let bytes = reader.slice(offset + 2, units * 2) else { return nil }
        return (String(bytes: Array(bytes), encoding: .utf16BigEndian), 2 + units * 2)
    }

    static func ase(_ data: Data) throws -> Palette {
        let reader = MediaReader(data)
        guard reader.tag(0) == "ASEF", let blocks = reader.u32(8) else { throw MediaError.unreadable(String(localized: "This swatch file is damaged.", bundle: .greeceKit)) }
        var groups: [PaletteGroup] = []
        var current: PaletteGroup?
        var offset = 12
        var total = 0
        for _ in 0..<min(blocks, colorLimit * 2) {
            guard let type = reader.u16(offset), let length = reader.u32(offset + 2), length <= data.count else { break }
            let body = offset + 6
            switch type {
            case 0xC001:
                if let open = current, !open.colors.isEmpty { groups.append(open) }
                current = PaletteGroup(name: clean(utf16Name(reader, at: body)?.0), colors: [])
            case 0xC002:
                if let open = current { groups.append(open) }
                current = nil
            case 0x0001:
                guard let (name, used) = utf16Name(reader, at: body), let model = reader.tag(body + used) else { break }
                let valueStart = body + used + 4
                func float(_ index: Int) -> Double? {
                    reader.u32(valueStart + index * 4).map { Double(Float(bitPattern: UInt32($0))) }.flatMap { $0.isFinite ? $0 : nil }
                }
                let channelCount = ["RGB ": 3, "CMYK": 4, "LAB ": 3, "Gray": 1][model] ?? 0
                let typeCode = reader.u16(valueStart + channelCount * 4)
                let kind = typeCode == 0 ? "Global" : typeCode == 1 ? "Spot" : nil
                var color: PaletteColor?
                switch model {
                case "RGB ": if let r = float(0), let g = float(1), let b = float(2) { color = rgb(r, g, b, name: name) }
                case "CMYK": if let c = float(0), let m = float(1), let y = float(2), let k = float(3) { color = cmyk(c, m, y, k, name: name, kind: kind) }
                case "LAB ": if let l = float(0), let a = float(1), let b = float(2) { color = lab(l * 100, a, b, name: name, kind: kind) }
                case "Gray": if let g = float(0) { color = gray(g, name: name, kind: kind) }
                default: break
                }
                if var color {
                    if color.kind == nil { color.kind = kind }
                    if current != nil {
                        current!.colors.append(color)
                    } else if let last = groups.indices.last, groups[last].name == nil {
                        groups[last].colors.append(color)
                    } else {
                        // Colours outside any group keep their place between groups.
                        groups.append(PaletteGroup(name: nil, colors: [color]))
                    }
                    total += 1
                }
            default:
                break
            }
            offset = body + length
            if total >= colorLimit { break }
        }
        if let open = current, !open.colors.isEmpty { groups.append(open) }
        return Palette(name: nil, groups: groups.filter { !$0.colors.isEmpty })
    }

    // MARK: - Photoshop swatches (.aco)

    static func aco(_ data: Data) throws -> Palette {
        let reader = MediaReader(data)
        func section(at start: Int, named: Bool) -> ([PaletteColor], Int)? {
            guard let version = reader.u16(start), version == (named ? 2 : 1), let count = reader.u16(start + 2) else { return nil }
            var colors: [PaletteColor] = []
            var offset = start + 4
            for _ in 0..<min(count, colorLimit) {
                guard let space = reader.u16(offset), let w = reader.u16(offset + 2), let x = reader.u16(offset + 4),
                      let y = reader.u16(offset + 6), let z = reader.u16(offset + 8) else { return nil }
                offset += 10
                var name: String?
                if named {
                    guard let length = reader.u32(offset + 2), length < 4096, let bytes = reader.slice(offset + 6, length * 2) else { return nil }
                    name = String(bytes: Array(bytes), encoding: .utf16BigEndian)
                    offset += 6 + length * 2
                }
                let color: PaletteColor?
                switch space {
                case 0: color = rgb(Double(w) / 65535, Double(x) / 65535, Double(y) / 65535, name: name)
                case 1: color = hsb(Double(w) / 65535, Double(x) / 65535, Double(y) / 65535, name: name)
                // Photoshop stores CMYK inverted: 0 is full ink.
                case 2: color = cmyk(1 - Double(w) / 65535, 1 - Double(x) / 65535, 1 - Double(y) / 65535, 1 - Double(z) / 65535, name: name)
                case 7: color = lab(Double(w) / 100, Double(Int16(bitPattern: UInt16(x))) / 100, Double(Int16(bitPattern: UInt16(y))) / 100, name: name)
                case 8: color = gray(1 - Double(min(w, 10000)) / 10000, name: name)
                case 9: color = cmyk(Double(min(w, 10000)) / 10000, Double(min(x, 10000)) / 10000, Double(min(y, 10000)) / 10000, Double(min(z, 10000)) / 10000, name: name)
                default: color = nil
                }
                if let color { colors.append(color) }
            }
            return (colors, offset)
        }
        guard let (first, end) = section(at: 0, named: reader.u16(0) == 2) else { throw MediaError.unreadable(String(localized: "This swatch file is damaged.", bundle: .greeceKit)) }
        // Version 1 is usually followed by version 2, which repeats the colours with their names.
        if reader.u16(0) == 1, let (named, _) = section(at: end, named: true), named.count == first.count {
            return Palette(name: nil, groups: [PaletteGroup(name: nil, colors: named)])
        }
        return Palette(name: nil, groups: [PaletteGroup(name: nil, colors: first)])
    }

    // MARK: - Adobe Color Table (.act)

    static func act(_ data: Data) -> Palette {
        let bytes = [UInt8](data.prefix(772))
        var count = 256
        if bytes.count == 772 { count = min(256, Int(bytes[768]) << 8 | Int(bytes[769])); if count == 0 { count = 256 } }
        let colors = (0..<min(count, bytes.count / 3)).compactMap { index in
            rgb(Double(bytes[index * 3]) / 255, Double(bytes[index * 3 + 1]) / 255, Double(bytes[index * 3 + 2]) / 255, name: nil)
        }
        return Palette(name: nil, groups: [PaletteGroup(name: nil, colors: colors)], columns: 16)
    }

    // MARK: - Apple colour lists (.clr)

    /// NSColorList archives, decoded with secure coding: only arrays, strings and colours.
    static func clr(_ data: Data) throws -> Palette {
        let unarchiver = try NSKeyedUnarchiver(forReadingFrom: data)
        unarchiver.requiresSecureCoding = true
        unarchiver.decodingFailurePolicy = .setErrorAndReturn
        defer { unarchiver.finishDecoding() }
        let keys = unarchiver.decodeObject(of: [NSArray.self, NSString.self], forKey: "NSKeys") as? [String] ?? []
        let colors = unarchiver.decodeObject(of: [NSArray.self, NSColor.self], forKey: "NSColors") as? [NSColor] ?? []
        guard !colors.isEmpty else { throw MediaError.unreadable(String(localized: "This color list is damaged or uses an old format.", bundle: .greeceKit)) }
        var result: [PaletteColor] = []
        for (index, color) in colors.prefix(colorLimit).enumerated() {
            let name = index < keys.count ? keys[index] : nil
            if let converted = paletteColor(color, name: name) { result.append(converted) }
        }
        return Palette(name: nil, groups: [PaletteGroup(name: nil, colors: result)])
    }

    static func paletteColor(_ color: NSColor, name: String?) -> PaletteColor? {
        guard color.type == .componentBased else {
            // Catalog colours (system colours) resolve to their current appearance.
            return color.usingColorSpace(.sRGB).flatMap { paletteColor($0, name: name) }
        }
        let space = color.colorSpace
        switch space.colorSpaceModel {
        case .cmyk:
            return cmyk(Double(color.cyanComponent), Double(color.magentaComponent), Double(color.yellowComponent), Double(color.blackComponent), name: name)
        case .gray:
            return gray(Double(color.whiteComponent), name: name)
        default:
            guard let cg = space.cgColorSpace else { return nil }
            var components = [CGFloat](repeating: 0, count: color.numberOfComponents)
            color.getComponents(&components)
            let model = space == .displayP3 ? "Display P3" : "RGB"
            let values = components.dropLast().map { (Double($0) * 255).rounded() }
            return self.color(components, space: cg, name: name, model: model, values: values)
        }
    }

    // MARK: - GIMP (.gpl)

    static func gpl(_ text: String) -> Palette {
        var name: String?
        var columns: Int?
        var colors: [PaletteColor] = []
        for raw in text.split(whereSeparator: \.isNewline).dropFirst().prefix(colorLimit + 100) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.lowercased().hasPrefix("name:") { name = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces); continue }
            if line.lowercased().hasPrefix("columns:") { columns = Int(line.dropFirst(8).trimmingCharacters(in: .whitespaces)).map { min(max($0, 1), 64) }; continue }
            let parts = line.split(maxSplits: 3, whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 3, let r = Int(parts[0]), let g = Int(parts[1]), let b = Int(parts[2]) else { continue }
            var label = parts.count > 3 ? String(parts[3]).trimmingCharacters(in: .whitespaces) : nil
            if label == "Untitled" { label = nil }
            if let color = rgb(Double(min(max(r, 0), 255)) / 255, Double(min(max(g, 0), 255)) / 255, Double(min(max(b, 0), 255)) / 255, name: label) {
                colors.append(color)
            }
            if colors.count >= colorLimit { break }
        }
        return Palette(name: clean(name), groups: [PaletteGroup(name: nil, colors: colors)], columns: columns == 0 ? nil : columns)
    }

    // MARK: - Procreate (.swatches)

    static func procreate(_ data: Data) throws -> Palette {
        guard let zip = ZIPArchive.media(data), let entry = zip.member(named: "Swatches.json") ?? zip.members.first(where: { $0.path.hasSuffix(".json") }),
              let json = try? zip.contents(of: entry, limit: 8 * 1024 * 1024),
              let object = try? JSONSerialization.jsonObject(with: json) else { throw MediaError.unreadable(String(localized: "These swatches are damaged.", bundle: .greeceKit)) }
        let palettes = (object as? [[String: Any]]) ?? [(object as? [String: Any]) ?? [:]]
        var groups: [PaletteGroup] = []
        for palette in palettes.prefix(64) {
            let swatches = palette["swatches"] as? [Any] ?? []
            let colors = swatches.prefix(colorLimit).compactMap { item -> PaletteColor? in
                guard let swatch = item as? [String: Any], let h = swatch["hue"] as? Double, let s = swatch["saturation"] as? Double,
                      let v = swatch["brightness"] as? Double else { return nil }
                let alpha = swatch["alpha"] as? Double ?? 1
                // colorSpace 1 is Display P3; anything else is sRGB.
                let p3 = (swatch["colorSpace"] as? Int) == 1
                return hsb(h, s, v, alpha: alpha, name: nil, space: p3 ? CGColorSpace(name: CGColorSpace.displayP3) : srgb, model: p3 ? "HSB (P3)" : "HSB")
            }
            if !colors.isEmpty { groups.append(PaletteGroup(name: clean(palette["name"] as? String), colors: colors)) }
        }
        return Palette(name: groups.count == 1 ? groups[0].name : nil, groups: groups.count == 1 ? [PaletteGroup(name: nil, colors: groups[0].colors)] : groups)
    }

    // MARK: - Sketch (.sketchpalette)

    static func sketch(_ data: Data) throws -> Palette {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let items = object["colors"] as? [Any] else {
            throw MediaError.unreadable(String(localized: "This palette is damaged.", bundle: .greeceKit))
        }
        let colors = items.prefix(colorLimit).compactMap { item -> PaletteColor? in
            if let hex = item as? String { return hexColor(hex, name: nil) }
            guard let color = item as? [String: Any], let r = color["red"] as? Double, let g = color["green"] as? Double, let b = color["blue"] as? Double else { return nil }
            return rgb(r, g, b, alpha: color["alpha"] as? Double ?? 1, name: color["name"] as? String)
        }
        return Palette(name: nil, groups: [PaletteGroup(name: nil, colors: colors)])
    }

    static func hexColor(_ value: String, name: String?) -> PaletteColor? {
        var hex = value.trimmingCharacters(in: .whitespaces)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard [3, 6, 8].contains(hex.count), let number = UInt64(hex, radix: 16) else { return nil }
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        let full = UInt64(hex, radix: 16) ?? number
        let shift: UInt64 = hex.count == 8 ? 8 : 0
        let alpha = hex.count == 8 ? Double(full & 0xFF) / 255 : 1
        return rgb(Double((full >> (16 + shift)) & 0xFF) / 255, Double((full >> (8 + shift)) & 0xFF) / 255, Double((full >> shift) & 0xFF) / 255, alpha: alpha, name: name)
    }
}
