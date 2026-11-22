import Foundation

/// Bytes that can be read at any offset: a file on disk, or the parts of a compressed member
/// that were captured while streaming it.
protocol RandomAccessBytes: AnyObject {
    var size: UInt64 { get }
    /// Exactly `count` bytes at `offset`, or nil if they aren't available.
    func read(_ offset: UInt64, _ count: Int) -> Data?
}

final class FileBytes: RandomAccessBytes {
    private let handle: FileHandle
    let size: UInt64

    init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
        size = (try? handle.seekToEnd()) ?? 0
    }

    deinit { try? handle.close() }

    func read(_ offset: UInt64, _ count: Int) -> Data? {
        guard count >= 0, offset <= size, UInt64(count) <= size - offset else { return nil }
        guard (try? handle.seek(toOffset: offset)) != nil, let data = try? handle.read(upToCount: count), data.count == count else { return nil }
        return data
    }
}

final class DataBytes: RandomAccessBytes {
    let data: Data
    init(_ data: Data) { self.data = data.startIndex == 0 ? data : Data(data) }
    var size: UInt64 { UInt64(data.count) }
    func read(_ offset: UInt64, _ count: Int) -> Data? {
        guard count >= 0, offset <= size, UInt64(count) <= size - offset else { return nil }
        let start = Int(offset)
        return data.subdata(in: start..<(start + count))
    }
}

/// A sparse copy of a stream: only the ranges someone asked for are kept.
final class SparseBytes: RandomAccessBytes {
    private(set) var pieces: [(start: UInt64, data: Data)] = []
    var size: UInt64

    init(size: UInt64) { self.size = size }

    func store(_ data: Data, at start: UInt64) {
        pieces.append((start, data))
    }

    func replace(_ pieces: [(start: UInt64, data: Data)]) { self.pieces = pieces }

    func read(_ offset: UInt64, _ count: Int) -> Data? {
        guard count >= 0 else { return nil }
        for piece in pieces where offset >= piece.start && offset + UInt64(count) <= piece.start + UInt64(piece.data.count) {
            let start = Int(offset - piece.start)
            return piece.data.subdata(in: (piece.data.startIndex + start)..<(piece.data.startIndex + start + count))
        }
        return nil
    }

    func has(_ range: Range<UInt64>) -> Bool { read(range.lowerBound, Int(range.count)) != nil }
}

/// A Mach-O file: one slice per architecture, with what each links, targets and carries.
struct MachOFile {
    struct BuildVersion: Equatable {
        var platform: Platform
        var minimum: String
        var sdk: String?
    }

    enum Platform: Equatable {
        case macOS, iOS, tvOS, watchOS, bridgeOS, macCatalyst, iOSSimulator, tvOSSimulator, watchOSSimulator, driverKit
        case visionOS, visionOSSimulator, firmware, sepOS, other(UInt32)

        init(_ raw: UInt32) {
            switch raw {
            case 1: self = .macOS
            case 2: self = .iOS
            case 3: self = .tvOS
            case 4: self = .watchOS
            case 5: self = .bridgeOS
            case 6: self = .macCatalyst
            case 7: self = .iOSSimulator
            case 8: self = .tvOSSimulator
            case 9: self = .watchOSSimulator
            case 10: self = .driverKit
            case 11: self = .visionOS
            case 12: self = .visionOSSimulator
            case 13: self = .firmware
            case 14: self = .sepOS
            default: self = .other(raw)
            }
        }

        var name: String {
            switch self {
            case .macOS: return "macOS"
            case .iOS: return "iOS"
            case .tvOS: return "tvOS"
            case .watchOS: return "watchOS"
            case .bridgeOS: return "bridgeOS"
            case .macCatalyst: return "Mac Catalyst"
            case .iOSSimulator: return "iOS Simulator"
            case .tvOSSimulator: return "tvOS Simulator"
            case .watchOSSimulator: return "watchOS Simulator"
            case .driverKit: return "DriverKit"
            case .visionOS: return "visionOS"
            case .visionOSSimulator: return "visionOS Simulator"
            case .firmware: return String(localized: "Firmware", bundle: .greeceKit, comment: "A platform a binary is built for")
            case .sepOS: return "sepOS"
            case .other(let raw): return String(localized: "Platform \(String(raw))", bundle: .greeceKit, comment: "An unknown platform a binary is built for. The argument is its number")
            }
        }
    }

