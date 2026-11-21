import Foundation

/// A typed attribute value from a compiled Android XML file (binary AXML or aapt2 protobuf).
enum AndroidValue: Equatable {
    case string(String)
    /// A resource reference, `@0x7f0e0000`.
    case reference(UInt32)
    /// A theme attribute reference, `?0x01010000`.
    case attribute(UInt32)
    case int(Int64)
    case bool(Bool)
    case float(Double)
    case color(UInt32)
    case other(String)
    case null

    var string: String? {
        switch self {
        case .string(let value): return value
        case .int(let value): return String(value)
        case .bool(let value): return value ? "true" : "false"
        case .float(let value): return String(value)
        case .other(let value): return value
        default: return nil
        }
    }

    var int: Int? {
        switch self {
        case .int(let value): return Int(exactly: value)
        case .string(let value): return Int(value.trimmingCharacters(in: .whitespaces))
        case .float(let value): return value.isFinite && abs(value) < 1e9 ? Int(value) : nil
        default: return nil
        }
    }

    var bool: Bool? {
        switch self {
        case .bool(let value): return value
        case .int(let value): return value != 0
        case .string(let value):
            switch value.lowercased() {
            case "true": return true
            case "false": return false
            default: return nil
            }
        default: return nil
        }
    }

}

struct AndroidXMLAttribute: Equatable {
    var namespace: String?
    var name: String
    /// The framework attribute ID (`android:name` is 0x01010003). Authoritative when present:
    /// obfuscated manifests can rename or blank the attribute's string.
    var resourceID: UInt32?
    var value: AndroidValue
}

/// An element of a compiled Android XML document.
final class AndroidXMLElement {
    let name: String
    var attributes: [AndroidXMLAttribute]
    var children: [AndroidXMLElement] = []

    init(name: String, attributes: [AndroidXMLAttribute]) {
        self.name = name
        self.attributes = attributes
    }

    /// Well-known framework attribute IDs, so lookups survive obfuscated attribute names.
    static let attributeIDs: [String: UInt32] = [
        "theme": 0x0101_0000, "label": 0x0101_0001, "icon": 0x0101_0002, "name": 0x0101_0003,
        "permission": 0x0101_0006, "protectionLevel": 0x0101_0009, "hasCode": 0x0101_000c,
        "enabled": 0x0101_000e, "debuggable": 0x0101_000f, "exported": 0x0101_0010,
        "authorities": 0x0101_0018, "scheme": 0x0101_0027, "host": 0x0101_0028, "port": 0x0101_0029,
        "path": 0x0101_002a, "pathPrefix": 0x0101_002b, "pathPattern": 0x0101_002c, "mimeType": 0x0101_0026,
        "value": 0x0101_0024, "resource": 0x0101_0025,
        "minSdkVersion": 0x0101_020c, "versionCode": 0x0101_021b, "versionName": 0x0101_021c,
        "targetSdkVersion": 0x0101_0270, "maxSdkVersion": 0x0101_0271, "testOnly": 0x0101_0272,
        "allowBackup": 0x0101_0280, "glEsVersion": 0x0101_0281, "required": 0x0101_028e,
        "largeHeap": 0x0101_035a, "extractNativeLibs": 0x0101_04ea, "usesCleartextTraffic": 0x0101_04ec,
        "networkSecurityConfig": 0x0101_0527, "roundIcon": 0x0101_052c,
        "compileSdkVersion": 0x0101_0572, "compileSdkVersionCodename": 0x0101_0573,
        "appComponentFactory": 0x0101_057a, "requestLegacyExternalStorage": 0x0101_0603,
        "drawable": 0x0101_0199, "autoVerify": 0x0101_04ee,
    ]

    /// An attribute by its local name: matched on the framework ID first, then on the name.
    func attribute(_ name: String) -> AndroidValue? {
        if let id = Self.attributeIDs[name], let match = attributes.first(where: { $0.resourceID == id }) { return match.value }
        return attributes.first { $0.name == name && ($0.resourceID == nil || $0.resourceID == 0 || Self.attributeIDs[name] == nil) }?.value
    }

