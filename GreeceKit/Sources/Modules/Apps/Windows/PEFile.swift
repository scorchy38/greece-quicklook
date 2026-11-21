import Foundation

/// A Windows Portable Executable (.exe, .dll, .sys, .efi): headers, imports, exports, resources,
/// .NET metadata and where the Authenticode signature lives. Everything comes from untrusted bytes,
/// so every count, walk and string is capped, and nothing ever reads outside the file.
struct PEFile {
    enum Failure: Error, Equatable { case notPE, truncated }

    struct Section {
        let name: String
        let virtualAddress: UInt32
        let virtualSize: UInt32
        let rawOffset: UInt32
        let rawSize: UInt32
        let characteristics: UInt32
        var entropy: Double?

        var isCode: Bool { characteristics & 0x20 != 0 }
        var isExecutable: Bool { characteristics & 0x2000_0000 != 0 }
        var isReadable: Bool { characteristics & 0x4000_0000 != 0 }
        var isWritable: Bool { characteristics & 0x8000_0000 != 0 }
        var hasUninitializedData: Bool { characteristics & 0x80 != 0 }
    }

    struct ImportedLibrary {
        let name: String
        /// Function names, or "Ordinal 12". Capped; `functionCount` is the real total.
        var functions: [String]
        var functionCount: Int
        var isDelayLoaded: Bool
    }

    struct Exports {
        let libraryName: String?
        let functionCount: Int
        let nameCount: Int
        /// The first exported names, capped.
        let names: [String]
    }

    struct DataDirectory: Equatable {
        let rva: UInt32
        let size: UInt32
        var isPresent: Bool { rva != 0 && size != 0 }
    }

    struct DotNet {
        var runtimeVersion: String
        var metadataVersion: String?
        /// ".NETCoreApp,Version=v8.0", from the TargetFramework attribute when it can be found.
        var targetFramework: String?
        var flags: UInt32
        var isILOnly: Bool { flags & 0x1 != 0 }
        var requires32Bit: Bool { flags & 0x2 != 0 }
        var isStrongNameSigned: Bool { flags & 0x8 != 0 }
        var prefers32Bit: Bool { flags & 0x2_0000 != 0 }
    }

    struct DebugInfo {
        var pdbPath: String?
        var pdbGUID: String?
        var pdbAge: UInt32?
        /// The linker wrote a deterministic build: the timestamp is a content hash, not a date.
        var isReproducible = false
        /// Compatible with CET shadow stacks (extended DLL characteristics).
        var isCETCompatible = false
    }

    struct LoadConfig {
        var hasSecurityCookie = false
        /// x86 only: the number of registered safe exception handlers.
        var safeExceptionHandlers: Int?
        var guardFlags: UInt32 = 0
        /// Hybrid ARM64X / ARM64EC code (CHPE metadata).
        var hasHybridMetadata = false
    }

    // Limits.
    static let maxSections = 256
    static let maxImportDescriptors = 4096
    static let maxThunksPerLibrary = 65_536
    static let maxThunksTotal = 200_000
    static let maxNamesKept = 400
    static let maxExportNames = 100_000

    let data: Data
    let peOffset: Int
    let machine: UInt16
    let characteristics: UInt16
    let timestamp: UInt32
    let is64Bit: Bool
    let linkerVersion: String
    let osVersion: (major: UInt16, minor: UInt16)
    let subsystemVersion: (major: UInt16, minor: UInt16)
    let imageVersion: (major: UInt16, minor: UInt16)
    let subsystem: UInt16
    let dllCharacteristics: UInt16
    let entryPoint: UInt32
    let imageBase: UInt64
    let imageSize: UInt32
    let headersSize: UInt32
    /// File offsets the Authenticode digest skips.
    let checksumOffset: Int
    let directoriesOffset: Int
    let directories: [DataDirectory]
    private(set) var sections: [Section] = []
    /// Sections by virtual address, for binary search.
    private var lookup: [(start: Int, end: Int, index: Int)] = []
    private(set) var imports: [ImportedLibrary] = []
    private(set) var exports: Exports?
    private(set) var resources: PEResources?
    private(set) var dotNet: DotNet?
    private(set) var debug = DebugInfo()
    private(set) var loadConfig: LoadConfig?