    struct Library: Equatable {
        enum Kind: String { case normal, weak, reexport, lazy, upward }
        var path: String
        var kind: Kind
        var currentVersion: String
        var compatibilityVersion: String

        /// "AppKit", "libswiftCore", "Sparkle".
        var name: String {
            let components = path.split(separator: "/")
            if let framework = components.lastIndex(where: { $0.hasSuffix(".framework") }) {
                return String(components[framework].dropLast(".framework".count))
            }
            var last = String(components.last ?? Substring(path))
            for suffix in [".dylib", ".tbd", ".so"] where last.hasSuffix(suffix) { last = String(last.dropLast(suffix.count)) }
            if let dot = last.range(of: ".A"), last.hasSuffix(".A") { last = String(last[..<dot.lowerBound]) }
            return last
        }

        var isSystem: Bool { path.hasPrefix("/System/") || path.hasPrefix("/usr/lib/") }
        var isEmbedded: Bool { path.hasPrefix("@") }
    }

    struct Segment: Equatable {
        var name: String
        var fileSize: UInt64
        var vmSize: UInt64
        var sections: [Section]
    }

    struct Section: Equatable {
        var segment: String
        var name: String
        var size: UInt64
        var offset: UInt32
    }

    struct Slice {
        var cpuType: Int32
        var cpuSubtype: Int32
        var offset: UInt64
        var size: UInt64
        var is64Bit = false
        var fileType: UInt32 = 0
        var flags: UInt32 = 0
        var uuid: UUID?
        var builds: [BuildVersion] = []
        var libraries: [Library] = []
        var installName: String?
        var installVersion: String?
        var rpaths: [String] = []
        var segments: [Segment] = []
        var codeSignature: Range<UInt64>?
        var encryptionID: UInt32?
        var sourceVersion: String?
        var hasEntryPoint = false
        var toolVersions: [(tool: String, version: String)] = []
        /// The load commands were cut short (hostile counts, or a capped read).
        var truncated = false

        var architecture: String { MachOFile.architectureName(cpuType: cpuType, subtype: cpuSubtype) }
        var isEncrypted: Bool { (encryptionID ?? 0) != 0 }
        var isAppleSilicon: Bool { cpuType == MachOFile.cpuARM64 }
        var isIntel: Bool { cpuType == MachOFile.cpuX86_64 || cpuType == MachOFile.cpuX86 }

        func section(_ segment: String, _ name: String) -> Section? {
            segments.lazy.flatMap(\.sections).first { $0.segment == segment && $0.name == name }
        }

        func hasSection(named name: String) -> Bool {
            segments.contains { $0.sections.contains { $0.name == name } }
        }
    }

    static let cpuX86: Int32 = 7
    static let cpuX86_64: Int32 = 0x0100_0007
    static let cpuARM: Int32 = 12
    static let cpuARM64: Int32 = 0x0100_000C
    static let cpuARM64_32: Int32 = 0x0200_000C
    static let cpuPPC: Int32 = 18
    static let cpuPPC64: Int32 = 0x0100_0012

    static let maxSlices = 32
    static let maxLoadCommands = 8192
    static let maxLoadCommandBytes = 16 << 20

    var slices: [Slice]
    var isFat: Bool

    // MARK: Detection

    enum Magic { case thin32, thin64, fat32, fat64 }

    /// Mach-O magic, telling Java class files (which share 0xCAFEBABE) apart from fat headers.
    static func magic(of bytes: [UInt8]) -> Magic? {
        guard bytes.count >= 8 else { return nil }
        let be = UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
        let second = UInt32(bytes[4]) << 24 | UInt32(bytes[5]) << 16 | UInt32(bytes[6]) << 8 | UInt32(bytes[7])
        switch be {
        case 0xCEFA_EDFE, 0xFEED_FACE: return .thin32
        case 0xCFFA_EDFE, 0xFEED_FACF: return .thin64
        case 0xCAFE_BABE:
            // Fat headers count architectures; class files store a version (45+) here.
            return (1...20).contains(second) ? .fat32 : nil
        case 0xCAFE_BABF: return (1...20).contains(second) ? .fat64 : nil
        default: return nil
        }
    }

