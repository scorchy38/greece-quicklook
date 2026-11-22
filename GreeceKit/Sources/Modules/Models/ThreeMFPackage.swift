import Foundation
import CoreGraphics
import simd

/// A tag streamed by `XMLTagScanner`: its local name (without namespace prefix) and attributes,
/// read straight from the document's bytes.
struct XMLTag {
    fileprivate let bytes: UnsafeBufferPointer<UInt8>
    fileprivate let nameRange: Range<Int>
    fileprivate var attributeRanges: [(key: Range<Int>, local: Range<Int>, value: Range<Int>)]
    let isClosing: Bool
    let isSelfClosing: Bool

    var name: String { String(decoding: UnsafeBufferPointer(rebasing: bytes[nameRange]), as: UTF8.self) }

    func nameIs(_ candidate: String) -> Bool { equal(nameRange, candidate) }

    /// An attribute by its full name (`p:path`) or by its local name (`path`).
    func attribute(_ key: String) -> String? {
        guard let range = valueRange(key) else { return nil }
        return String(decoding: UnsafeBufferPointer(rebasing: bytes[range]), as: UTF8.self)
    }

    func float(_ key: String) -> Float? {
        guard let range = valueRange(key), !range.isEmpty, range.count < 64 else { return nil }
        var buffer = [CChar](repeating: 0, count: range.count + 1)
        for (i, byte) in bytes[range].enumerated() { buffer[i] = CChar(bitPattern: byte) }
        let value = buffer.withUnsafeMutableBufferPointer { strtof($0.baseAddress!, nil) }
        return value.isFinite ? value : nil
    }

    func uint(_ key: String) -> UInt32? {
        guard let range = valueRange(key), !range.isEmpty, range.count <= 10 else { return nil }
        var value: UInt64 = 0
        for byte in bytes[range] {
            guard byte >= 0x30 && byte <= 0x39 else { return nil }
            value = value * 10 + UInt64(byte - 0x30)
        }
        return value <= UInt64(UInt32.max) ? UInt32(value) : nil
    }

    private func valueRange(_ key: String) -> Range<Int>? {
        let qualified = key.contains(":")
        for attribute in attributeRanges where equal(qualified ? attribute.key : attribute.local, key) { return attribute.value }
        return nil
    }

    private func equal(_ range: Range<Int>, _ string: String) -> Bool {
        var utf8 = string.utf8.makeIterator()
        for index in range { guard utf8.next() == bytes[index] else { return false } }
        return utf8.next() == nil
    }
}

/// Streams the tags of an XML document. Enough for 3MF's flat, attribute-heavy markup, and far
/// faster than building a DOM. Comments, processing instructions and text are skipped.
enum XMLTagScanner {
    static func scan(_ data: Data, _ visit: (XMLTag) -> Bool) {
        data.withUnsafeBytes { raw in scan(raw.bindMemory(to: UInt8.self), visit) }
    }

    static func scan(_ text: String, _ visit: (XMLTag) -> Bool) {
        scan(Data(text.utf8), visit)
    }

    /// Calls `visit` for every start, end and empty tag; returning false stops the scan.
    static func scan(_ bytes: UnsafeBufferPointer<UInt8>, _ visit: (XMLTag) -> Bool) {
        guard let base = bytes.baseAddress else { return }
        let count = bytes.count
        var index = 0
        func isSpace(_ byte: UInt8) -> Bool { byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D }
        while index < count {
            guard let hit = memchr(base + index, 0x3C, count - index) else { return }   // "<"
            let open = base.distance(to: hit.assumingMemoryBound(to: UInt8.self))
            guard let closeHit = memchr(base + open, 0x3E, count - open) else { return }   // ">"
            let close = base.distance(to: closeHit.assumingMemoryBound(to: UInt8.self))
            index = close + 1
            var cursor = open + 1
            guard cursor < close else { continue }
            let first = bytes[cursor]
            if first == 0x3F || first == 0x21 { continue }   // "<?" and "<!"
            let isClosing = first == 0x2F
            if isClosing { cursor += 1 }
            let isSelfClosing = close - 1 > open && bytes[close - 1] == 0x2F
            let end = isSelfClosing ? close - 1 : close
            var localStart = cursor
            while cursor < end, !isSpace(bytes[cursor]) {
                if bytes[cursor] == 0x3A { localStart = cursor + 1 }
                cursor += 1
            }
            var tag = XMLTag(bytes: bytes, nameRange: localStart..<cursor, attributeRanges: [], isClosing: isClosing, isSelfClosing: isSelfClosing)
            while cursor < end {
                while cursor < end, isSpace(bytes[cursor]) { cursor += 1 }
                let keyStart = cursor
                var keyLocal = cursor
                while cursor < end, bytes[cursor] != 0x3D, !isSpace(bytes[cursor]) {
                    if bytes[cursor] == 0x3A { keyLocal = cursor + 1 }
                    cursor += 1
                }
                let keyEnd = cursor
                while cursor < end, isSpace(bytes[cursor]) { cursor += 1 }
                guard cursor < end, bytes[cursor] == 0x3D else { break }
                cursor += 1
                while cursor < end, isSpace(bytes[cursor]) { cursor += 1 }
                guard cursor < end, bytes[cursor] == 0x22 || bytes[cursor] == 0x27 else { break }
                let quote = bytes[cursor]
                cursor += 1
                let valueStart = cursor
                while cursor < end, bytes[cursor] != quote { cursor += 1 }
                guard cursor < end else { break }
                tag.attributeRanges.append((keyStart..<keyEnd, keyLocal..<keyEnd, valueStart..<cursor))
                cursor += 1
            }
            if !visit(tag) { return }
        }
    }
}

