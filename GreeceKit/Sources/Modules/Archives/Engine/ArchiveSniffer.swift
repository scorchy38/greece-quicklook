import Foundation

/// Kinds of software package Greece reads metadata from.
enum PackageKind: String, Sendable {
    case wheel, jar, war, ear, apk, aab, nuget, vsix, xpi, crx, gem, deb, rpm, npm, sdist, skill

    var title: String {
        switch self {
        case .wheel: return "Python Wheel"
        case .sdist: return "Python Source Package"
        case .jar: return "Java Archive"
        case .war: return "Web Application Archive"
        case .ear: return "Enterprise Archive"
        case .apk: return "Android Package"
        case .aab: return "Android App Bundle"
        case .nuget: return "NuGet Package"
        case .vsix: return "Visual Studio Extension"
        case .xpi: return "Firefox Extension"
        case .crx: return "Chrome Extension"
        case .gem: return "Ruby Gem"
        case .deb: return "Debian Package"
        case .rpm: return "RPM Package"
        case .npm: return "npm Package"
        case .skill: return "Agent Skill"
        }
    }

    static func forExtension(_ ext: String) -> PackageKind? {
        switch ext {
        case "whl": return .wheel
        case "jar": return .jar
        case "war": return .war
        case "ear": return .ear
        case "apk": return .apk
        case "aab": return .aab
        case "nupkg", "snupkg": return .nuget
        case "vsix": return .vsix
        case "xpi": return .xpi
        case "crx": return .crx
        case "gem": return .gem
        case "deb", "udeb": return .deb
        case "rpm": return .rpm
        case "skill": return .skill
        default: return nil
        }
    }
}

/// What an archive file is, from its first bytes and its name.
struct ArchiveIdentity: Equatable {
    enum Flavor: Equatable { case plain, comic, package(PackageKind) }
    var format: ArchiveFormat
    var flavor: Flavor
}

enum ArchiveSniffer {
    /// ZIP-based documents and formats other previewers own (Office, iWork, EPUB, 3D, apps).
    static let foreignZipExtensions: Set<String> = [
        "docx", "docm", "dotx", "dotm", "xlsx", "xlsm", "xltx", "xltm", "xlsb", "pptx", "pptm", "potx", "ppsx", "vsdx",
        "odt", "ods", "odp", "odg", "odf", "ott", "pages", "numbers", "key", "epub", "ibooks", "ipa", "xip",
        "usdz", "kmz", "sketch", "fig", "xd", "afdesign", "graffle", "mlmodel", "mlpackage", "ora", "xmind",
        "3mf", "idml", "swiftpm", "playground", "appex", "mcworld", "pkpass", "aar",
    ]
    static let comicExtensions: Set<String> = ["cbz", "cbr", "cb7", "cbt"]

    static func identify(_ file: FileInfo) -> ArchiveIdentity? {
        guard !file.isDirectory else { return nil }
        let ext = file.ext
        let bytes = file.probe.bytes

        var format = self.format(of: bytes, ext: ext)
        if format == nil {
            switch ext {
            case "zip":
                // The last part of a .z01 set starts mid-stream.
                if ArchiveVolumes.discover(file.url).kind == .spannedZIP { format = .zip }
            case "iso", "cdr", "toast":
                if isISO9660(file.url) { format = .iso }
            case "lzma", "tlz":
                if bytes.first == 0x5D { format = .lzma }
            default:
                // Middle parts of a spanned ZIP (.z02…) start mid-stream too.
                if ext.count >= 3, ext.first == "z", ext.dropFirst().allSatisfy(\.isNumber),
                   ArchiveVolumes.discover(file.url).kind == .spannedZIP { format = .zip }
            }
        }
        guard var found = format else { return nil }

        // Leave other previewers their formats.
        switch found {
        case .zip where foreignZipExtensions.contains(ext): return nil
        case .xar where ["pkg", "mpkg", "xip", "safariextz"].contains(ext): return nil
        case .gzip where ["svgz", "emz", "wmz", "vgz"].contains(ext): return nil
        case .ar:
            if bytes.count > 8 + 13, Array(bytes[8..<21]) == Array("debian-binary".utf8) { found = .deb }
            else if !["ar", "deb", "udeb"].contains(ext) { return nil }   // static libraries (.a) belong to code tools
        default: break
        }

        var flavor = ArchiveIdentity.Flavor.plain
        if comicExtensions.contains(ext) {
            flavor = .comic
        } else if let kind = PackageKind.forExtension(ext) {
            flavor = .package(kind)
        } else if found == .deb {
            flavor = .package(.deb)
        } else if found == .rpm {
            flavor = .package(.rpm)
        }
        if bytes.starts(with: Array("Cr24".utf8)) { flavor = .package(.crx) }
        return ArchiveIdentity(format: found, flavor: flavor)
    }