    var fileSize: Int { data.count }

    // MARK: - Sniffing

    /// "MZ", then e_lfanew pointing at "PE\0\0" inside the probe.
    static func sniff(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 0x40, bytes[0] == 0x4D, bytes[1] == 0x5A else { return false }
        let lfanew = Int(bytes[0x3C]) | Int(bytes[0x3D]) << 8 | Int(bytes[0x3E]) << 16 | Int(bytes[0x3F]) << 24
        guard lfanew >= 4, lfanew <= bytes.count - 24 else { return false }
        return bytes[lfanew] == 0x50 && bytes[lfanew + 1] == 0x45 && bytes[lfanew + 2] == 0 && bytes[lfanew + 3] == 0
    }

    // MARK: - Parsing

    init(url: URL) throws {
        try self.init(data: Data(contentsOf: url, options: .alwaysMapped))
    }

    /// `resourcesOnly` skips imports, exports, .NET, debug data and entropy (for thumbnails).
    init(data input: Data, resourcesOnly: Bool = false) throws {
        data = input.startIndex == 0 ? input : Data(input)
        let reader = BinaryReader(data)
        guard data.count >= 0x40, reader.u16(at: 0) == 0x5A4D, let lfanew = reader.u32(at: 0x3C).map(Int.init),
              lfanew >= 4, reader.u32(at: lfanew) == 0x0000_4550 else { throw Failure.notPE }
        peOffset = lfanew
        let file = lfanew + 4
        guard let machine = reader.u16(at: file), let sectionCount = reader.u16(at: file + 2),
              let timestamp = reader.u32(at: file + 4), let optionalSize = reader.u16(at: file + 16),
              let characteristics = reader.u16(at: file + 18) else { throw Failure.truncated }
        self.machine = machine
        self.timestamp = timestamp
        self.characteristics = characteristics

        let optional = file + 20
        guard let magic = reader.u16(at: optional), magic == 0x10B || magic == 0x20B else { throw Failure.notPE }
        is64Bit = magic == 0x20B
        linkerVersion = "\(reader.u8(at: optional + 2) ?? 0).\(String(format: "%02d", reader.u8(at: optional + 3) ?? 0))"
        entryPoint = reader.u32(at: optional + 16) ?? 0
        imageBase = is64Bit ? (reader.u64(at: optional + 24) ?? 0) : UInt64(reader.u32(at: optional + 28) ?? 0)
        osVersion = (reader.u16(at: optional + 40) ?? 0, reader.u16(at: optional + 42) ?? 0)
        imageVersion = (reader.u16(at: optional + 44) ?? 0, reader.u16(at: optional + 46) ?? 0)
        subsystemVersion = (reader.u16(at: optional + 48) ?? 0, reader.u16(at: optional + 50) ?? 0)
        imageSize = reader.u32(at: optional + 56) ?? 0
        headersSize = reader.u32(at: optional + 60) ?? 0
        checksumOffset = optional + 64
        subsystem = reader.u16(at: optional + 68) ?? 0
        dllCharacteristics = reader.u16(at: optional + 70) ?? 0
        let countOffset = optional + (is64Bit ? 108 : 92)
        directoriesOffset = countOffset + 4
        let declared = Int(reader.u32(at: countOffset) ?? 0)
        // The directories must fit inside the optional header.
        let fits = max(0, (optional + Int(optionalSize) - directoriesOffset) / 8)
        var directories: [DataDirectory] = []
        for index in 0..<min(declared, 16, fits) {
            let position = directoriesOffset + index * 8
            guard let rva = reader.u32(at: position), let size = reader.u32(at: position + 4) else { break }
            directories.append(DataDirectory(rva: rva, size: size))
        }
        self.directories = directories

        let table = optional + Int(optionalSize)
        var sections: [Section] = []
        for index in 0..<min(Int(sectionCount), Self.maxSections) {
            let position = table + index * 40
            guard reader.has(40, at: position) else { break }
            sections.append(Section(
                name: Self.sectionName(reader, at: position),
                virtualAddress: reader.u32(at: position + 12) ?? 0,
                virtualSize: reader.u32(at: position + 8) ?? 0,
                rawOffset: reader.u32(at: position + 20) ?? 0,
                rawSize: reader.u32(at: position + 16) ?? 0,
                characteristics: reader.u32(at: position + 36) ?? 0))
        }
        self.sections = sections
        lookup = sections.enumerated()
            .map { (start: Int($0.element.virtualAddress), end: Int($0.element.virtualAddress) + Int(max($0.element.virtualSize, $0.element.rawSize)), index: $0.offset) }
            .filter { $0.end > $0.start }
            .sorted { $0.start < $1.start }

        if let directory = directory(2) { resources = PEResources(file: self, directory: directory) }
        if resourcesOnly { return }
        imports = readImports() + readDelayImports()
        exports = readExports()
        dotNet = readDotNet()
        debug = readDebug()
        loadConfig = readLoadConfig()
        var budget = 8 << 20
        for index in self.sections.indices where budget > 0 {
            self.sections[index].entropy = entropy(of: self.sections[index], budget: &budget)
        }
    }

