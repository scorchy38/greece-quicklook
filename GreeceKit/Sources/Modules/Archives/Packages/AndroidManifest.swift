import Foundation

/// The parts of an Android manifest Greece shows, from an APK's binary XML (AXML) or an App
/// Bundle's protobuf XML. Both decoders are bounds-checked throughout: the input is untrusted.
struct AndroidManifest {
    var package: String?
    var versionName: String?
    var versionCode: String?
    var minSDK: String?
    var targetSDK: String?
    var label: String?
    var permissions: [String] = []

    // MARK: - APK: binary XML

    private static let attributeIDs: [UInt32: String] = [
        0x0101_021B: "versionCode", 0x0101_021C: "versionName", 0x0101_020C: "minSdkVersion",
        0x0101_0270: "targetSdkVersion", 0x0101_0001: "label", 0x0101_0003: "name",
    ]

    init?(binaryXML data: Data) {
        guard data.count >= 8, data.count <= 16 * 1024 * 1024, data.u16(0) == 0x0003 else { return nil }
        var strings: [String] = []
        var resourceIDs: [UInt32] = []
        var offset = Int(data.u16(2))
        var elements = 0
        while offset + 8 <= data.count, elements < 100_000 {
            let type = data.u16(offset)
            let headerSize = Int(data.u16(offset + 2))
            let size = Int(data.u32(offset + 4))
            guard size >= 8, offset + size <= data.count, headerSize >= 8 else { break }
            switch type {
            case 0x0001:
                strings = AndroidManifest.stringPool(data, at: offset, size: size)
            case 0x0180:
                let count = (size - headerSize) / 4
                resourceIDs = (0..<min(count, 10_000)).map { data.u32(offset + headerSize + $0 * 4) }
            case 0x0102:
                elements += 1
                let body = offset + headerSize
                guard body + 20 <= data.count else { break }
                let nameIndex = Int(data.u32(body + 4))
                let attributeStart = Int(data.u16(body + 8))
                let attributeSize = max(Int(data.u16(body + 10)), 20)
                let count = Int(data.u16(body + 12))
                let element = nameIndex < strings.count ? strings[nameIndex] : ""
                var attributes: [String: String] = [:]
                for index in 0..<min(count, 512) {
                    let at = body + attributeStart + index * attributeSize
                    guard at + 20 <= data.count else { break }
                    let nameRef = Int(data.u32(at + 4))
                    var name = nameRef < strings.count ? strings[nameRef] : ""
                    if nameRef < resourceIDs.count, let known = AndroidManifest.attributeIDs[resourceIDs[nameRef]] { name = known }
                    let raw = Int(data.u32(at + 8))
                    let valueType = data[data.startIndex + at + 15]
                    let value = data.u32(at + 16)
                    if raw != 0xFFFF_FFFF, raw < strings.count {
                        attributes[name] = strings[raw]
                    } else {
                        switch valueType {
                        case 0x03: attributes[name] = Int(value) < strings.count ? strings[Int(value)] : nil
                        case 0x10, 0x11: attributes[name] = String(Int32(bitPattern: value))
                        case 0x12: attributes[name] = value != 0 ? "true" : "false"
                        case 0x01: attributes[name] = String(format: "@0x%08X", value)
                        default: break
                        }
                    }
                }
                apply(element: element, attributes)
            default:
                break
            }
            offset += size
        }
        guard package != nil else { return nil }
    }

    private mutating func apply(element: String, _ attributes: [String: String]) {
        switch element {
        case "manifest":
            package = attributes["package"]
            versionName = attributes["versionName"]
            versionCode = attributes["versionCode"]
        case "uses-sdk":
            minSDK = attributes["minSdkVersion"]
            targetSDK = attributes["targetSdkVersion"]
        case "application":
            if let label = attributes["label"], !label.hasPrefix("@") { self.label = label }
        case "uses-permission", "uses-permission-sdk-23":
            if let name = attributes["name"], permissions.count < 500 { permissions.append(name) }
        default:
            break
        }
    }

