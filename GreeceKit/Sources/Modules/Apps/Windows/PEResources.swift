import Foundation

/// A PE resource tree (type → name → language), flattened, plus the resources Greece reads:
/// the version block, the application manifest and the icon.
struct PEResources {
    enum Identifier: Hashable, Comparable {
        case id(UInt32)
        case name(String)

        static func < (lhs: Identifier, rhs: Identifier) -> Bool {
            switch (lhs, rhs) {
            case (.name(let a), .name(let b)): return a < b
            case (.name, .id): return true          // Windows sorts named entries first
            case (.id, .name): return false
            case (.id(let a), .id(let b)): return a < b
            }
        }
    }

    struct Entry {
        let type: Identifier
        let name: Identifier
        let language: UInt32
        let dataRVA: UInt32
        let size: UInt32
    }

    static let maxEntries = 20_000
    static let maxEntriesPerDirectory = 4096

    let entries: [Entry]

    init(entries: [Entry]) { self.entries = entries }

    init?(file: PEFile, directory: PEFile.DataDirectory) {
        guard let root = file.offset(ofRVA: directory.rva, length: 16) else { return nil }
        let reader = BinaryReader(file.data)
        var entries: [Entry] = []
        // Directories are visited once (no cycles), and the whole walk reads a bounded number of entries.
        var visited = Set<Int>()
        var budget = Self.maxEntries * 4

        /// The children of a directory at a section-relative offset.
        func children(_ relative: Int) -> [(Identifier, isDirectory: Bool, target: Int)] {
            let base = root + relative
            guard budget > 0, relative >= 0, visited.insert(relative).inserted, reader.has(16, at: base),
                  let named = reader.u16(at: base + 12), let numbered = reader.u16(at: base + 14) else { return [] }
            var result: [(Identifier, Bool, Int)] = []
            for index in 0..<min(Int(named) + Int(numbered), Self.maxEntriesPerDirectory, budget) {
                budget -= 1
                let position = base + 16 + index * 8
                guard let key = reader.u32(at: position), let value = reader.u32(at: position + 4) else { break }
                let identifier: Identifier
                if key & 0x8000_0000 != 0 {
                    let at = root + Int(key & 0x7FFF_FFFF)
                    guard let length = reader.u16(at: at).map(Int.init), let raw = reader.bytes(at: at + 2, count: min(length, 256) * 2) else { continue }
                    identifier = .name(Format.clean(Self.utf16LE(raw), limit: 128))
                } else {
                    identifier = .id(key)
                }
                result.append((identifier, value & 0x8000_0000 != 0, Int(value & 0x7FFF_FFFF)))
            }
            return result
        }

        outer: for (type, typeIsDirectory, typeTarget) in children(0) where typeIsDirectory {
            for (name, nameIsDirectory, nameTarget) in children(typeTarget) where nameIsDirectory {
                for (language, languageIsDirectory, dataTarget) in children(nameTarget) where !languageIsDirectory {
                    let position = root + dataTarget
                    guard let rva = reader.u32(at: position), let size = reader.u32(at: position + 4) else { continue }
                    let languageID: UInt32
                    if case .id(let value) = language { languageID = value } else { languageID = 0 }
                    entries.append(Entry(type: type, name: name, language: languageID, dataRVA: rva, size: size))
                    if entries.count >= Self.maxEntries { break outer }
                }
            }
        }
        self.entries = entries
    }

    /// Little-endian UTF-16, without assuming the bytes are aligned.
    static func utf16LE<D: DataProtocol>(_ bytes: D) -> String {
        var units: [UInt16] = []
        units.reserveCapacity(bytes.count / 2)
        var low: UInt8?
        for byte in bytes {
            if let first = low { units.append(UInt16(first) | UInt16(byte) << 8); low = nil } else { low = byte }
        }
        return String(decoding: units, as: UTF16.self)
    }

    /// Entries of one type, by name, each name's languages ordered US English, neutral, any English, then the rest.
    func entries(ofType type: UInt32) -> [Entry] {
        func rank(_ language: UInt32) -> Int {
            switch language {
            case 0x0409: return 0
            case 0, 0x0400, 0x0800: return 1
            default: return language & 0x3FF == 0x09 ? 2 : 3
            }
        }
        return entries.filter { $0.type == .id(type) }.sorted {
            $0.name != $1.name ? $0.name < $1.name : rank($0.language) < rank($1.language)
        }
    }

