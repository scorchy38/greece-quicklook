import Foundation

/// One configuration-specific value of a resource ("res/mipmap-xxxhdpi-v4/ic_launcher.png" at 640 dpi).
struct AndroidResourceValue: Equatable {
    /// Screen density in dpi; 0 is the default, 0xFFFE "anydpi", 0xFFFF "nodpi".
    var density: Int
    /// "" for the default configuration, otherwise "fr", "pt-BR"…
    var locale: String
    var value: AndroidValue
}

/// Resolves resource IDs (0xPPTTEEEE) to their values in every configuration.
protocol AndroidResourceTable: AnyObject {
    func values(for id: UInt32) -> [AndroidResourceValue]
    /// The locales the app's resources are translated into.
    var locales: Set<String> { get }
}

extension AndroidResourceTable {
    /// A string in the default (or English, or first) configuration, following references.
    func string(for id: UInt32) -> String? {
        var current = id
        for _ in 0..<6 {
            let values = values(for: current)
            let preferred = values.first { $0.locale.isEmpty } ?? values.first { $0.locale.hasPrefix("en") } ?? values.first
            guard let preferred else { return nil }
            switch preferred.value {
            case .reference(let next): current = next
            default: return preferred.value.string
            }
        }
        return nil
    }

    /// File paths for a drawable or mipmap, best density first, following references.
    func files(for id: UInt32) -> [(path: String, density: Int)] {
        var result: [(String, Int)] = []
        var queue: [UInt32] = [id]
        var seen = Set<UInt32>()
        while let next = queue.popLast(), seen.count < 16 {
            guard seen.insert(next).inserted else { continue }
            for value in values(for: next) {
                switch value.value {
                case .string(let path): result.append((path, value.density))
                case .reference(let target): queue.append(target)
                default: break
                }
            }
        }
        return result.sorted { AndroidResources.rank($0.1) > AndroidResources.rank($1.1) }
    }
}

enum AndroidResources {
    /// Orders densities for icons: real densities by size, then anydpi (vector/adaptive), nodpi last.
    static func rank(_ density: Int) -> Int {
        switch density {
        case 0xFFFE: return 100_000
        case 0xFFFF: return -1
        case 0: return 160
        default: return density
        }
    }
}

// MARK: - resources.arsc

/// The binary resource table in an APK. Only chunk headers are indexed up front; entries are read
/// on demand, so a multi-megabyte table resolves a handful of IDs in microseconds.
final class AndroidBinaryResources: AndroidResourceTable {
    private struct TypeChunk {
        let offset: Int
        let headerSize: Int
        let size: Int
        let flags: UInt8
        let entryCount: Int
        let entriesStart: Int
        let density: Int
        let locale: String
    }

    private let data: Data
    private var globalPool: AndroidStringPool?
    /// (package << 8 | type) -> chunks.
    private var types: [UInt32: [TypeChunk]] = [:]
    private(set) var locales: Set<String> = []

    init(data input: Data, deadline: Date = Date().addingTimeInterval(1)) throws {
        let reader = BinaryReader(input)
        data = reader.data
        guard reader.u16(at: 0) == 0x0002, let headerSize = reader.u16(at: 2).map(Int.init), headerSize >= 12 else {
            throw AndroidXMLError.notXML
        }
        let end = min(data.count, Int(reader.u32(at: 4) ?? 0) == 0 ? data.count : Int(reader.u32(at: 4) ?? 0))
        var pool: AndroidStringPool?
        var offset = headerSize
        var chunks = 0
        while offset + 8 <= end {
            guard let type = reader.u16(at: offset), let chunkHeader = reader.u16(at: offset + 2).map(Int.init),
                  let size = reader.u32(at: offset + 4).map(Int.init), size >= 8, chunkHeader <= size, size <= end - offset else { break }
            chunks += 1
            if chunks > 1_000 || Date() > deadline { break }
            if type == 0x0001, pool == nil {
                pool = AndroidStringPool(data: data, chunk: offset)
            } else if type == 0x0200 {
                indexPackage(at: offset, headerSize: chunkHeader, size: size, deadline: deadline)
            }
            offset += size
        }
        globalPool = pool
    }