    /// "/4" style names point into the COFF string table (object files and MinGW images).
    private static func sectionName(_ reader: BinaryReader, at position: Int) -> String {
        let name = reader.fixedString(at: position, length: 8) ?? ""
        return Format.clean(name, limit: 16)
    }

    // MARK: - Addresses

    func directory(_ index: Int) -> DataDirectory? {
        guard index < directories.count, directories[index].isPresent else { return nil }
        return directories[index]
    }

    /// The file offset of a relative virtual address, if `length` bytes there are backed by the file.
    func offset(ofRVA rva: UInt32, length: Int = 1) -> Int? {
        let address = Int(rva)
        guard length >= 0 else { return nil }
        // The last section starting at or before the address.
        var low = 0, high = lookup.count
        while low < high {
            let middle = (low + high) / 2
            if lookup[middle].start <= address { low = middle + 1 } else { high = middle }
        }
        if low > 0, address < lookup[low - 1].end {
            let section = sections[lookup[low - 1].index]
            let delta = address - Int(section.virtualAddress)
            guard delta + length <= Int(section.rawSize) else { return nil }
            let position = Int(section.rawOffset) + delta
            return position >= 0 && position + length <= data.count ? position : nil
        }
        // Inside the headers (tiny images put everything there).
        if address + length <= max(Int(headersSize), 0x200), address + length <= data.count { return address }
        return nil
    }

    func bytes(atRVA rva: UInt32, count: Int) -> Data? {
        guard let position = offset(ofRVA: rva, length: count) else { return nil }
        return data.subdata(in: position..<(position + count))
    }

    func u16(atRVA rva: UInt32) -> UInt16? { offset(ofRVA: rva, length: 2).flatMap { BinaryReader(data).u16(at: $0) } }
    func u32(atRVA rva: UInt32) -> UInt32? { offset(ofRVA: rva, length: 4).flatMap { BinaryReader(data).u32(at: $0) } }
    func u64(atRVA rva: UInt32) -> UInt64? { offset(ofRVA: rva, length: 8).flatMap { BinaryReader(data).u64(at: $0) } }

    func string(atRVA rva: UInt32, maxLength: Int = 512) -> String? {
        guard let position = offset(ofRVA: rva) else { return nil }
        guard let text = BinaryReader(data).cString(at: position, maxLength: maxLength), !text.isEmpty else { return nil }
        return Format.clean(text, limit: maxLength)
    }