    func contents(of entry: Entry, in file: PEFile, limit: Int) -> Data? {
        guard entry.size > 0, Int(entry.size) <= limit else { return nil }
        return file.bytes(atRVA: entry.dataRVA, count: Int(entry.size))
    }

    /// Counts by kind, for the Info section: "8 icons", "3 dialogs".
    var census: [String] {
        // Icon images (3) are the parts of icons (14): only the icons count.
        let counted: Set<UInt32> = [1, 2, 4, 5, 6, 8, 10, 14, 23]
        // One resource can exist in several languages: count names, not leaves.
        var seen: [UInt32: Set<Identifier>] = [:]
        for entry in entries { if case .id(let type) = entry.type, counted.contains(type) { seen[type, default: []].insert(entry.name) } }
        return seen.sorted { $0.key < $1.key }.compactMap { type, set in Self.census(type: type, count: set.count) }
    }

    /// "8 icons": a count of one kind of resource.
    private static func census(type: UInt32, count: Int) -> String? {
        switch type {
        case 1: return String(localized: "\(count) cursors", bundle: .greeceKit, comment: "Resources in a Windows program. The argument is a count")
        case 2: return String(localized: "\(count) bitmaps", bundle: .greeceKit, comment: "Resources in a Windows program. The argument is a count")
        case 4: return String(localized: "\(count) menus", bundle: .greeceKit, comment: "Resources in a Windows program. The argument is a count")
        case 5: return String(localized: "\(count) dialogs", bundle: .greeceKit, comment: "Resources in a Windows program. The argument is a count")
        case 6: return String(localized: "\(count) string tables", bundle: .greeceKit, comment: "Resources in a Windows program. The argument is a count")
        case 8: return String(localized: "\(count) fonts", bundle: .greeceKit, comment: "Resources in a Windows program. The argument is a count")
        case 10: return String(localized: "\(count) data resources", bundle: .greeceKit, comment: "Resources in a Windows program. The argument is a count")
        case 14: return String(localized: "\(count) icons", bundle: .greeceKit, comment: "Resources in a Windows program. The argument is a count")
        case 23: return String(localized: "\(count) HTML pages", bundle: .greeceKit, comment: "Resources in a Windows program. The argument is a count")
        default: return nil
        }
    }

    // MARK: - Icon

    /// The application's icon (the first icon group, as Explorer picks it), rebuilt as an .ico file.
    func iconFile(in file: PEFile) -> Data? {
        let images = entries(ofType: 3)
        guard !images.isEmpty else { return nil }
        for group in entries(ofType: 14).prefix(4) {
            guard let directory = contents(of: group, in: file, limit: 64 * 1024), let ico = Self.icoFile(group: directory, images: images, file: file) else { continue }
            return ico
        }
        return nil
    }

    /// GRPICONDIR entries name RT_ICON resources by id; an .ico stores image offsets instead.
    static func icoFile(group: Data, images: [Entry], file: PEFile) -> Data? {
        let reader = BinaryReader(group)
        guard reader.u16(at: 2) == 1, let declared = reader.u16(at: 4).map(Int.init), declared > 0 else { return nil }
        var byID: [UInt32: Entry] = [:]
        for image in images { if case .id(let id) = image.name, byID[id] == nil { byID[id] = image } }

        var chosen: [(header: Data, image: Data)] = []
        var total = 0
        for index in 0..<min(declared, 32) {
            let position = 6 + index * 14
            guard let header = reader.bytes(at: position, count: 12), let id = reader.u16(at: position + 12).map(UInt32.init),
                  let entry = byID[id], entry.size >= 40, entry.size <= 4 << 20,
                  let image = file.bytes(atRVA: entry.dataRVA, count: Int(entry.size)) else { continue }
            total += image.count
            if total > 16 << 20 { break }
            chosen.append((header, image))
        }
        guard !chosen.isEmpty else { return nil }
        var output = Data([0, 0, 1, 0])
        output.append(contentsOf: withUnsafeBytes(of: UInt16(chosen.count).littleEndian, Array.init))
        var offset = 6 + chosen.count * 16
        for item in chosen {
            var header = item.header
            // dwBytesInRes must match the real image size.
            header.replaceSubrange(8..<12, with: withUnsafeBytes(of: UInt32(item.image.count).littleEndian, Array.init))
            output.append(header)
            output.append(contentsOf: withUnsafeBytes(of: UInt32(offset).littleEndian, Array.init))
            offset += item.image.count
        }
        for item in chosen { output.append(item.image) }
        return output
    }

