import Foundation

/// ESRI shapefiles: geometry from .shp, attributes from .dbf, the CRS from .prj and the text
/// encoding from .cpg. Every count and length in the binary headers is validated.
enum ShapefileReader {

    struct Sources {
        var name: String
        var shp: Data
        var dbf: Data?
        var prj: String?
        var cpg: String?
    }

    /// The sidecars beside a .shp on disk (any case of extension).
    static func sources(for url: URL, maxBytes: Int) throws -> Sources {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= maxBytes else {
            throw GeoError.tooLarge("This shapefile is \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)); Greece draws shapefiles up to \(ByteCountFormatter.string(fromByteCount: Int64(maxBytes), countStyle: .file)).")
        }
        let shp = try Data(contentsOf: url, options: .alwaysMapped)
        let folder = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        let siblings = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        func sidecar(_ ext: String) -> URL? {
            let wanted = (base + "." + ext).lowercased()
            return siblings.first { $0.lowercased() == wanted }.map { folder.appendingPathComponent($0) }
        }
        let dbf = sidecar("dbf").flatMap { try? Data(contentsOf: $0, options: .alwaysMapped) }
        let prj = sidecar("prj").flatMap { try? Data(contentsOf: $0) }.map { String(decoding: $0.prefix(64 * 1024), as: UTF8.self) }
        let cpg = sidecar("cpg").flatMap { try? Data(contentsOf: $0) }.map { String(decoding: $0.prefix(256), as: UTF8.self) }
        return Sources(name: base, shp: shp, dbf: dbf, prj: prj, cpg: cpg)
    }

    /// Every shapefile inside a ZIP, with its sidecars.
    static func sources(in zip: ZIPArchive, maxBytes: Int) -> [Sources] {
        var result: [Sources] = []
        let shps = zip.members.filter { $0.path.lowercased().hasSuffix(".shp") && !$0.path.hasPrefix("__MACOSX") && !($0.path as NSString).lastPathComponent.hasPrefix("._") }
        var budget = maxBytes
        for member in shps.prefix(64) {
            let base = String(member.path.dropLast(4))
            guard let shp = try? zip.contents(of: member, limit: budget) else { continue }
            budget -= shp.count
            func sidecar(_ ext: String, limit: Int) -> Data? {
                guard let m = zip.member(named: base + "." + ext) else { return nil }
                return try? zip.contents(of: m, limit: min(limit, max(budget, 0)))
            }
            let dbf = sidecar("dbf", limit: maxBytes)
            budget -= dbf?.count ?? 0
            result.append(Sources(name: (base as NSString).lastPathComponent, shp: shp, dbf: dbf,
                                  prj: sidecar("prj", limit: 64 * 1024).map { String(decoding: $0, as: UTF8.self) },
                                  cpg: sidecar("cpg", limit: 256).map { String(decoding: $0, as: UTF8.self) }))
            if budget <= 0 { break }
        }
        return result
    }

    struct Result {
        var layer: GeoLayer
        var crs: CRS?
        var prjUnreadable = false
        var shapeType: Int32
    }