    // MARK: Parsing

    static func parse(_ source: RandomAccessBytes) throws -> MachOFile {
        guard let head = source.read(0, 8), let magic = magic(of: [UInt8](head)) else { throw MachOError.notMachO }
        switch magic {
        case .thin32, .thin64:
            var slice = Slice(cpuType: 0, cpuSubtype: 0, offset: 0, size: source.size)
            try parseSlice(&slice, in: source)
            return MachOFile(slices: [slice], isFat: false)
        case .fat32, .fat64:
            let wide = magic == .fat64
            guard let countData = source.read(4, 4) else { throw MachOError.truncated }
            let count = min(Int(countData.be32(0)), maxSlices)
            let entrySize = wide ? 32 : 20
            guard let table = source.read(8, count * entrySize) else { throw MachOError.truncated }
            var slices: [Slice] = []
            for index in 0..<count {
                let base = index * entrySize
                let cpu = Int32(bitPattern: table.be32(base))
                let subtype = Int32(bitPattern: table.be32(base + 4))
                let offset = wide ? table.be64(base + 8) : UInt64(table.be32(base + 8))
                let size = wide ? table.be64(base + 16) : UInt64(table.be32(base + 12))
                guard offset < source.size else { continue }
                var slice = Slice(cpuType: cpu, cpuSubtype: subtype, offset: offset, size: min(size, source.size - offset))
                do { try parseSlice(&slice, in: source) } catch { slice.truncated = true }
                slices.append(slice)
            }
            guard !slices.isEmpty else { throw MachOError.truncated }
            return MachOFile(slices: slices, isFat: true)
        }
    }

    private static func parseSlice(_ slice: inout Slice, in source: RandomAccessBytes) throws {
        guard let header = source.read(slice.offset, 28) else { throw MachOError.truncated }
        let magic = header.u32(0)
        let is64: Bool
        switch magic {
        case 0xFEED_FACF: is64 = true
        case 0xFEED_FACE: is64 = false
        default: throw MachOError.notMachO   // big-endian (PowerPC) thin slices aren't worth parsing
        }
        slice.is64Bit = is64
        slice.cpuType = Int32(bitPattern: header.u32(4))
        slice.cpuSubtype = Int32(bitPattern: header.u32(8))
        slice.fileType = header.u32(12)
        let commandCount = Int(header.u32(16))
        let commandBytes = Int(header.u32(20))
        slice.flags = header.u32(24)
        let headerSize: UInt64 = is64 ? 32 : 28
        let available = min(commandBytes, maxLoadCommandBytes)
        guard let commands = source.read(slice.offset + headerSize, available) ?? source.read(slice.offset + headerSize, min(available, 256 * 1024 - Int(headerSize))) else {
            slice.truncated = true
            return
        }
        if commands.count < commandBytes { slice.truncated = true }
        let reader = BinaryReader(commands)
        var cursor = 0
        for _ in 0..<min(commandCount, maxLoadCommands) {
            guard let command = reader.u32(at: cursor), let size = reader.u32(at: cursor + 4).map(Int.init),
                  size >= 8, reader.has(size, at: cursor) else {
                slice.truncated = true
                break
            }
            parseCommand(command, at: cursor, size: size, reader: reader, into: &slice)
            cursor += size
        }
        if commandCount > maxLoadCommands { slice.truncated = true }
    }