    // MARK: - Version

    func versionInfo(in file: PEFile) -> PEVersionInfo? {
        for entry in entries(ofType: 16).prefix(2) {
            if let data = contents(of: entry, in: file, limit: 256 * 1024), let info = PEVersionInfo(data: data) { return info }
        }
        return nil
    }

    // MARK: - Manifest

    func manifest(in file: PEFile) -> PEManifest? {
        for entry in entries(ofType: 24).prefix(2) {
            if let data = contents(of: entry, in: file, limit: 256 * 1024), let manifest = PEManifest(data: data) { return manifest }
        }
        return nil
    }
}

/// VS_VERSIONINFO: the fixed version numbers and the string table (company, product, copyright…).
struct PEVersionInfo {
    var strings: [(key: String, value: String)] = []
    var fileVersion: String?
    var productVersion: String?
    var fileFlags: UInt32 = 0
    var fileType: UInt32 = 0
    var languages: [UInt16] = []

    subscript(key: String) -> String? { strings.first { $0.key == key }?.value }

    var isDebugBuild: Bool { fileFlags & 0x1 != 0 }
    var isPrerelease: Bool { fileFlags & 0x2 != 0 }
    var isPatched: Bool { fileFlags & 0x4 != 0 }
    var isPrivateBuild: Bool { fileFlags & 0x8 != 0 }

    init?(data: Data) {
        let reader = BinaryReader(data)
        var tables: [String: [(String, String)]] = [:]
        var tableOrder: [String] = []

        /// One block: length, value length, type, key, value, then child blocks up to `length`.
        /// Depth 0 is VS_VERSION_INFO, 1 StringFileInfo or VarFileInfo, 2 a string table or Var, 3 a string.
        func block(at position: Int, depth: Int, table: String?) -> Int? {
            guard depth < 5, let length = reader.u16(at: position).map(Int.init), length >= 6,
                  let valueLength = reader.u16(at: position + 2).map(Int.init), let type = reader.u16(at: position + 4) else { return nil }
            let end = min(position + length, data.count)
            guard end > position + 6 else { return nil }
            var cursor = position + 6
            let key = Self.utf16(reader, at: &cursor, end: end)
            let valueStart = Self.align(cursor)

            if depth == 0, key == "VS_VERSION_INFO", valueLength >= 52, reader.u32(at: valueStart) == 0xFEEF_04BD {
                func version(_ high: UInt32?, _ low: UInt32?) -> String? {
                    guard let high, let low else { return nil }
                    return "\(high >> 16).\(high & 0xFFFF).\(low >> 16).\(low & 0xFFFF)"
                }
                fileVersion = version(reader.u32(at: valueStart + 8), reader.u32(at: valueStart + 12))
                productVersion = version(reader.u32(at: valueStart + 16), reader.u32(at: valueStart + 20))
                let mask = reader.u32(at: valueStart + 24) ?? 0x3F
                fileFlags = (reader.u32(at: valueStart + 28) ?? 0) & mask
                fileType = reader.u32(at: valueStart + 36) ?? 0
            }
            if depth == 3, let table {
                // A string's value runs to its NUL: tools disagree on whether its length counts bytes or characters.
                var valueCursor = valueStart
                let value = Self.utf16(reader, at: &valueCursor, end: end)
                if tables[table] == nil { tables[table] = []; tableOrder.append(table) }
                if (tables[table]?.count ?? 0) < 64, !key.isEmpty, !value.trimmingCharacters(in: .whitespaces).isEmpty {
                    tables[table]?.append((Format.clean(key, limit: 64), Format.clean(value, limit: 300)))
                }
                return end
            }
            if key == "Translation", type == 0 {
                var at = valueStart
                while at + 4 <= min(valueStart + valueLength, end), languages.count < 256 {
                    if let language = reader.u16(at: at) { languages.append(language) }
                    at += 4
                }
            }
            cursor = Self.align(valueStart + (type == 1 ? valueLength * 2 : valueLength))
            var children = 0
            while cursor + 6 <= end, children < 256 {
                guard let next = block(at: cursor, depth: depth + 1, table: depth == 2 ? key : table), next > cursor else { break }
                cursor = Self.align(next)
                children += 1
            }
            return end
        }

        guard block(at: 0, depth: 0, table: nil) != nil else { return nil }
        // Prefer US English, then any English table, then the first.
        let preferred = tableOrder.first { $0.lowercased().hasPrefix("0409") }
            ?? tableOrder.first { $0.lowercased().hasPrefix("09", at: 2) }
            ?? tableOrder.first
        strings = preferred.flatMap { tables[$0] }?.map { (key: $0.0, value: $0.1) } ?? []
        if strings.isEmpty && fileVersion == nil { return nil }
    }