    private func indexPackage(at package: Int, headerSize: Int, size: Int, deadline: Date) {
        let reader = BinaryReader(data)
        guard let packageID = reader.u32(at: package + 8), packageID <= 0xFF else { return }
        var offset = package + headerSize
        let end = package + size
        var count = 0
        while offset + 8 <= end {
            guard let type = reader.u16(at: offset), let chunkHeader = reader.u16(at: offset + 2).map(Int.init),
                  let chunkSize = reader.u32(at: offset + 4).map(Int.init), chunkSize >= 8, chunkHeader <= chunkSize,
                  chunkSize <= end - offset else { break }
            count += 1
            if count > 200_000 || (count % 512 == 0 && Date() > deadline) { break }
            if type == 0x0201, chunkHeader >= 20 + 28,
               let typeID = reader.u8(at: offset + 8), let flags = reader.u8(at: offset + 9),
               let entryCount = reader.u32(at: offset + 12).map(Int.init), let entriesStart = reader.u32(at: offset + 16).map(Int.init),
               entriesStart <= chunkSize {
                let config = offset + 20
                let density = Int(reader.u16(at: config + 14) ?? 0)
                let locale = Self.locale(language: reader.bytes(at: config + 8, count: 2), country: reader.bytes(at: config + 10, count: 2))
                if !locale.isEmpty, locales.count < 1_000 { locales.insert(locale) }
                let key = packageID << 8 | UInt32(typeID)
                if (types[key]?.count ?? 0) < 512 {
                    types[key, default: []].append(TypeChunk(offset: offset, headerSize: chunkHeader, size: chunkSize, flags: flags,
                                                             entryCount: min(entryCount, 65_536), entriesStart: entriesStart,
                                                             density: density, locale: locale))
                }
            }
            offset += chunkSize
        }
    }

    /// Two-letter codes, or aapt's packed three-letter form; "" when unset.
    private static func locale(language: Data?, country: Data?) -> String {
        func decode(_ bytes: Data?, base: UInt8) -> String {
            guard let bytes, bytes.count == 2, bytes[bytes.startIndex] != 0 else { return "" }
            let first = bytes[bytes.startIndex], second = bytes[bytes.startIndex + 1]
            if first & 0x80 != 0 {
                // Packed: 5 bits per letter.
                let a = second & 0x1F, b = ((second & 0xE0) >> 5) | ((first & 0x03) << 3), c = (first & 0x7C) >> 2
                return String(bytes: [a + base, b + base, c + base], encoding: .ascii) ?? ""
            }
            return String(bytes: [first, second], encoding: .ascii) ?? ""
        }
        let lang = decode(language, base: 0x61)
        let region = decode(country, base: 0x30)
        guard !lang.isEmpty else { return "" }
        return region.isEmpty ? lang : lang + "-" + region
    }