    // MARK: - Imports

    private func readImports() -> [ImportedLibrary] {
        guard let directory = directory(1) else { return [] }
        var libraries: [ImportedLibrary] = []
        var budget = Self.maxThunksTotal
        for index in 0..<Self.maxImportDescriptors {
            let base = directory.rva &+ UInt32(index * 20)
            guard let lookup = u32(atRVA: base), let nameRVA = u32(atRVA: base &+ 12), let first = u32(atRVA: base &+ 16) else { break }
            if lookup == 0 && nameRVA == 0 && first == 0 { break }
            guard let name = string(atRVA: nameRVA, maxLength: 256) else { continue }
            let (functions, count) = thunks(at: lookup != 0 ? lookup : first, budget: &budget, vaBased: false)
            libraries.append(ImportedLibrary(name: name, functions: functions, functionCount: count, isDelayLoaded: false))
        }
        return libraries
    }

    private func readDelayImports() -> [ImportedLibrary] {
        guard let directory = directory(13) else { return [] }
        var libraries: [ImportedLibrary] = []
        var budget = Self.maxThunksTotal / 2
        for index in 0..<Self.maxImportDescriptors {
            let base = directory.rva &+ UInt32(index * 32)
            guard let attributes = u32(atRVA: base), let nameField = u32(atRVA: base &+ 4),
                  let namesField = u32(atRVA: base &+ 16) else { break }
            if nameField == 0 && namesField == 0 { break }
            // Old images store virtual addresses instead of RVAs.
            let vaBased = attributes & 1 == 0
            guard let nameRVA = rva(fromField: nameField, vaBased: vaBased), let name = string(atRVA: nameRVA, maxLength: 256) else { continue }
            let tableRVA = rva(fromField: namesField, vaBased: vaBased) ?? 0
            let (functions, count) = tableRVA == 0 ? ([], 0) : thunks(at: tableRVA, budget: &budget, vaBased: vaBased)
            libraries.append(ImportedLibrary(name: name, functions: functions, functionCount: count, isDelayLoaded: true))
        }
        return libraries
    }

    private func rva(fromField value: UInt32, vaBased: Bool) -> UInt32? {
        guard vaBased else { return value }
        let base = imageBase
        guard UInt64(value) >= base, UInt64(value) - base <= UInt64(UInt32.max) else { return nil }
        return UInt32(UInt64(value) - base)
    }

    private func thunks(at start: UInt32, budget: inout Int, vaBased: Bool) -> ([String], Int) {
        var names: [String] = []
        var count = 0
        let width: UInt32 = is64Bit ? 8 : 4
        let ordinalFlag: UInt64 = is64Bit ? 1 << 63 : 1 << 31
        var cursor = start
        while count < Self.maxThunksPerLibrary, budget > 0 {
            guard let value = is64Bit ? u64(atRVA: cursor) : u32(atRVA: cursor).map(UInt64.init), value != 0 else { break }
            count += 1
            budget -= 1
            if names.count < Self.maxNamesKept {
                if value & ordinalFlag != 0 {
                    names.append("Ordinal \(value & 0xFFFF)")
                } else if let hintRVA = rva(fromField: UInt32(truncatingIfNeeded: value & 0x7FFF_FFFF), vaBased: vaBased),
                          let name = string(atRVA: hintRVA &+ 2, maxLength: 256) {
                    names.append(name)
                }
            }
            let (next, overflow) = cursor.addingReportingOverflow(width)
            if overflow { break }
            cursor = next
        }
        return (names, count)
    }

    // MARK: - Exports