    func string(_ name: String) -> String? { attribute(name)?.string }

    func children(named name: String) -> [AndroidXMLElement] { children.filter { $0.name == name } }
}

enum AndroidXMLError: Error, Equatable { case notXML, corrupt, tooLarge }

/// Limits applied to every compiled XML document.
enum AndroidXMLLimits {
    static let maxElements = 50_000
    static let maxDepth = 64
    static let maxAttributes = 256
    static let maxStrings = 500_000
    static let maxStringLength = 64 * 1024
}

// MARK: - String pools

/// A ResStringPool chunk (shared by AXML and resources.arsc). Strings decode lazily and are cached.
final class AndroidStringPool {
    private let data: Data
    private let chunkStart: Int
    private let stringsStart: Int
    private let chunkEnd: Int
    private let offsets: [UInt32]
    private let utf8: Bool
    private var cache: [Int: String] = [:]

    var count: Int { offsets.count }

    /// `data` is the whole file; `chunk` is the offset of the pool's chunk header.
    init?(data: Data, chunk: Int) {
        let reader = BinaryReader(data)
        guard reader.u16(at: chunk) == 0x0001, let headerSize = reader.u16(at: chunk + 2).map(Int.init),
              let size = reader.u32(at: chunk + 4).map(Int.init), headerSize >= 28, size >= headerSize,
              reader.has(size, at: chunk),
              let stringCount = reader.u32(at: chunk + 8).map(Int.init),
              let flags = reader.u32(at: chunk + 16), let start = reader.u32(at: chunk + 20).map(Int.init) else { return nil }
        guard stringCount <= AndroidXMLLimits.maxStrings, headerSize + stringCount * 4 <= size else { return nil }
        self.data = reader.data
        chunkStart = chunk
        chunkEnd = chunk + size
        stringsStart = chunk + start
        utf8 = flags & 0x100 != 0
        var offsets: [UInt32] = []
        offsets.reserveCapacity(stringCount)
        for index in 0..<stringCount {
            offsets.append(reader.u32(at: chunk + headerSize + index * 4) ?? 0)
        }
        self.offsets = offsets
    }

    subscript(index: Int) -> String? { string(at: index) }

    func string(at index: Int) -> String? {
        guard index >= 0, index < offsets.count else { return nil }
        if let cached = cache[index] { return cached }
        let position = stringsStart + Int(offsets[index])
        guard position >= chunkStart, position < chunkEnd else { return nil }
        let reader = BinaryReader(data)
        var value: String?
        if utf8 {
            // UTF-16 length (1–2 bytes), then UTF-8 length (1–2 bytes), then bytes.
            var cursor = position
            func length() -> Int? {
                guard let first = reader.u8(at: cursor) else { return nil }
                cursor += 1
                if first & 0x80 != 0 {
                    guard let second = reader.u8(at: cursor) else { return nil }
                    cursor += 1
                    return (Int(first & 0x7F) << 8) | Int(second)
                }
                return Int(first)
            }
            guard length() != nil, let byteCount = length() else { return nil }
            let bounded = min(byteCount, AndroidXMLLimits.maxStringLength, max(0, chunkEnd - cursor))
            if let bytes = reader.bytes(at: cursor, count: bounded) {
                value = String(data: bytes, encoding: .utf8) ?? String(decoding: bytes, as: UTF8.self)
            }
        } else {
            var cursor = position
            guard let first = reader.u16(at: cursor) else { return nil }
            cursor += 2
            var units = Int(first)
            if first & 0x8000 != 0 {
                guard let second = reader.u16(at: cursor) else { return nil }
                cursor += 2
                units = (Int(first & 0x7FFF) << 16) | Int(second)
            }
            let bounded = min(units, AndroidXMLLimits.maxStringLength, max(0, (chunkEnd - cursor) / 2))
            var scalars: [UInt16] = []
            scalars.reserveCapacity(bounded)
            for unit in 0..<bounded { scalars.append(reader.u16(at: cursor + unit * 2) ?? 0) }
            value = String(decoding: scalars, as: UTF16.self)
        }
        if let value, cache.count < 100_000 { cache[index] = value }
        return value
    }
}