/// A 3MF package: the root model part, its units, metadata, and geometry (including the
/// production extension's components that live in other parts, as Bambu and Prusa write them).
enum ThreeMFPackage {

    static func rootModelPath(in package: ZipMembers) -> String? {
        guard let rels = package.entry(named: "_rels/.rels"), let data = package.contents(of: rels, limit: 1024 * 1024) else { return nil }
        var target: String?
        XMLTagScanner.scan(data) { tag in
            if tag.nameIs("Relationship"), let type = tag.attribute("Type"), type.hasSuffix("/3dmodel"), let value = tag.attribute("Target") {
                target = value
                return false
            }
            return true
        }
        return target
    }

    /// The `<model unit="…">` attribute as a symbol; millimetres when absent (the 3MF default).
    static func unitSymbol(_ head: String) -> String {
        var unit = "millimeter"
        XMLTagScanner.scan(head) { tag in
            if tag.nameIs("model") {
                if let value = tag.attribute("unit") { unit = value }
                return false
            }
            return true
        }
        switch unit.lowercased() {
        case "micron": return "µm"
        case "centimeter": return "cm"
        case "inch": return "in"
        case "foot": return "ft"
        case "meter": return "m"
        default: return "mm"
        }
    }

    static func metadata(_ name: String, in xml: String) -> String? {
        guard let range = xml.range(of: "name=\"\(name)\""),
              let open = xml[range.upperBound...].firstIndex(of: ">"),
              let close = xml[open...].range(of: "</") else { return nil }
        let value = xml[xml.index(after: open)..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : String(value.prefix(80))
    }

    // MARK: - Geometry

    private struct Object {
        var positions: [SIMD3<Float>] = []
        var triangles: [UInt32] = []
        var triangleColors: [SIMD4<Float>?] = []
        var components: [(path: String?, id: String, transform: simd_float4x4)] = []
        var color: SIMD4<Float>?
    }

    private struct Part {
        var objects: [String: Object] = [:]
        var build: [(id: String, transform: simd_float4x4)] = []
    }

    static func load(_ url: URL, budget: ModelBudget) -> ModelScene? {
        guard let package = try? ZipMembers(url: url) else { return nil }
        let rootPath = rootModelPath(in: package) ?? package.entries.first { $0.name.lowercased().hasSuffix(".model") }?.name
        guard let rootPath else { return nil }
        var parts: [String: Part] = [:]
        var triangleBudget = budget.triangles

        func key(_ path: String) -> String { "/" + path.drop { $0 == "/" } }
        func part(_ path: String) -> Part? {
            if let cached = parts[key(path)] { return cached }
            guard parts.count < 512, let entry = package.entry(named: path), let data = package.contents(of: entry, limit: budget.fileBytes) else { return nil }
            let parsed = parse(data, triangleBudget: &triangleBudget, budget: budget)
            parts[key(path)] = parsed
            return parsed
        }

        guard let root = part(rootPath) else { return nil }
        var scene = ModelScene(zUp: true)
        var emitted = 0

        func emit(_ id: String, in path: String, transform: simd_float4x4, depth: Int) {
            guard depth < 16, emitted < 50_000, !budget.expired, let owner = part(path), let object = owner.objects[id] else { return }
            if !object.triangles.isEmpty {
                emitted += 1
                var mesh = ModelMesh()
                // Flat-shaded: each triangle gets its own corners, so per-triangle colours stay crisp.
                let hasColors = object.triangleColors.contains { $0 != nil }
                mesh.positions.reserveCapacity(object.triangles.count)
                mesh.indices.reserveCapacity(object.triangles.count)
                for (t, triangle) in Swift.stride(from: 0, to: object.triangles.count - 2, by: 3).enumerated() {
                    let a = Int(object.triangles[triangle]), b = Int(object.triangles[triangle + 1]), c = Int(object.triangles[triangle + 2])
                    guard a < object.positions.count, b < object.positions.count, c < object.positions.count else { continue }
                    let base = UInt32(mesh.positions.count)
                    mesh.positions += [object.positions[a], object.positions[b], object.positions[c]]
                    mesh.indices += [base, base + 1, base + 2]
                    if hasColors {
                        let color = (t < object.triangleColors.count ? object.triangleColors[t] : nil) ?? object.color ?? SIMD4(0.8, 0.8, 0.8, 1)
                        mesh.colors += [color, color, color]
                    }
                }
                if !hasColors, let color = object.color { mesh.material.baseColor = color }
                mesh.material.roughness = 0.5
                mesh.apply(transform)
                mesh.computeNormals()
                scene.meshes.append(mesh)
            }
            for component in object.components {
                emit(component.id, in: component.path ?? path, transform: transform * component.transform, depth: depth + 1)
            }
        }

        let items = root.build.isEmpty ? root.objects.keys.sorted().map { (id: $0, transform: matrix_identity_float4x4) } : root.build
        for item in items { emit(item.id, in: rootPath, transform: item.transform, depth: 0) }
        return scene.isEmpty ? nil : scene
    }

    /// One model part: objects (meshes or components), colours and build items.
    private static func parse(_ xml: Data, triangleBudget: inout Int, budget: ModelBudget) -> Part {
        var part = Part()
        var materials: [String: [SIMD4<Float>]] = [:]
        var currentGroup: String?
        var currentID: String?
        var current = Object()
        var steps = 0
        var budgetLeft = triangleBudget
        let fallback = SIMD4<Float>(0.8, 0.8, 0.8, 1)

        XMLTagScanner.scan(xml) { tag in
            steps += 1
            if steps & 0x3FFF == 0, budget.expired { return false }
            if tag.isClosing {
                if tag.nameIs("object"), let id = currentID { part.objects[id] = current; currentID = nil }
                return true
            }
            if tag.nameIs("vertex") {
                guard currentID != nil else { return true }
                current.positions.append(SIMD3(tag.float("x") ?? 0, tag.float("y") ?? 0, tag.float("z") ?? 0))
            } else if tag.nameIs("triangle") {
                guard currentID != nil, budgetLeft > 0, let v1 = tag.uint("v1"), let v2 = tag.uint("v2"), let v3 = tag.uint("v3") else { return true }
                budgetLeft -= 1
                current.triangles += [v1, v2, v3]
                var triangleColor: SIMD4<Float>?
                if let pid = tag.attribute("pid"), let group = materials[pid] {
                    let index = Int(tag.uint("p1") ?? 0)
                    triangleColor = group.indices.contains(index) ? group[index] : nil
                }
                current.triangleColors.append(triangleColor)
            } else if tag.nameIs("basematerials") || tag.nameIs("colorgroup") {
                currentGroup = tag.attribute("id")
                if let id = currentGroup { materials[id] = [] }
            } else if tag.nameIs("base") {
                if let id = currentGroup { materials[id, default: []].append(color(tag.attribute("displaycolor")) ?? fallback) }
            } else if tag.nameIs("color") {
                if let id = currentGroup { materials[id, default: []].append(color(tag.attribute("color")) ?? fallback) }
            } else if tag.nameIs("object") {
                current = Object()
                if let pid = tag.attribute("pid"), let group = materials[pid] {
                    let index = Int(tag.uint("pindex") ?? 0)
                    current.color = group.indices.contains(index) ? group[index] : group.first
                }
                currentID = tag.attribute("id") ?? ""
                if tag.isSelfClosing, let id = currentID { part.objects[id] = current; currentID = nil }
            } else if tag.nameIs("component") {
                guard currentID != nil, let id = tag.attribute("objectid") else { return true }
                current.components.append((tag.attribute("p:path") ?? tag.attribute("path"), id, matrix(tag.attribute("transform"))))
            } else if tag.nameIs("item") {
                if let id = tag.attribute("objectid") { part.build.append((id, matrix(tag.attribute("transform")))) }
            }
            return true
        }
        triangleBudget = budgetLeft
        return part
    }

    /// "m00 m01 m02 m10 m11 m12 m20 m21 m22 m30 m31 m32": a row-vector affine transform.
    static func matrix(_ value: String?) -> simd_float4x4 {
        guard let numbers = value?.split(whereSeparator: \.isWhitespace).compactMap({ Float($0) }), numbers.count == 12,
              numbers.allSatisfy(\.isFinite) else { return matrix_identity_float4x4 }
        return simd_float4x4(columns: (SIMD4(numbers[0], numbers[1], numbers[2], 0),
                                       SIMD4(numbers[3], numbers[4], numbers[5], 0),
                                       SIMD4(numbers[6], numbers[7], numbers[8], 0),
                                       SIMD4(numbers[9], numbers[10], numbers[11], 1)))
    }

    /// "#RRGGBB" or "#RRGGBBAA" in sRGB.
    static func color(_ value: String?) -> SIMD4<Float>? {
        guard var hex = value?.trimmingCharacters(in: .whitespaces), hex.hasPrefix("#") else { return nil }
        hex.removeFirst()
        guard hex.count == 6 || hex.count == 8, let number = UInt32(hex, radix: 16) else { return nil }
        let rgba = hex.count == 6 ? (number << 8) | 0xFF : number
        return SIMD4(Float((rgba >> 24) & 0xFF) / 255, Float((rgba >> 16) & 0xFF) / 255, Float((rgba >> 8) & 0xFF) / 255, Float(rgba & 0xFF) / 255)
    }
}
