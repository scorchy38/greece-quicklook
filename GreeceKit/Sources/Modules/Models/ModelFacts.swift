import Foundation
import simd

/// What Greece can say about a model before rendering it: counts, size and units. Read with
/// hard limits; any field may be missing. The page refines these once three.js has loaded the model.
struct ModelFacts: Encodable, Equatable {
    var triangles: Int?
    var vertices: Int?
    var faces: Int?
    var meshes: Int?
    var materials: Int?
    var textures: Int?
    var animations: Int?
    var points: Int?
    var voxels: Int?
    /// Bounding-box size along the file's own x, y and z axes, in `units`.
    var size: [Double]?
    /// "m", "mm", "cm", "in", "ft", "µm", "US ft"; nil when the format has no units.
    var units: String?
    var generator: String?
    var version: String?
    var compression: [String] = []
    var isSplat = false

    /// Anything larger is summarised from its header only.
    static let scanLimit = 512 * 1024 * 1024

    static func read(_ format: ModelFormat, url: URL, deadline: Date = Date().addingTimeInterval(1.5)) -> ModelFacts {
        var facts = ModelFacts()
        switch format {
        case .gltf, .glb:
            guard let document = try? GLTFDocument(url: url) else { break }
            let summary = document.summarize()
            facts.meshes = summary.meshInstances
            facts.triangles = summary.triangles
            facts.vertices = summary.vertices
            if summary.points > 0 { facts.points = summary.points }
            facts.materials = document.array("materials").count
            facts.textures = document.array("images").count
            facts.animations = document.array("animations").count
            facts.units = "m"
            if !summary.bounds.isEmpty { facts.size = summary.bounds.size.doubles }
            facts.generator = document.generator
            facts.version = document.version
            let used = Set(document.extensionsUsed)
            if used.contains("KHR_draco_mesh_compression") { facts.compression.append("Draco") }
            if used.contains("EXT_meshopt_compression") || used.contains("KHR_meshopt_compression") { facts.compression.append("Meshopt") }
            if used.contains("KHR_texture_basisu") { facts.compression.append("KTX2") }
            if used.contains("KHR_mesh_quantization") { facts.compression.append("Quantized") }
        case .stl:
            facts = readSTL(url, deadline: deadline)
        case .ply:
            facts = readPLY(url)
        case .obj:
            facts = readOBJ(url, deadline: deadline)
        case .off:
            facts = readOFF(url)
        case .threeMF:
            facts = readThreeMF(url, deadline: deadline)
        case .collada:
            facts = readCollada(url)
        case .fbx:
            facts = readFBXHeader(url)
        case .vox:
            facts = readVOX(url)
        case .las, .laz:
            guard let las = try? LASFile(url: url) else { break }
            facts.points = las.header.pointCount
            facts.version = "\(las.header.versionMajor).\(las.header.versionMinor)"
            if !las.header.software.isEmpty { facts.generator = las.header.software }
            if !las.units.geographic {
                let size = zip(las.header.minimum, las.header.maximum).map { $1 - $0 }
                if size.allSatisfy({ $0.isFinite && $0 >= 0 }) { facts.size = size }
                facts.units = las.units.horizontal
            }
        case .pcd:
            facts = readPCD(url)
        case .threeDS, .vrml, .amf:
            break
        }
        return facts
    }

    // MARK: - Mesh formats