    private static func stringPool(_ data: Data, at offset: Int, size: Int) -> [String] {
        let count = Int(data.u32(offset + 8))
        let flags = data.u32(offset + 16)
        let stringsStart = Int(data.u32(offset + 20))
        let utf8 = flags & 0x100 != 0
        let headerSize = Int(data.u16(offset + 2))
        guard count <= 200_000, offset + headerSize + count * 4 <= offset + size else { return [] }
        var result: [String] = []
        result.reserveCapacity(count)
        for index in 0..<count {
            let start = offset + stringsStart + Int(data.u32(offset + headerSize + index * 4))
            guard start < offset + size else { result.append(""); continue }
            if utf8 {
                var cursor = start
                cursor += data[data.startIndex + cursor] & 0x80 != 0 ? 2 : 1          // UTF-16 length
                guard cursor + 1 < data.count else { result.append(""); continue }
                var length = Int(data[data.startIndex + cursor])
                if length & 0x80 != 0 { length = (length & 0x7F) << 8 | Int(data[data.startIndex + cursor + 1]); cursor += 2 } else { cursor += 1 }
                guard cursor + length <= data.count else { result.append(""); continue }
                result.append(String(decoding: data[(data.startIndex + cursor)..<(data.startIndex + cursor + length)], as: UTF8.self))
            } else {
                var length = Int(data.u16(start))
                var cursor = start + 2
                if length & 0x8000 != 0 { length = (length & 0x7FFF) << 16 | Int(data.u16(start + 2)); cursor += 2 }
                guard length <= 65_536, cursor + length * 2 <= data.count else { result.append(""); continue }
                let units = (0..<length).map { data.u16(cursor + $0 * 2) }
                result.append(String(decoding: units, as: UTF16.self))
            }
        }
        return result
    }

    // MARK: - App Bundle: protobuf XML

    /// aapt2's XmlNode protobuf (base/manifest/AndroidManifest.xml in an .aab).
    init?(protobufXML data: Data) {
        guard data.count <= 16 * 1024 * 1024 else { return nil }
        var budget = 200_000
        AndroidManifest.walkNode(data[...], depth: 0, budget: &budget) { element, attributes in
            apply(element: element, attributes)
        }
        guard package != nil else { return nil }
    }

    private static func walkNode(_ data: Data.SubSequence, depth: Int, budget: inout Int, visit: (String, [String: String]) -> Void) {
        guard depth < 64 else { return }
        for (field, value) in Protobuf.fields(data, budget: &budget) where field == 1 {
            guard case .bytes(let element) = value else { continue }
            var name = ""
            var attributes: [String: String] = [:]
            var children: [Data.SubSequence] = []
            for (elementField, elementValue) in Protobuf.fields(element, budget: &budget) {
                guard case .bytes(let bytes) = elementValue else { continue }
                switch elementField {
                case 3: name = String(decoding: bytes, as: UTF8.self)
                case 4:
                    var attributeName = "", attributeValue = ""
                    var resourceID: UInt64 = 0
                    for (attributeField, attribute) in Protobuf.fields(bytes, budget: &budget) {
                        switch (attributeField, attribute) {
                        case (2, .bytes(let text)): attributeName = String(decoding: text, as: UTF8.self)
                        case (3, .bytes(let text)): attributeValue = String(decoding: text, as: UTF8.self)
                        case (5, .varint(let id)): resourceID = id
                        default: break
                        }
                    }
                    if let known = attributeIDs[UInt32(truncatingIfNeeded: resourceID)] { attributeName = known }
                    if !attributeName.isEmpty { attributes[attributeName] = attributeValue }
                case 5: children.append(bytes)
                default: break
                }
            }
            visit(name, attributes)
            for child in children { walkNode(child, depth: depth + 1, budget: &budget, visit: visit) }
        }
    }
}

/// Just enough protobuf wire format to walk messages: varints and length-delimited fields.
enum Protobuf {
    enum Value { case varint(UInt64), bytes(Data.SubSequence), other }

    static func fields(_ data: Data.SubSequence, budget: inout Int) -> [(Int, Value)] {
        var result: [(Int, Value)] = []
        var index = data.startIndex
        func varint() -> UInt64? {
            var value: UInt64 = 0
            var shift: UInt64 = 0
            while index < data.endIndex, shift < 64 {
                let byte = data[index]
                index += 1
                value |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return value }
                shift += 7
            }
            return nil
        }
        while index < data.endIndex, budget > 0 {
            budget -= 1
            guard let key = varint() else { break }
            let field = Int(key >> 3)
            switch key & 7 {
            case 0:
                guard let value = varint() else { return result }
                result.append((field, .varint(value)))
            case 1:
                guard data.endIndex - index >= 8 else { return result }
                index += 8
                result.append((field, .other))
            case 2:
                guard let length = varint(), length <= UInt64(data.endIndex - index) else { return result }
                let end = index + Int(length)
                result.append((field, .bytes(data[index..<end])))
                index = end
            case 5:
                guard data.endIndex - index >= 4 else { return result }
                index += 4
                result.append((field, .other))
            default:
                return result
            }
        }
        return result
    }
}