    private func readExports() -> Exports? {
        guard let directory = directory(0), let base = offset(ofRVA: directory.rva, length: 40) else { return nil }
        let reader = BinaryReader(data)
        let nameRVA = reader.u32(at: base + 12) ?? 0
        let functionCount = Int(reader.u32(at: base + 20) ?? 0)
        let nameCount = Int(reader.u32(at: base + 24) ?? 0)
        let namesRVA = reader.u32(at: base + 32) ?? 0
        var names: [String] = []
        var valid = 0
        for index in 0..<min(nameCount, Self.maxExportNames) {
            guard let pointer = u32(atRVA: namesRVA &+ UInt32(index * 4)) else { break }
            valid += 1
            if names.count < Self.maxNamesKept, let name = string(atRVA: pointer, maxLength: 256) { names.append(name) }
        }
        // Counts come from the header; keep them believable against what the file actually holds.
        let plausibleFunctions = min(functionCount, max(0, data.count / 4))
        return Exports(libraryName: string(atRVA: nameRVA, maxLength: 256), functionCount: plausibleFunctions,
                       nameCount: valid, names: names)
    }

    // MARK: - .NET

    private func readDotNet() -> DotNet? {
        guard let directory = directory(14), let header = offset(ofRVA: directory.rva, length: 24) else { return nil }
        let reader = BinaryReader(data)
        let major = reader.u16(at: header + 4) ?? 0
        let minor = reader.u16(at: header + 6) ?? 0
        let metadataRVA = reader.u32(at: header + 8) ?? 0
        let metadataSize = Int(reader.u32(at: header + 12) ?? 0)
        let flags = reader.u32(at: header + 16) ?? 0
        var result = DotNet(runtimeVersion: "\(major).\(minor)", flags: flags)
        if let root = offset(ofRVA: metadataRVA, length: 16), reader.u32(at: root) == 0x424A_5342,
           let length = reader.u32(at: root + 12).map(Int.init), length > 0, length <= 256 {
            result.metadataVersion = reader.cString(at: root + 16, maxLength: length).map { Format.clean($0, limit: 64) }
            // TargetFrameworkAttribute's value sits in the #Blob heap as UTF-8.
            let span = min(metadataSize, 32 << 20, data.count - root)
            if span > 0 {
                let metadata = data.subdata(in: root..<(root + span))
                for prefix in [".NETCoreApp,Version=", ".NETFramework,Version=", ".NETStandard,Version="] {
                    if let found = metadata.firstRange(of: Array(prefix.utf8)) {
                        let tail = metadata[(metadata.startIndex + found)...].prefix(64)
                        let text = String(decoding: tail.prefix { $0 >= 0x20 && $0 < 0x7F }, as: UTF8.self)
                        result.targetFramework = Format.clean(text, limit: 64)
                        break
                    }
                }
            }
        }
        return result
    }

    // MARK: - Debug directory

    private func readDebug() -> DebugInfo {
        var info = DebugInfo()
        guard let directory = directory(6) else { return info }
        let reader = BinaryReader(data)
        let count = min(Int(directory.size) / 28, 32)
        for index in 0..<count {
            guard let entry = offset(ofRVA: directory.rva &+ UInt32(index * 28), length: 28) else { break }
            let type = reader.u32(at: entry + 12) ?? 0
            let size = Int(reader.u32(at: entry + 16) ?? 0)
            let pointer = Int(reader.u32(at: entry + 24) ?? 0)
            switch type {
            case 2 where size >= 24 && size < 4096:
                // CodeView: "RSDS", GUID, age, PDB path.
                guard reader.has(size, at: pointer), reader.u32(at: pointer) == 0x5344_5352,
                      let guid = reader.bytes(at: pointer + 4, count: 16) else { continue }
                info.pdbGUID = Self.guidString(guid)
                info.pdbAge = reader.u32(at: pointer + 20)
                info.pdbPath = reader.cString(at: pointer + 24, maxLength: min(size - 24, 1024)).map { Format.clean($0, limit: 400) }
            case 16:
                info.isReproducible = true
            case 20 where size >= 4:
                if let flags = reader.u32(at: pointer), reader.has(4, at: pointer) { info.isCETCompatible = flags & 0x1 != 0 }
            default:
                break
            }
        }
        return info
    }