    static func readSTL(_ url: URL, deadline: Date) -> ModelFacts {
        var facts = ModelFacts()
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return facts }
        if data.count >= 84 {
            let count = Int(data.u32(80))
            if 84 + count * 50 == data.count {
                facts.triangles = count
                facts.vertices = count * 3
                var bounds = Bounds()
                data.withUnsafeBytes { raw in
                    for index in 0..<count {
                        if index & 0xFFFF == 0, index > 0, Date() > deadline { bounds = Bounds(); return }
                        let base = 84 + index * 50 + 12
                        for corner in 0..<3 {
                            let at = base + corner * 12
                            bounds.add(SIMD3(Float(bitPattern: raw.loadUnaligned(fromByteOffset: at, as: UInt32.self).littleEndian),
                                             Float(bitPattern: raw.loadUnaligned(fromByteOffset: at + 4, as: UInt32.self).littleEndian),
                                             Float(bitPattern: raw.loadUnaligned(fromByteOffset: at + 8, as: UInt32.self).littleEndian)))
                        }
                    }
                }
                if !bounds.isEmpty { facts.size = bounds.size.doubles }
                return facts
            }
        }
        // ASCII: count facets, and measure smaller files.
        guard data.count <= scanLimit else { return facts }
        facts.triangles = count(Array("endfacet".utf8), in: data, deadline: deadline)
        if data.count <= measureLimit, let mesh = STLReader.load(url, budget: ModelBudget(deadline: deadline))?.meshes.first, Date() < deadline {
            var bounds = Bounds()
            for p in mesh.positions { bounds.add(p) }
            if !bounds.isEmpty { facts.size = bounds.size.doubles }
        }
        return facts
    }

    /// Text formats are measured by parsing them, which is only worth it below this size.
    static let measureLimit = 64 * 1024 * 1024

    static func readPLY(_ url: URL) -> ModelFacts {
        var facts = ModelFacts()
        let head = FileProbe(url: url, length: 64 * 1024).bytes
        guard let end = find(Array("end_header".utf8), in: head) else { return facts }
        let header = String(decoding: head[..<end], as: UTF8.self)
        var element = ""
        var properties = Set<String>()
        for line in header.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ").map(String.init)
            if parts.first == "element", parts.count >= 3 {
                element = parts[1]
                let count = Int(parts[2]) ?? 0
                if element == "vertex" { facts.vertices = count }
                if element == "face" { facts.faces = count }
            } else if parts.first == "property", element == "vertex", let name = parts.last {
                properties.insert(name)
            } else if parts.first == "comment", parts.count > 1, facts.generator == nil,
                      let generator = parts.dropFirst().joined(separator: " ").split(separator: ":", maxSplits: 1).last,
                      line.lowercased().contains("generated by") || line.lowercased().contains("created by") {
                facts.generator = generator.trimmingCharacters(in: .whitespaces)
            }
        }
        // 3D Gaussian splats are PLY point clouds with spherical-harmonic colours, opacity and scale.
        facts.isSplat = properties.contains("f_dc_0") && properties.contains("opacity") && properties.contains("scale_0")
        if (facts.faces ?? 0) == 0, let vertices = facts.vertices {
            facts.points = vertices
            facts.vertices = nil
            facts.faces = nil
        }
        return facts
    }

    static func readOBJ(_ url: URL, deadline: Date) -> ModelFacts {
        var facts = ModelFacts()
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped), data.count <= scanLimit else { return facts }
        var vertices = 0, triangles = 0, groups = 0
        var materials = Set<Int>()
        var complete = true
        var bounds = Bounds()
        let measure = data.count <= measureLimit
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: CChar.self) else { return }
            var index = 0
            var lines = 0
            let count = raw.count
            while index < count {
                lines += 1
                if lines & 0x3FFFF == 0, Date() > deadline { complete = false; return }
                // Skip leading blanks, read the keyword, then count the face's vertices.
                while index < count, raw[index] == 0x20 || raw[index] == 0x09 { index += 1 }
                let start = index
                if index + 1 < count, raw[index] == 0x76, raw[index + 1] == 0x20 || raw[index + 1] == 0x09 {   // "v "
                    vertices += 1
                    // strtof needs a terminator ahead and must not run onto the next line.
                    if measure, let newline = memchr(base + index, 0x0A, count - index) {
                        let lineEnd = UnsafePointer(newline.assumingMemoryBound(to: CChar.self))
                        var cursor = UnsafeMutablePointer(mutating: base + index + 1)
                        var xyz = SIMD3<Float>()
                        var parsed = 0
                        for axis in 0..<3 {
                            var end: UnsafeMutablePointer<CChar>?
                            let value = strtof(cursor, &end)
                            guard let end, end != cursor, end <= lineEnd else { break }
                            xyz[axis] = value
                            cursor = end
                            parsed += 1
                        }
                        if parsed == 3 { bounds.add(xyz) }
                    }
                } else if index + 1 < count, raw[index] == 0x66, raw[index + 1] == 0x20 || raw[index + 1] == 0x09 {   // "f "
                    var corners = 0
                    var inToken = false
                    var cursor = index + 1
                    while cursor < count, raw[cursor] != 0x0A, raw[cursor] != 0x0D {
                        let isSpace = raw[cursor] == 0x20 || raw[cursor] == 0x09
                        if !isSpace && !inToken { corners += 1 }
                        inToken = !isSpace
                        cursor += 1
                    }
                    if corners >= 3 { triangles += corners - 2 }
                    index = cursor
                } else if index + 6 < count, raw[index] == 0x75, raw[index + 1] == 0x73, raw[index + 2] == 0x65,
                          raw[index + 3] == 0x6D, raw[index + 4] == 0x74, raw[index + 5] == 0x6C {   // "usemtl"
                    var hash = 5381
                    var cursor = index + 6
                    while cursor < count, raw[cursor] != 0x0A, raw[cursor] != 0x0D {
                        hash = (hash &* 33) &+ Int(raw[cursor])
                        cursor += 1
                    }
                    materials.insert(hash)
                    index = cursor
                } else if index + 1 < count, raw[index] == 0x6F || raw[index] == 0x67, raw[index + 1] == 0x20 {   // "o " / "g "
                    groups += 1
                }
                _ = start
                while index < count, raw[index] != 0x0A { index += 1 }
                index += 1
            }
        }
        guard complete else { return facts }
        facts.vertices = vertices
        facts.triangles = triangles
        if !bounds.isEmpty { facts.size = bounds.size.doubles }
        if !materials.isEmpty { facts.materials = materials.count }
        if groups > 0 { facts.meshes = groups }
        return facts
    }

    static func readOFF(_ url: URL) -> ModelFacts {
        var facts = ModelFacts()
        let text = String(decoding: FileProbe(url: url, length: 4096).bytes, as: UTF8.self)
        var numbers: [Int] = []
        var sawKeyword = false
        for line in text.split(whereSeparator: \.isNewline) {
            let content = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            var words = content.split(whereSeparator: \.isWhitespace)
            if !sawKeyword, let first = words.first, first.hasSuffix("OFF") { sawKeyword = true; words.removeFirst() }
            numbers += words.compactMap { Int($0) }
            if numbers.count >= 3 { break }
        }
        if numbers.count >= 2 { facts.vertices = numbers[0]; facts.faces = numbers[1] }
        return facts
    }

    static func readThreeMF(_ url: URL, deadline: Date) -> ModelFacts {
        var facts = ModelFacts()
        guard let package = try? ZipMembers(url: url) else { return facts }
        let modelEntry = ThreeMFPackage.rootModelPath(in: package).flatMap { package.entry(named: $0) }
            ?? package.entries.first { $0.name.lowercased().hasSuffix(".model") }
        guard let modelEntry, let xml = package.contents(of: modelEntry, limit: scanLimit) else { return facts }
        facts.vertices = count(Array("<vertex ".utf8), in: xml, deadline: deadline)
        facts.triangles = count(Array("<triangle ".utf8), in: xml, deadline: deadline)
        facts.meshes = count(Array("<mesh".utf8), in: xml, deadline: deadline)
        // Build transforms and components place the parts, so measure the assembled model.
        if xml.count <= measureLimit, let scene = ThreeMFPackage.load(url, budget: ModelBudget(deadline: deadline)), Date() < deadline {
            let bounds = scene.bounds
            if !bounds.isEmpty { facts.size = bounds.size.doubles }
        }
        let materials = count(Array("<base ".utf8), in: xml, deadline: deadline) ?? 0
        let colors = count(Array("<color ".utf8), in: xml, deadline: deadline) ?? 0
        if materials + colors > 0 { facts.materials = materials + colors }
        let head = String(decoding: xml.prefix(4096), as: UTF8.self)
        facts.units = ThreeMFPackage.unitSymbol(head)
        if let application = ThreeMFPackage.metadata("Application", in: String(decoding: xml.prefix(16_384), as: UTF8.self)) {
            facts.generator = application
        }
        return facts
    }

    static func readCollada(_ url: URL) -> ModelFacts {
        var facts = ModelFacts()
        let head = String(decoding: FileProbe(url: url, length: 16 * 1024).bytes, as: UTF8.self)
        if let range = head.range(of: "<unit"), let end = head[range.upperBound...].firstIndex(of: ">") {
            let tag = head[range.lowerBound...end]
            let meter = attribute("meter", in: tag).flatMap(Double.init)
            facts.units = meter.flatMap(unitSymbol(metres:))
        } else {
            facts.units = "m"
        }
        if let tool = head.range(of: "<authoring_tool>"), let end = head[tool.upperBound...].range(of: "</authoring_tool>") {
            facts.generator = String(head[tool.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return facts
    }

    static func readFBXHeader(_ url: URL) -> ModelFacts {
        var facts = ModelFacts()
        let head = FileProbe(url: url, length: 64).bytes
        if head.count >= 27, Array(head.prefix(18)) == Array("Kaydara FBX Binary".utf8) {
            let version = Int(head[23]) | Int(head[24]) << 8 | Int(head[25]) << 16 | Int(head[26]) << 24
            facts.version = "\(version / 1000).\(version % 1000 / 100)"
        } else {
            let text = String(decoding: FileProbe(url: url, length: 4096).bytes, as: UTF8.self)
            if let range = text.range(of: "FBXVersion:") {
                let digits = text[range.upperBound...].drop { $0 == " " }.prefix { $0.isNumber }
                if let version = Int(digits) { facts.version = "\(version / 1000).\(version % 1000 / 100)" }
            }
        }
        return facts
    }

    static func readVOX(_ url: URL) -> ModelFacts {
        var facts = ModelFacts()
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped), data.count >= 20 else { return facts }
        // Chunks: id, content size, children size. SIZE gives the grid; XYZI the voxel count.
        var offset = 8
        var models = 0, voxels = 0
        var steps = 0
        while offset + 12 <= data.count, steps < 100_000 {
            steps += 1
            let id = String(decoding: data.subdata(in: offset..<(offset + 4)), as: UTF8.self)
            let content = Int(data.u32(offset + 4))
            if id == "MAIN" { offset += 12; continue }
            if id == "SIZE", offset + 24 <= data.count, models == 0 {
                facts.size = [Double(data.u32(offset + 12)), Double(data.u32(offset + 16)), Double(data.u32(offset + 20))]
            }
            if id == "XYZI", offset + 16 <= data.count { models += 1; voxels = voxels.addingClamped(Int(data.u32(offset + 12))) }
            let children = Int(data.u32(offset + 8))
            guard content >= 0, children >= 0, content <= data.count, children <= data.count else { break }
            offset += 12 + content + children
        }
        if models > 0 { facts.meshes = models }
        if voxels > 0 { facts.voxels = voxels }
        return facts
    }

    static func readPCD(_ url: URL) -> ModelFacts {
        var facts = ModelFacts()
        let text = String(decoding: FileProbe(url: url, length: 4096).bytes, as: UTF8.self)
        for line in text.split(whereSeparator: \.isNewline).prefix(20) {
            let parts = line.split(separator: " ")
            if parts.first == "POINTS", parts.count > 1 { facts.points = Int(parts[1]) }
            if parts.first == "VERSION", parts.count > 1 { facts.version = String(parts[1]) }
            if parts.first == "DATA" { break }
        }
        return facts
    }

    // MARK: - Helpers

    static func unitSymbol(metres: Double) -> String? {
        let known: [(Double, String)] = [(1, "m"), (0.01, "cm"), (0.001, "mm"), (0.0254, "in"), (0.3048, "ft"), (1e-6, "µm"), (1000, "km")]
        return known.first { abs($0.0 - metres) / metres < 0.001 }?.1
    }

    static func attribute(_ name: String, in tag: Substring) -> String? {
        for quote in ["\"", "'"] {
            if let range = tag.range(of: name + "=" + quote), let end = tag[range.upperBound...].firstIndex(of: Character(quote)) {
                return String(tag[range.upperBound..<end])
            }
        }
        return nil
    }

    static func find(_ needle: [UInt8], in haystack: [UInt8]) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        outer: for start in 0...(haystack.count - needle.count) {
            for (offset, byte) in needle.enumerated() where haystack[start + offset] != byte { continue outer }
            return start
        }
        return nil
    }

    /// Occurrences of `needle`, or nil if the deadline passed first.
    static func count(_ needle: [UInt8], in data: Data, deadline: Date) -> Int? {
        guard let first = needle.first, data.count >= needle.count else { return 0 }
        var total = 0
        var timedOut = false
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            var index = 0
            let end = raw.count - needle.count
            var checks = 0
            while index <= end {
                // memchr finds candidates quickly; then compare the rest.
                guard let hit = memchr(base + index, Int32(first), end - index + 1) else { break }
                let position = base.distance(to: hit.assumingMemoryBound(to: UInt8.self))
                if memcmp(base + position, needle, needle.count) == 0 { total += 1 }
                index = position + 1
                checks += 1
                if checks & 0xFFFF == 0, Date() > deadline { timedOut = true; return }
            }
        }
        return timedOut ? nil : total
    }

    // MARK: - Presentation

    /// Info bar facts, most telling first.
    func details(format: ModelFormat) -> [String] {
        var details: [String] = []
        func plural(_ count: Int, _ one: String, _ many: String) -> String { "\(count.formatted()) \(count == 1 ? one : many)" }
        if let points, points > 0 { details.append(plural(points, isSplat ? "splat" : "point", isSplat ? "splats" : "points")) }
        if let triangles, triangles > 0 { details.append(plural(triangles, "triangle", "triangles")) }
        else if let faces, faces > 0 { details.append(plural(faces, "face", "faces")) }
        if let voxels, voxels > 0 { details.append(plural(voxels, "voxel", "voxels")) }
        if let materials, materials > 1 { details.append(plural(materials, "material", "materials")) }
        if let animations, animations > 0 { details.append(plural(animations, "animation", "animations")) }
        if let size, size.count == 3 {
            // Width × depth × height, whichever axis the format calls up.
            let ordered = format.isZUp ? size : [size[0], size[2], size[1]]
            if let text = Self.dimensions(ordered, units: format == .vox ? "voxels" : units) { details.append(text) }
        }
        return details
    }

    /// "24.3 × 18 × 9.1 cm": metric sizes in the unit that reads best, others as stored.
    static func dimensions(_ size: [Double], units: String?) -> String? {
        guard size.count == 3, size.allSatisfy({ $0.isFinite && $0 >= 0 }), size.contains(where: { $0 > 0 }) else { return nil }
        var values = size
        var unit = units
        if units == "m" {
            let largest = size.max() ?? 0
            if largest < 0.01 { values = size.map { $0 * 1000 }; unit = "mm" }
            else if largest < 1 { values = size.map { $0 * 100 }; unit = "cm" }
        }
        let largest = values.max() ?? 0
        let text = values.map { formatLength($0, largest: largest) }.joined(separator: " × ")
        return unit.map { "\(text) \($0)" } ?? text
    }

    static func formatLength(_ value: Double, largest: Double) -> String {
        let digits = largest >= 1000 ? 0 : largest >= 100 ? 1 : 2
        return value.formatted(.number.precision(.fractionLength(0...digits)))
    }
}

extension SIMD3 where Scalar == Float {
    var doubles: [Double] { [Double(x), Double(y), Double(z)] }
}