    /// Recognises an archive or compressor by its magic bytes.
    static func format(of bytes: [UInt8], ext: String = "") -> ArchiveFormat? {
        func starts(_ magic: [UInt8], at offset: Int = 0) -> Bool {
            bytes.count >= offset + magic.count && bytes[offset..<(offset + magic.count)].elementsEqual(magic)
        }
        if starts([0x50, 0x4B, 0x03, 0x04]) || starts([0x50, 0x4B, 0x05, 0x06]) || starts([0x50, 0x4B, 0x07, 0x08])
            || starts(Array("PK00PK".utf8)) || starts(Array("Cr24".utf8)) { return .zip }
        if starts([0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]) { return .sevenZip }
        if starts([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07]) { return .rar }
        if starts([0x1F, 0x8B, 0x08]) { return .gzip }
        if starts([0x42, 0x5A, 0x68]), bytes.count > 3, (0x31...0x39).contains(bytes[3]) { return .bzip2 }
        if starts([0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]) { return .xz }
        if starts(ZstdSource.magic) { return .zstd }
        if bytes.count >= 4, bytes[0] & 0xF0 == 0x50, starts([0x2A, 0x4D, 0x18], at: 1) { return .zstd }   // skippable frame
        if starts(Array("LZIP".utf8)) { return .lzip }
        if starts([0x1F, 0x9D]) { return .compress }
        if starts(Array("MSCF".utf8)), starts([0, 0, 0, 0], at: 4) { return .cab }
        if starts(Array("xar!".utf8)) { return .xar }
        if starts([0xED, 0xAB, 0xEE, 0xDB]) { return .rpm }
        if starts(Array("!<arch>\n".utf8)) { return .ar }
        if starts(Array("070701".utf8)) || starts(Array("070702".utf8)) || starts(Array("070707".utf8)) { return .cpio }
        if ext == "cpio", starts([0xC7, 0x71]) || starts([0x71, 0xC7]) { return .cpio }
        // LZMA-alone has no magic, only a properties byte (almost always 0x5D) and a dictionary size.
        if ["lzma", "tlz"].contains(ext), bytes.count > 13, bytes[0] == 0x5D, bytes[1] == 0 { return .lzma }
        if bytes.count >= 512 {
            if starts(Array("ustar".utf8), at: 257) || TarReader.isValidHeader(bytes[0..<512]) { return .tar }
        }
        if bytes.count >= 22, bytes[2] == 0x2D, bytes[6] == 0x2D, bytes[3] == 0x6C, [0x68, 0x7A].contains(bytes[4]) { return .lha }
        if bytes.count >= 22, bytes[2] == 0x2D, bytes[6] == 0x2D, starts(Array("pm".utf8), at: 3) { return .lha }
        return nil
    }

    /// ISO 9660 puts "CD001" at the start of the volume descriptors, 32 KB in.
    static func isISO9660(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: 32_769)) != nil, let data = try? handle.read(upToCount: 5) else { return false }
        return data == Data("CD001".utf8)
    }
}