    static func guidString(_ bytes: Data) -> String {
        let b = [UInt8](bytes)
        guard b.count == 16 else { return bytes.hexString.uppercased() }
        let first = String(format: "%02X%02X%02X%02X", b[3], b[2], b[1], b[0])
        let second = String(format: "%02X%02X", b[5], b[4])
        let third = String(format: "%02X%02X", b[7], b[6])
        let fourth = String(format: "%02X%02X", b[8], b[9])
        let fifth = b[10...].map { String(format: "%02X", $0) }.joined()
        return "\(first)-\(second)-\(third)-\(fourth)-\(fifth)"
    }

    // MARK: - Load config

    private func readLoadConfig() -> LoadConfig? {
        guard let directory = directory(10), let base = offset(ofRVA: directory.rva, length: 4) else { return nil }
        let reader = BinaryReader(data)
        let size = Int(reader.u32(at: base) ?? 0)
        guard size >= 64, reader.has(min(size, 1024), at: base) else { return nil }
        var config = LoadConfig()
        if is64Bit {
            if size >= 96 { config.hasSecurityCookie = (reader.u64(at: base + 88) ?? 0) != 0 }
            if size >= 148 { config.guardFlags = reader.u32(at: base + 144) ?? 0 }
            if size >= 208 { config.hasHybridMetadata = (reader.u64(at: base + 200) ?? 0) != 0 }
        } else {
            if size >= 64 { config.hasSecurityCookie = (reader.u32(at: base + 60) ?? 0) != 0 }
            if size >= 72 { config.safeExceptionHandlers = Int(reader.u32(at: base + 68) ?? 0) }
            if size >= 92 { config.guardFlags = reader.u32(at: base + 88) ?? 0 }
            if size >= 128 { config.hasHybridMetadata = (reader.u32(at: base + 124) ?? 0) != 0 }
        }
        return config
    }

    // MARK: - Entropy

    /// Shannon entropy of a section's bytes (sampled), 0–8. Above ~7.2 means compressed or encrypted.
    private func entropy(of section: Section, budget: inout Int) -> Double? {
        let start = Int(section.rawOffset)
        let length = min(Int(section.rawSize), data.count - start, 1 << 20, budget)
        guard start >= 0, start < data.count, length >= 256 else { return nil }
        budget -= length
        var histogram = [Int](repeating: 0, count: 256)
        data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for index in 0..<length { histogram[Int(base[start + index])] += 1 }
        }
        let total = Double(length)
        return histogram.reduce(0.0) { sum, count in
            guard count > 0 else { return sum }
            let p = Double(count) / total
            return sum - p * log2(p)
        }
    }

    // MARK: - Layout facts

    /// Where the sections end on disk. Anything after (before the signature) is an overlay:
    /// installers keep their payload there.
    var overlayRange: Range<Int>? {
        let end = sections.reduce(Int(headersSize)) { max($0, Int($1.rawOffset) + Int($1.rawSize)) }
        let limit = certificateTable?.lowerBound ?? data.count
        guard end < limit, end >= 0 else { return nil }
        return end..<limit
    }

    /// The Authenticode certificate table: a file offset (not an RVA) and size.
    var certificateTable: Range<Int>? {
        guard let directory = directory(4) else { return nil }
        let start = Int(directory.rva)
        let size = Int(directory.size)
        guard start > 0, size >= 8, start <= data.count, size <= data.count - start else { return nil }
        return start..<(start + size)
    }

    var isDLL: Bool { characteristics & 0x2000 != 0 }
    var isEFI: Bool { (10...13).contains(subsystem) }
    var isDriver: Bool { subsystem == 1 || (characteristics & 0x1000 != 0) }
    var hasRelocationsStripped: Bool { characteristics & 0x1 != 0 }
}