    private static func parseCommand(_ command: UInt32, at start: Int, size: Int, reader: BinaryReader, into slice: inout Slice) {
        func string(at fieldOffset: Int) -> String? {
            guard let offset = reader.u32(at: start + fieldOffset).map(Int.init), offset < size else { return nil }
            return reader.cString(at: start + offset, maxLength: size - offset)
        }
        switch command {
        case 0x1, 0x19: // LC_SEGMENT, LC_SEGMENT_64
            let wide = command == 0x19
            guard let name = reader.fixedString(at: start + 8, length: 16) else { return }
            let vmSize = wide ? reader.u64(at: start + 32) : reader.u32(at: start + 28).map(UInt64.init)
            let fileSize = wide ? reader.u64(at: start + 48) : reader.u32(at: start + 36).map(UInt64.init)
            let sectionCount = Int((wide ? reader.u32(at: start + 64) : reader.u32(at: start + 48)) ?? 0)
            let firstSection = start + (wide ? 72 : 56)
            let sectionSize = wide ? 80 : 68
            var sections: [Section] = []
            for index in 0..<min(sectionCount, 512) {
                let base = firstSection + index * sectionSize
                guard base + sectionSize <= start + size,
                      let sectionName = reader.fixedString(at: base, length: 16),
                      let segmentName = reader.fixedString(at: base + 16, length: 16) else { break }
                let sectionBytes = wide ? reader.u64(at: base + 40) : reader.u32(at: base + 36).map(UInt64.init)
                let offset = wide ? reader.u32(at: base + 48) : reader.u32(at: base + 40)
                sections.append(Section(segment: segmentName, name: sectionName, size: sectionBytes ?? 0, offset: offset ?? 0))
            }
            if slice.segments.count < 256 {
                slice.segments.append(Segment(name: name, fileSize: fileSize ?? 0, vmSize: vmSize ?? 0, sections: sections))
            }
        case 0xC, 0x8000_0018, 0x8000_001F, 0x20, 0x8000_0023: // load, weak, reexport, lazy, upward dylib
            guard let path = string(at: 8), !path.isEmpty, slice.libraries.count < 4096 else { return }
            let kind: Library.Kind = command == 0x8000_0018 ? .weak : command == 0x8000_001F ? .reexport
                : command == 0x20 ? .lazy : command == 0x8000_0023 ? .upward : .normal
            slice.libraries.append(Library(path: path, kind: kind,
                                           currentVersion: dylibVersion(reader.u32(at: start + 16) ?? 0),
                                           compatibilityVersion: dylibVersion(reader.u32(at: start + 20) ?? 0)))
        case 0xD: // LC_ID_DYLIB
            slice.installName = string(at: 8)
            slice.installVersion = dylibVersion(reader.u32(at: start + 16) ?? 0)
        case 0x1B: // LC_UUID
            if let bytes = reader.bytes(at: start + 8, count: 16) {
                slice.uuid = bytes.withUnsafeBytes { UUID(uuid: $0.loadUnaligned(as: uuid_t.self)) }
            }
        case 0x8000_001C: // LC_RPATH
            if let path = string(at: 8), slice.rpaths.count < 256 { slice.rpaths.append(path) }
        case 0x1D: // LC_CODE_SIGNATURE
            if let offset = reader.u32(at: start + 8), let length = reader.u32(at: start + 12), length > 0 {
                let begin = slice.offset + UInt64(offset)
                slice.codeSignature = begin..<(begin + UInt64(length))
            }
        case 0x21, 0x2C: // LC_ENCRYPTION_INFO(_64)
            slice.encryptionID = reader.u32(at: start + 16)
        case 0x24, 0x25, 0x2F, 0x30: // LC_VERSION_MIN_*
            let platform: Platform = command == 0x24 ? .macOS : command == 0x25 ? .iOS : command == 0x2F ? .tvOS : .watchOS
            guard let version = reader.u32(at: start + 8) else { return }
            let sdk = reader.u32(at: start + 12).flatMap { $0 == 0 ? nil : osVersion($0) }
            slice.builds.append(BuildVersion(platform: platform, minimum: osVersion(version), sdk: sdk))
        case 0x32: // LC_BUILD_VERSION
            guard let platform = reader.u32(at: start + 8), let minimum = reader.u32(at: start + 12) else { return }
            let sdk = reader.u32(at: start + 16).flatMap { $0 == 0 ? nil : osVersion($0) }
            slice.builds.append(BuildVersion(platform: Platform(platform), minimum: osVersion(minimum), sdk: sdk))
            let tools = Int(reader.u32(at: start + 20) ?? 0)
            for index in 0..<min(tools, 16) {
                guard let tool = reader.u32(at: start + 24 + index * 8), let version = reader.u32(at: start + 28 + index * 8) else { break }
                let name: String
                switch tool {
                case 1: name = "Clang"
                case 2: name = "Swift"
                case 3: name = "ld"
                case 4: name = "lld"
                case 1024: name = "Metal"
                default: continue
                }
                slice.toolVersions.append((name, osVersion(version)))
            }
        case 0x2A: // LC_SOURCE_VERSION
            if let value = reader.u64(at: start + 8), value != 0 {
                let parts = [value >> 40, (value >> 30) & 0x3FF, (value >> 20) & 0x3FF, (value >> 10) & 0x3FF, value & 0x3FF]
                var trimmed = Array(parts)
                while trimmed.count > 2, trimmed.last == 0 { trimmed.removeLast() }
                slice.sourceVersion = trimmed.map(String.init).joined(separator: ".")
            }
        case 0x8000_0028: // LC_MAIN
            slice.hasEntryPoint = true
        default:
            break
        }
    }