// MARK: - Res_value

enum AndroidResValue {
    /// Decodes a Res_value's type and data. Strings index into `pool`.
    static func decode(type: UInt8, data: UInt32, pool: AndroidStringPool?) -> AndroidValue {
        switch type {
        case 0x00: return .null
        case 0x01, 0x07: return data == 0 ? .null : .reference(data)
        case 0x02, 0x08: return .attribute(data)
        case 0x03: return pool?.string(at: Int(data)).map(AndroidValue.string) ?? .null
        case 0x04: return .float(Double(Float(bitPattern: data)))
        case 0x05: return .other(dimension(data))
        case 0x06: return .other(String(format: "%.2f%%", Double(Int32(bitPattern: data & 0xFFFF_FF00)) / Double(1 << 23) * 100))
        case 0x10: return .int(Int64(Int32(bitPattern: data)))
        case 0x11: return .int(Int64(data))
        case 0x12: return .bool(data != 0)
        case 0x1c...0x1f: return .color(data)
        default: return .other(String(format: "0x%08x", data))
        }
    }

    private static func dimension(_ data: UInt32) -> String {
        let units = ["px", "dp", "sp", "pt", "in", "mm"]
        let radix: [Double] = [1, 1.0 / 128, 1.0 / 32768, 1.0 / 8_388_608]
        let mantissa = Double(Int32(bitPattern: data & 0xFFFF_FF00) >> 8)
        let value = mantissa * radix[Int((data >> 4) & 0x3)]
        let unit = Int(data & 0xF)
        return String(format: "%g", value) + (unit < units.count ? units[unit] : "")
    }
}

// MARK: - Binary XML (AXML)

enum AndroidBinaryXML {
    /// Parses a binary AndroidManifest.xml (or any compiled resource XML) into its root element.
    static func parse(_ input: Data, deadline: Date = Date().addingTimeInterval(1)) throws -> AndroidXMLElement {
        let reader = BinaryReader(input)
        let data = reader.data
        guard reader.u16(at: 0) == 0x0003, let headerSize = reader.u16(at: 2).map(Int.init), headerSize >= 8 else {
            throw AndroidXMLError.notXML
        }
        let declared = Int(reader.u32(at: 4) ?? 0)
        let end = min(data.count, declared > 0 ? declared : data.count)
        var pool: AndroidStringPool?
        var resourceMap: [UInt32] = []
        var stack: [AndroidXMLElement] = []
        var root: AndroidXMLElement?
        var elements = 0
        var offset = headerSize

        while offset + 8 <= end {
            guard let type = reader.u16(at: offset), let chunkHeader = reader.u16(at: offset + 2).map(Int.init),
                  let size = reader.u32(at: offset + 4).map(Int.init), size >= 8, chunkHeader <= size, size <= end - offset else {
                break
            }
            if Date() > deadline { throw AndroidXMLError.tooLarge }
            switch type {
            case 0x0001:
                if pool == nil { pool = AndroidStringPool(data: data, chunk: offset) }
            case 0x0180:
                let count = min((size - chunkHeader) / 4, 10_000)
                resourceMap = (0..<count).map { reader.u32(at: offset + chunkHeader + $0 * 4) ?? 0 }
            case 0x0102:
                elements += 1
                guard elements <= AndroidXMLLimits.maxElements else { throw AndroidXMLError.tooLarge }
                let ext = offset + chunkHeader
                guard let nameIndex = reader.u32(at: ext + 4),
                      let attributeStart = reader.u16(at: ext + 8).map(Int.init),
                      let attributeSize = reader.u16(at: ext + 10).map(Int.init),
                      let attributeCount = reader.u16(at: ext + 12).map(Int.init) else { break }
                let name = pool?.string(at: Int(nameIndex)) ?? ""
                var attributes: [AndroidXMLAttribute] = []
                let stride = max(attributeSize, 20)
                for index in 0..<min(attributeCount, AndroidXMLLimits.maxAttributes) {
                    let position = ext + attributeStart + index * stride
                    guard position + 20 <= offset + size,
                          let ns = reader.u32(at: position), let attrName = reader.u32(at: position + 4),
                          let raw = reader.u32(at: position + 8), let dataType = reader.u8(at: position + 15),
                          let value = reader.u32(at: position + 16) else { break }
                    let namespace = ns == 0xFFFF_FFFF ? nil : pool?.string(at: Int(ns))
                    let id = Int(attrName) < resourceMap.count ? resourceMap[Int(attrName)] : nil
                    var typed = AndroidResValue.decode(type: dataType, data: value, pool: pool)
                    if raw != 0xFFFF_FFFF, let rawString = pool?.string(at: Int(raw)), dataType == 0x03 || typed == .null {
                        typed = .string(rawString)
                    }
                    attributes.append(AndroidXMLAttribute(namespace: namespace, name: pool?.string(at: Int(attrName)) ?? "",
                                                          resourceID: id, value: typed))
                }
                let element = AndroidXMLElement(name: name, attributes: attributes)
                if let parent = stack.last {
                    if stack.count < AndroidXMLLimits.maxDepth { parent.children.append(element) }
                } else if root == nil {
                    root = element
                }
                if stack.count < AndroidXMLLimits.maxDepth || stack.isEmpty {
                    stack.append(element)
                } else {
                    // Too deep: keep counting depth with a detached placeholder so end tags still balance.
                    stack.append(AndroidXMLElement(name: name, attributes: []))
                }
            case 0x0103:
                if !stack.isEmpty { stack.removeLast() }
            default:
                break
            }
            offset += size
        }
        guard let root else { throw AndroidXMLError.corrupt }
        return root
    }
}