    private static func align(_ value: Int) -> Int { (value + 3) & ~3 }

    private static func utf16(_ reader: BinaryReader, at cursor: inout Int, end: Int) -> String {
        var units: [UInt16] = []
        while cursor + 2 <= end, let unit = reader.u16(at: cursor) {
            cursor += 2
            if unit == 0 { break }
            if units.count < 1024 { units.append(unit) }
        }
        return String(decoding: units, as: UTF16.self)
    }
}

private extension String {
    func hasPrefix(_ prefix: String, at offset: Int) -> Bool {
        guard count >= offset + prefix.count else { return false }
        return dropFirst(offset).hasPrefix(prefix)
    }
}

/// The application manifest: what privileges it asks for and which Windows versions it knows.
struct PEManifest {
    var text: String
    var executionLevel: String?
    var uiAccess = false
    var dpiAware: String?
    var longPathAware = false
    var supportedOS: [String] = []
    var assemblyName: String?
    var assemblyDescription: String?

    var requiresAdministrator: Bool { executionLevel == "requireAdministrator" }

    static let windowsVersions: [String: String] = [
        "e2011457-1546-43c5-a5fe-008deee3d3f0": "Windows Vista",
        "35138b9a-5d96-4fbd-8e2d-a2440225f93a": "Windows 7",
        "4a2f28e3-53b9-4441-ba9c-d69d4a4a6e38": "Windows 8",
        "1f676c76-80e1-4239-95bb-83d0f6d0da78": "Windows 8.1",
        "8e0f7a12-bfb3-4fe8-b9a5-48fd50a15a9a": String(localized: "Windows 10 and 11", bundle: .greeceKit, comment: "Windows versions a program says it supports"),
    ]

    init?(data: Data) {
        var text: String
        if data.starts(with: [0xFF, 0xFE]) {
            text = PEResources.utf16LE(data.dropFirst(2))
        } else {
            text = String(decoding: data.starts(with: [0xEF, 0xBB, 0xBF]) ? data.dropFirst(3) : data, as: UTF8.self)
        }
        text = text.replacingOccurrences(of: "\0", with: "")
        guard text.contains("<") else { return nil }
        self.text = String(text.prefix(64 * 1024))

        // Bounded quantifiers keep hostile manifests (no closing brackets, endless attributes) linear.
        func attribute(_ element: String, _ name: String) -> String? {
            let pattern = "<(?:\\w{1,32}:)?\(element)\\b[^>]{0,400}?\\b\(name)\\s*=\\s*[\"']([^\"']{0,200})[\"']"
            return Self.firstMatch(pattern, in: self.text)
        }
        func element(_ name: String) -> String? {
            Self.firstMatch("<(?:\\w{1,32}:)?\(name)\\b[^>]{0,400}>([^<]{0,200})</", in: self.text)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        executionLevel = attribute("requestedExecutionLevel", "level")
        uiAccess = attribute("requestedExecutionLevel", "uiAccess")?.lowercased() == "true"
        dpiAware = element("dpiAwareness") ?? element("dpiAware")
        longPathAware = element("longPathAware")?.lowercased() == "true"
        assemblyName = attribute("assemblyIdentity", "name")
        assemblyDescription = element("description")
        let ids = Self.allMatches("supportedOS\\s+Id\\s*=\\s*[\"']\\{?([0-9A-Fa-f-]{36})\\}?[\"']", in: self.text)
        var seen = Set<String>()
        for id in ids.prefix(16) {
            let name = Self.windowsVersions[id.lowercased()] ?? id
            if seen.insert(name).inserted { supportedOS.append(name) }
        }
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return Format.clean(String(text[range]), limit: 200)
    }

    private static func allMatches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).prefix(32).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]) }
        }
    }
}