    static func read(_ sources: Sources, limits: GeoLimits, budget: inout GeoBudget) throws -> Result {
        let data = sources.shp
        guard data.count >= 100, data.beU32(0) == 9994 else { throw GeoError.invalid("This isn’t a shapefile.") }
        let shapeType = Int32(bitPattern: data.u32(32))
        let layer = GeoLayer(name: sources.name)
        let table = sources.dbf.flatMap { ShapefileDBF(data: $0, cpg: sources.cpg, maxFields: max(limits.maxProperties, 1)) }

        var offset = 100
        var index = 0
        while offset + 8 <= data.count {
            let words = Int(data.beU32(offset + 4))
            let length = words * 2
            let content = offset + 8
            guard words >= 0, length >= 4, content + length <= data.count else { break }
            defer { offset = content + length; index += 1 }
            if table?.isDeleted(index) == true { continue }
            let geometry = shape(data, at: content, length: length)
            var feature = GeoFeature(geometry: geometry)
            if limits.maxProperties > 0, let table { feature.properties = table.record(index) }
            GeoJSONReader.finish(&feature)
            if budget.exhausted { break }
            if budget.admit(geometry) { layer.features.append(feature) }
        }
        var result = Result(layer: layer, crs: nil, shapeType: shapeType)
        if let prj = sources.prj, !prj.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let crs = CRS.parse(wkt: prj) { result.crs = crs } else { result.prjUnreadable = true }
        }
        return result
    }

    private static func shape(_ d: Data, at start: Int, length: Int) -> GeoGeometry? {
        let end = start + length
        let type = Int32(bitPattern: d.u32(start))
        func point(_ at: Int) -> GeoPoint { GeoPoint(d.f64(at), d.f64(at + 8)) }
        switch type {
        case 0:
            return nil
        case 1, 11, 21:
            guard start + 20 <= end else { return nil }
            let p = point(start + 4)
            return p.isFinite ? .point(p) : nil
        case 8, 18, 28:
            guard start + 40 <= end else { return nil }
            let count = Int(d.u32(start + 36))
            guard count >= 0, count <= (end - start - 40) / 16 else { return nil }
            return .multiPoint((0..<count).map { point(start + 40 + $0 * 16) }.filter(\.isFinite))
        case 3, 13, 23, 5, 15, 25, 31:
            guard start + 44 <= end else { return nil }
            let partCount = Int(d.u32(start + 36))
            let pointCount = Int(d.u32(start + 40))
            let isPatch = type == 31
            let partsAt = start + 44
            let typesAt = partsAt + partCount * 4
            let pointsAt = isPatch ? typesAt + partCount * 4 : typesAt
            guard partCount >= 1, partCount <= 1_000_000, pointCount >= 0, pointCount <= (end - start) / 16,
                  pointsAt + pointCount * 16 <= end else { return nil }
            var parts: [[GeoPoint]] = []
            parts.reserveCapacity(partCount)
            for i in 0..<partCount {
                let first = Int(d.u32(partsAt + i * 4))
                let last = i + 1 < partCount ? Int(d.u32(partsAt + (i + 1) * 4)) : pointCount
                guard first >= 0, first <= last, last <= pointCount else { continue }
                if isPatch {
                    // Only ring parts; triangle strips and fans have no outline to draw.
                    let partType = d.u32(typesAt + i * 4)
                    guard partType >= 2 else { continue }
                }
                var ring: [GeoPoint] = []
                ring.reserveCapacity(last - first)
                for j in first..<last {
                    let p = point(pointsAt + j * 16)
                    if p.isFinite { ring.append(p) }
                }
                parts.append(ring)
            }
            if type == 3 || type == 13 || type == 23 {
                let lines = parts.filter { $0.count >= 2 }
                return lines.count == 1 ? .lineString(lines[0]) : .multiLineString(lines)
            }
            return assemblePolygons(parts.filter { $0.count >= 4 })
        default:
            return nil
        }
    }

    /// Groups rings into polygons by containment (outer rings and their holes), which works
    /// whatever orientation the writer used.
    static func assemblePolygons(_ rings: [[GeoPoint]]) -> GeoGeometry? {
        guard !rings.isEmpty else { return nil }
        if rings.count == 1 { return .polygon(rings) }
        let areas = rings.map { abs(GeoJSONWriter.signedArea($0)) }
        if rings.count > 2000 {
            // Too many to compare: trust the specification (outer rings clockwise).
            var polygons: [[[GeoPoint]]] = []
            for ring in rings {
                if GeoJSONWriter.signedArea(ring) <= 0 || polygons.isEmpty { polygons.append([ring]) } else { polygons[polygons.count - 1].append(ring) }
            }
            return .multiPolygon(polygons)
        }
        let order = rings.indices.sorted { areas[$0] > areas[$1] }
        let boxes = rings.map { ring -> GeoBounds in var b = GeoBounds(); ring.forEach { b.extend($0) }; return b }
        var depth = [Int](repeating: 0, count: rings.count)
        var polygonOf = [Int](repeating: -1, count: rings.count)
        var polygons: [[[GeoPoint]]] = []
        var processed: [Int] = []
        for i in order {
            let probe = rings[i][0]
            var container: Int?
            for j in processed.reversed() where areas[j] >= areas[i] {
                let b = boxes[j]
                guard probe.x >= b.minX, probe.x <= b.maxX, probe.y >= b.minY, probe.y <= b.maxY else { continue }
                if contains(rings[j], probe) { container = j; break }
            }
            if let j = container, depth[j] % 2 == 0 {
                depth[i] = depth[j] + 1
                polygons[polygonOf[j]].append(rings[i])
                polygonOf[i] = polygonOf[j]
            } else {
                depth[i] = container.map { depth[$0] + 1 } ?? 0
                polygonOf[i] = polygons.count
                polygons.append([rings[i]])
            }
            processed.append(i)
        }
        return polygons.count == 1 ? .polygon(polygons[0]) : .multiPolygon(polygons)
    }

    static func contains(_ ring: [GeoPoint], _ p: GeoPoint) -> Bool {
        var inside = false
        var j = ring.count - 1
        for i in ring.indices {
            let a = ring[i], b = ring[j]
            if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            j = i
        }
        return inside
    }
}