// MARK: - Protobuf

/// A minimal protobuf wire-format reader for aapt2's Resources.proto messages.
struct ProtoMessage {
    enum Value {
        case varint(UInt64)
        case fixed64(UInt64)
        case bytes(Data)
        case fixed32(UInt32)
    }

    let fields: [(number: Int, value: Value)]

    init?(_ input: Data, fieldLimit: Int = 2_000_000) {
        let bytes = input.startIndex == 0 ? input : Data(input)
        var fields: [(Int, Value)] = []
        var offset = 0
        let count = bytes.count
        func varint() -> UInt64? {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while offset < count, shift < 64 {
                let byte = bytes[offset]
                offset += 1
                result |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return result }
                shift += 7
            }
            return nil
        }
        while offset < count {
            guard fields.count < fieldLimit, let key = varint() else { return nil }
            let number = Int(key >> 3)
            guard number > 0 else { return nil }
            switch key & 7 {
            case 0:
                guard let value = varint() else { return nil }
                fields.append((number, .varint(value)))
            case 1:
                guard offset + 8 <= count else { return nil }
                let value = bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self) }
                offset += 8
                fields.append((number, .fixed64(UInt64(littleEndian: value))))
            case 2:
                guard let length = varint(), length <= UInt64(count - offset) else { return nil }
                let end = offset + Int(length)
                fields.append((number, .bytes(bytes.subdata(in: offset..<end))))
                offset = end
            case 5:
                guard offset + 4 <= count else { return nil }
                let value = bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
                offset += 4
                fields.append((number, .fixed32(UInt32(littleEndian: value))))
            default:
                return nil   // groups and unknown wire types: not used by aapt2
            }
        }
        self.fields = fields
    }

    func all(_ number: Int) -> [Value] { fields.filter { $0.number == number }.map(\.value) }
    func first(_ number: Int) -> Value? { fields.first { $0.number == number }?.value }

    func data(_ number: Int) -> Data? { if case .bytes(let data)? = first(number) { return data } else { return nil } }
    func string(_ number: Int) -> String? { data(number).map { String(decoding: $0, as: UTF8.self) } }
    func message(_ number: Int) -> ProtoMessage? { data(number).flatMap { ProtoMessage($0) } }
    func messages(_ number: Int) -> [ProtoMessage] {
        all(number).compactMap { if case .bytes(let data) = $0 { return ProtoMessage(data) } else { return nil } }
    }
    func uint(_ number: Int) -> UInt64? {
        switch first(number) {
        case .varint(let value)?: return value
        case .fixed32(let value)?: return UInt64(value)
        case .fixed64(let value)?: return value
        default: return nil
        }
    }
    func float(_ number: Int) -> Float? {
        if case .fixed32(let value)? = first(number) { return Float(bitPattern: value) }
        return nil
    }
}