    func values(for id: UInt32) -> [AndroidResourceValue] {
        let key = (id >> 24) << 8 | ((id >> 16) & 0xFF)
        let entry = Int(id & 0xFFFF)
        guard let chunks = types[key] else { return [] }
        let reader = BinaryReader(data)
        var result: [AndroidResourceValue] = []
        for chunk in chunks where entry < chunk.entryCount || chunk.flags & 0x01 != 0 {
            let table = chunk.offset + chunk.headerSize
            var entryOffset: Int?
            if chunk.flags & 0x01 != 0 {
                // Sparse: sorted (index, offset / 4) pairs.
                var low = 0, high = chunk.entryCount - 1
                while low <= high {
                    let middle = (low + high) / 2
                    guard let index = reader.u16(at: table + middle * 4).map(Int.init) else { break }
                    if index == entry { entryOffset = reader.u16(at: table + middle * 4 + 2).map { Int($0) * 4 }; break }
                    if index < entry { low = middle + 1 } else { high = middle - 1 }
                }
            } else if chunk.flags & 0x02 != 0 {
                if let value = reader.u16(at: table + entry * 2), value != 0xFFFF { entryOffset = Int(value) * 4 }
            } else if let value = reader.u32(at: table + entry * 4), value != 0xFFFF_FFFF {
                entryOffset = Int(value)
            }
            guard let entryOffset else { continue }
            let position = chunk.offset + chunk.entriesStart + entryOffset
            guard position + 8 <= chunk.offset + chunk.size, let size = reader.u16(at: position).map(Int.init),
                  let flags = reader.u16(at: position + 2) else { continue }
            var value: AndroidValue
            if flags & 0x0008 != 0 {
                let dataType = UInt8(flags >> 8)
                value = AndroidResValue.decode(type: dataType, data: reader.u32(at: position + 4) ?? 0, pool: globalPool)
            } else if flags & 0x0001 != 0 {
                continue   // styles, arrays, plurals: not needed for labels or icons
            } else {
                let valueAt = position + size
                guard valueAt + 8 <= chunk.offset + chunk.size, let dataType = reader.u8(at: valueAt + 3),
                      let raw = reader.u32(at: valueAt + 4) else { continue }
                value = AndroidResValue.decode(type: dataType, data: raw, pool: globalPool)
            }
            result.append(AndroidResourceValue(density: chunk.density, locale: chunk.locale, value: value))
            if result.count >= 256 { break }
        }
        return result
    }
}

// MARK: - resources.pb (Android App Bundles)

/// aapt2's protobuf `ResourceTable`, as found in `base/resources.pb`.
final class AndroidProtoResources: AndroidResourceTable {
    /// id -> values, decoded once up front (bundles keep the table small enough).
    private var table: [UInt32: [AndroidResourceValue]] = [:]
    private(set) var locales: Set<String> = []

    init(data: Data, deadline: Date = Date().addingTimeInterval(1.5)) throws {
        guard let root = ProtoMessage(data) else { throw AndroidXMLError.notXML }
        var entries = 0
        for package in root.messages(2) {
            let packageID = UInt32(truncatingIfNeeded: package.message(1)?.uint(1) ?? 0x7f)
            for type in package.messages(3) {
                guard Date() < deadline else { return }
                let typeID = UInt32(truncatingIfNeeded: type.message(1)?.uint(1) ?? 0)
                let typeName = type.string(2) ?? ""
                // Only the types a header can use: strings for labels, drawables and mipmaps for icons, colors for backgrounds.
                guard ["string", "mipmap", "drawable", "color"].contains(typeName) else {
                    if typeName.isEmpty { continue }
                    for entry in type.messages(3).prefix(1) { collectLocales(entry) }
                    continue
                }
                for entry in type.messages(3) {
                    entries += 1
                    guard entries < 300_000 else { return }
                    let entryID = UInt32(truncatingIfNeeded: entry.message(1)?.uint(1) ?? 0)
                    let id = packageID << 24 | (typeID & 0xFF) << 16 | (entryID & 0xFFFF)
                    var values: [AndroidResourceValue] = []
                    for configValue in entry.messages(6).prefix(256) {
                        let config = configValue.message(1)
                        let locale = config?.string(3) ?? ""
                        if !locale.isEmpty, locales.count < 1_000 { locales.insert(locale) }
                        let density = Int(config?.uint(18) ?? 0)
                        guard let item = configValue.message(2)?.message(4), let value = AndroidProtoXML.item(item) else { continue }
                        values.append(AndroidResourceValue(density: density, locale: locale, value: value))
                    }
                    if !values.isEmpty { table[id] = values }
                }
            }
        }
    }

    private func collectLocales(_ entry: ProtoMessage) {
        for configValue in entry.messages(6).prefix(256) {
            if let locale = configValue.message(1)?.string(3), !locale.isEmpty, locales.count < 1_000 { locales.insert(locale) }
        }
    }

    func values(for id: UInt32) -> [AndroidResourceValue] { table[id] ?? [] }
}