/// A dBase III/IV table (.dbf).
struct ShapefileDBF {
    struct Field { let name: String; let type: UInt8; let offset: Int; let length: Int; let decimals: Int }

    private let data: Data
    let fields: [Field]
    let recordCount: Int
    private let headerLength: Int
    private let recordLength: Int
    private let encoding: String.Encoding?

    init?(data: Data, cpg: String?, maxFields: Int) {
        guard data.count >= 33 else { return nil }
        self.data = data
        recordCount = Int(data.u32(4))
        headerLength = Int(data.u16(8))
        recordLength = Int(data.u16(10))
        guard headerLength >= 33, headerLength <= data.count, recordLength >= 1 else { return nil }
        var fields: [Field] = []
        var at = 32
        var offset = 1
        while at + 32 <= headerLength, data[data.startIndex + at] != 0x0D, fields.count < 2048 {
            let nameBytes = data.subdata(in: at..<(at + 11)).prefix { $0 != 0 }
            let name = String(decoding: nameBytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
            let length = Int(data[data.startIndex + at + 16])
            let decimals = Int(data[data.startIndex + at + 17])
            let type = data[data.startIndex + at + 11]
            if fields.count < maxFields { fields.append(Field(name: name.isEmpty ? "Field \(fields.count + 1)" : name, type: type, offset: offset, length: length, decimals: decimals)) }
            offset += length
            at += 32
        }
        self.fields = fields
        encoding = ShapefileDBF.encoding(cpg: cpg, languageDriver: data[data.startIndex + 29])
    }

    static func encoding(cpg: String?, languageDriver: UInt8) -> String.Encoding? {
        func cf(_ e: CFStringEncodings) -> String.Encoding {
            String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(e.rawValue)))
        }
        if let cpg = cpg?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().replacingOccurrences(of: "-", with: "").replacingOccurrences(of: "_", with: "") {
            switch cpg {
            case "UTF8", "65001": return .utf8
            case "1252", "CP1252", "WINDOWS1252", "ANSI1252": return .windowsCP1252
            case "88591", "ISO88591", "LATIN1": return .isoLatin1
            case "1250", "CP1250", "WINDOWS1250": return .windowsCP1250
            case "1251", "CP1251", "WINDOWS1251": return .windowsCP1251
            case "1253", "CP1253": return .windowsCP1253
            case "1254", "CP1254": return .windowsCP1254
            case "932", "SHIFTJIS", "SJIS": return .shiftJIS
            case "936", "GBK", "GB2312": return cf(.GB_18030_2000)
            case "950", "BIG5": return cf(.big5)
            case "949", "EUCKR": return cf(.EUC_KR)
            case "437", "CP437": return cf(.dosLatinUS)
            case "850", "CP850": return cf(.dosLatin1)
            case "866", "CP866": return cf(.dosRussian)
            case "88592", "ISO88592": return .isoLatin2
            default: break
            }
        }
        switch languageDriver {
        case 0x01: return cf(.dosLatinUS)
        case 0x02: return cf(.dosLatin1)
        case 0x03, 0x57: return .windowsCP1252
        case 0x4D: return cf(.GB_18030_2000)
        case 0x4E: return cf(.EUC_KR)
        case 0x4F: return cf(.big5)
        case 0x13, 0x7B: return .shiftJIS
        case 0x65: return cf(.dosRussian)
        case 0xC8: return .windowsCP1250
        case 0xC9: return .windowsCP1251
        case 0xCB: return .windowsCP1253
        default: return nil
        }
    }

    func isDeleted(_ index: Int) -> Bool {
        let at = headerLength + index * recordLength
        guard index < recordCount, at < data.count else { return false }
        return data[data.startIndex + at] == 0x2A
    }

    private func decode(_ bytes: Data) -> String {
        if let encoding, encoding != .utf8 {
            // UTF-8 files are often mislabelled; prefer it when the bytes are valid UTF-8.
            if let utf8 = String(data: bytes, encoding: .utf8), bytes.contains(where: { $0 >= 0x80 }) { return utf8 }
            if let text = String(data: bytes, encoding: encoding) { return text }
        }
        if let text = String(data: bytes, encoding: .utf8) { return text }
        return String(data: bytes, encoding: .windowsCP1252) ?? String(decoding: bytes, as: UTF8.self)
    }

    func record(_ index: Int) -> [(key: String, value: GeoValue)] {
        guard index < recordCount else { return [] }
        let start = headerLength + index * recordLength
        guard start + recordLength <= data.count else { return [] }
        var result: [(key: String, value: GeoValue)] = []
        result.reserveCapacity(fields.count)
        for field in fields {
            let from = start + field.offset, to = from + field.length
            guard to <= start + recordLength else { continue }
            let bytes = data.subdata(in: from..<to)
            let raw = decode(bytes).trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\0")))
            let value: GeoValue
            switch field.type {
            case UInt8(ascii: "N"), UInt8(ascii: "F"), UInt8(ascii: "O"):
                if raw.isEmpty || raw.allSatisfy({ $0 == "*" }) { value = .null } else { value = Double(raw).map(GeoValue.number) ?? .string(raw) }
            case UInt8(ascii: "I"):
                value = bytes.count >= 4 ? .number(Double(Int32(bitPattern: bytes.u32(0)))) : .null
            case UInt8(ascii: "L"):
                switch raw.uppercased() {
                case "T", "Y": value = .bool(true)
                case "F", "N": value = .bool(false)
                default: value = .null
                }
            case UInt8(ascii: "D"):
                if raw.count == 8, raw.allSatisfy(\.isNumber) {
                    let c = Array(raw)
                    value = .string("\(String(c[0..<4]))-\(String(c[4..<6]))-\(String(c[6..<8]))")
                } else {
                    value = raw.isEmpty ? .null : .string(raw)
                }
            case UInt8(ascii: "M"), UInt8(ascii: "B"), UInt8(ascii: "G"):
                value = .null
            default:
                value = raw.isEmpty ? .null : .string(raw)
            }
            result.append((field.name, value))
        }
        return result
    }
}

extension Data {
    @inline(__always) func beU32(_ offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= count else { return 0 }
        return withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self).bigEndian }
    }
    @inline(__always) func f64(_ offset: Int) -> Double {
        guard offset >= 0, offset + 8 <= count else { return .nan }
        return withUnsafeBytes { Double(bitPattern: $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self).littleEndian) }
    }
}