/// aapt2's protobuf XML (`XmlNode`), as stored in Android App Bundles.
enum AndroidProtoXML {
    static func parse(_ data: Data, deadline: Date = Date().addingTimeInterval(1)) throws -> AndroidXMLElement {
        guard let node = ProtoMessage(data), let element = node.message(1) else { throw AndroidXMLError.notXML }
        var budget = AndroidXMLLimits.maxElements
        guard let root = convert(element, depth: 0, budget: &budget, deadline: deadline) else { throw AndroidXMLError.corrupt }
        return root
    }

    private static func convert(_ element: ProtoMessage, depth: Int, budget: inout Int, deadline: Date) -> AndroidXMLElement? {
        guard budget > 0, depth < AndroidXMLLimits.maxDepth, Date() < deadline else { return nil }
        budget -= 1
        var attributes: [AndroidXMLAttribute] = []
        for attribute in element.messages(4).prefix(AndroidXMLLimits.maxAttributes) {
            let id = attribute.uint(5).map { UInt32(truncatingIfNeeded: $0) }
            var value: AndroidValue = attribute.string(3).map(AndroidValue.string) ?? .null
            if let compiledItem = attribute.message(6), let compiled = AndroidProtoXML.item(compiledItem) { value = compiled }
            attributes.append(AndroidXMLAttribute(namespace: attribute.string(1), name: attribute.string(2) ?? "",
                                                  resourceID: id == 0 ? nil : id, value: value))
        }
        let result = AndroidXMLElement(name: element.string(3) ?? "", attributes: attributes)
        for child in element.messages(5) {
            guard let childElement = child.message(1) else { continue }   // text nodes are field 2
            if let converted = convert(childElement, depth: depth + 1, budget: &budget, deadline: deadline) {
                result.children.append(converted)
            }
        }
        return result
    }

    /// Decodes an aapt2 `Item` (reference, string, file, primitive).
    static func item(_ item: ProtoMessage) -> AndroidValue? {
        if let reference = item.message(1) {
            let id = UInt32(truncatingIfNeeded: reference.uint(2) ?? 0)
            if id != 0 { return (reference.uint(1) ?? 0) == 1 ? .attribute(id) : .reference(id) }
            if let name = reference.string(3) { return .string("@" + name) }
            return .null
        }
        if let string = item.message(2) { return .string(string.string(1) ?? "") }
        if let raw = item.message(3) { return .string(raw.string(1) ?? "") }
        if let styled = item.message(4) { return .string(styled.string(1) ?? "") }
        if let file = item.message(5) { return .string(file.string(1) ?? "") }
        if let primitive = item.message(7) {
            for field in primitive.fields {
                switch (field.number, field.value) {
                case (1, _), (2, _): return .null
                case (3, .fixed32(let bits)), (4, .fixed32(let bits)), (5, .fixed32(let bits)): return .float(Double(Float(bitPattern: bits)))
                case (6, .varint(let value)): return .int(Int64(Int32(truncatingIfNeeded: value)))
                case (7, .varint(let value)): return .int(Int64(UInt32(truncatingIfNeeded: value)))
                case (8, .varint(let value)): return .bool(value != 0)
                case (9...12, .varint(let value)): return .color(UInt32(truncatingIfNeeded: value))
                case (13, .varint(let value)), (14, .varint(let value)): return .other(String(value))
                default: continue
                }
            }
            // proto3 omits default scalars: an empty primitive is false / 0.
            return .int(0)
        }
        return nil
    }
}