    /// Ranges a streaming reader still needs to finish parsing what it has (headers, load
    /// commands, code signatures, embedded Info.plist), given what's already captured.
    static func neededRanges(_ source: SparseBytes, signatureLimit: Int = 8 << 20) -> [Range<UInt64>] {
        let headerWindow: UInt64 = 256 * 1024
        guard let head = source.read(0, 8) else { return [0..<min(headerWindow, source.size)] }
        guard let magic = magic(of: [UInt8](head)) else { return [] }
        var starts: [UInt64] = []
        switch magic {
        case .thin32, .thin64: starts = [0]
        case .fat32, .fat64:
            let wide = magic == .fat64
            let count = min(Int(head.be32(4)), maxSlices)
            let entrySize = wide ? 32 : 20
            guard let table = source.read(8, count * entrySize) else { return [0..<min(headerWindow, source.size)] }
            for index in 0..<count {
                let base = index * entrySize
                starts.append(wide ? table.be64(base + 8) : UInt64(table.be32(base + 8)))
            }
        }
        var needed: [Range<UInt64>] = []
        for start in starts where start < source.size {
            let window = start..<min(source.size, start + headerWindow)
            guard source.has(window) || source.read(start, 28) != nil else { needed.append(window); continue }
            var slice = Slice(cpuType: 0, cpuSubtype: 0, offset: start, size: source.size - start)
            guard (try? parseSlice(&slice, in: source)) != nil else { needed.append(window); continue }
            if let signature = slice.codeSignature, signature.upperBound <= source.size {
                let capped = signature.lowerBound..<min(signature.upperBound, signature.lowerBound + UInt64(signatureLimit))
                if !source.has(capped) { needed.append(capped) }
            }
            if let plist = slice.section("__TEXT", "__info_plist"), plist.size > 0, plist.size < 1 << 20 {
                let begin = start + UInt64(plist.offset)
                let range = begin..<(begin + plist.size)
                if range.upperBound <= source.size, !source.has(range) { needed.append(range) }
            }
        }
        return needed
    }

    // MARK: Formatting

    static func osVersion(_ value: UInt32) -> String {
        let major = value >> 16, minor = (value >> 8) & 0xFF, patch = value & 0xFF
        return patch == 0 ? "\(major).\(minor)" : "\(major).\(minor).\(patch)"
    }

    static func dylibVersion(_ value: UInt32) -> String {
        let major = value >> 16, minor = (value >> 8) & 0xFF, patch = value & 0xFF
        return patch == 0 ? "\(major).\(minor)" : "\(major).\(minor).\(patch)"
    }

    static func architectureName(cpuType: Int32, subtype: Int32) -> String {
        let sub = subtype & 0x00FF_FFFF
        switch cpuType {
        case cpuARM64: return sub == 2 ? "arm64e" : "arm64"
        case cpuARM64_32: return "arm64_32"
        case cpuX86_64: return sub == 8 ? "x86_64h" : "x86_64"
        case cpuX86: return "i386"
        case cpuARM:
            switch sub {
            case 6: return "armv6"
            case 9: return "armv7"
            case 11: return "armv7s"
            case 12: return "armv7k"
            default: return "arm"
            }
        case cpuPPC: return "ppc"
        case cpuPPC64: return "ppc64"
        default: return "cpu \(cpuType)"
        }
    }

    var fileTypeName: String {
        switch slices.first?.fileType ?? 0 {
        case 1: return String(localized: "Object File", bundle: .greeceKit)
        case 2: return String(localized: "Executable", bundle: .greeceKit, comment: "A kind of Mach-O file: a program")
        case 4: return String(localized: "Core Dump", bundle: .greeceKit)
        case 6: return String(localized: "Dynamic Library", bundle: .greeceKit)
        case 7: return String(localized: "Dynamic Linker", bundle: .greeceKit)
        case 8: return String(localized: "Bundle", bundle: .greeceKit, comment: "A kind of Mach-O file: a loadable bundle")
        case 9: return String(localized: "Library Stub", bundle: .greeceKit)
        case 10: return String(localized: "Debug Symbols", bundle: .greeceKit, comment: "Info bar title, section title and kind of file: a .dSYM bundle or Mach-O debug symbols file")
        case 11: return String(localized: "Kernel Extension", bundle: .greeceKit)
        case 12: return String(localized: "Kernel Collection", bundle: .greeceKit)
        default: return String(localized: "Mach-O File", bundle: .greeceKit)
        }
    }

    var architectures: [String] {
        var seen: [String] = []
        for slice in slices where !seen.contains(slice.architecture) { seen.append(slice.architecture) }
        return seen
    }

    /// The slice macOS would pick on this Mac: arm64e/arm64 first, then Intel.
    var preferredSlice: Slice? {
        slices.first { $0.cpuType == MachOFile.cpuARM64 } ?? slices.first { $0.cpuType == MachOFile.cpuX86_64 } ?? slices.first
    }
}

enum MachOError: Error { case notMachO, truncated }

/// Which kinds of Mac an executable runs on natively.
enum ArchitectureSupport: Equatable {
    case universal, appleSilicon, intel, other([String])

    init(_ slices: [MachOFile.Slice]) {
        let arm = slices.contains { $0.isAppleSilicon }
        let intel = slices.contains { $0.cpuType == MachOFile.cpuX86_64 }
        switch (arm, intel) {
        case (true, true): self = .universal
        case (true, false): self = .appleSilicon
        case (false, true): self = .intel
        default: self = .other(slices.map(\.architecture))
        }
    }

    var badge: InspectorBadge {
        switch self {
        case .universal:
            return InspectorBadge("architecture", symbol: "cpu", title: String(localized: "Universal", bundle: .greeceKit, comment: "Badge: a program that runs on both Apple silicon and Intel Macs"), tone: .neutral,
                                  help: String(localized: "Runs natively on Apple silicon and Intel Macs.", bundle: .greeceKit))
        case .appleSilicon:
            return InspectorBadge("architecture", symbol: "cpu", title: String(localized: "Apple Silicon", bundle: .greeceKit, comment: "Badge: a program that runs only on Macs with Apple silicon"), tone: .neutral,
                                  help: String(localized: "Runs natively on Apple silicon only. Intel Macs can’t run it.", bundle: .greeceKit))
        case .intel:
            return InspectorBadge("architecture", symbol: "exclamationmark.triangle", title: String(localized: "Intel Only", bundle: .greeceKit, comment: "Badge: a program built only for Intel Macs"), tone: .caution,
                                  help: String(localized: "Built for Intel only. On Apple silicon it needs Rosetta, which future versions of macOS won’t include.", bundle: .greeceKit))
        case .other(let names):
            return InspectorBadge("architecture", symbol: "cpu", title: names.joined(separator: ", "), tone: .neutral)
        }
    }
}
