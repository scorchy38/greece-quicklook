import AppKit

/// A disk image of any kind macOS makes (UDIF, sparse image, sparse bundle, ASIF, raw/ISO), opened
/// read-only and without mounting: its format, partitions, and the files on its volume.
final class DiskImage {
    enum Container: Equatable { case udif, sparseImage, sparseBundle, asif, raw, encrypted }

    let url: URL
    let container: Container
    /// Bytes on disk (for sparse bundles, the sum of the bands).
    let fileSize: UInt64
    /// The virtual disk, or nil when it can't be read (encrypted).
    let device: DiskDevice?
    let udif: UDIFImage?
    let encryption: DiskEncryption?
    /// The disk size a sparse bundle declares (readable even when it's encrypted).
    private var declaredSize: UInt64?

    static let imageExtensions: Set<String> = ["dmg", "udif", "smi", "img", "iso", "cdr", "toast", "sparseimage", "sparsebundle", "asif", "dvdmedia"]

    // MARK: Detection

    /// Cheap detection from the extension and the first bytes. UDIF's trailer is at the end of the file,
    /// so `.dmg` is trusted by name; ambiguous extensions need a signature in the probe.
    static func sniff(probe: [UInt8], ext: String, isDirectory: Bool) -> Bool {
        if isDirectory { return ext == "sparsebundle" }
        func starts(_ text: String) -> Bool { probe.count >= text.utf8.count && probe.prefix(text.utf8.count).elementsEqual(Array(text.utf8)) }
        if starts("encrcdsa") { return true }
        if SparseImageDevice.isSparseImage(probe) { return ext == "sparseimage" || ext == "dmg" || (probe.count >= 8 && probe[4..<8].elementsEqual([0, 0, 0, 3])) }
        if ASIFDevice.isASIF(probe) { return ext == "asif" || (probe.count >= 12 && probe[8..<12].elementsEqual([0, 0, 2, 0])) }
        switch ext {
        case "dmg", "udif", "asif", "sparseimage": return true
        case "smi":
            // Old self-mounting images share the extension with SAMI subtitles, which are text.
            let head = String(decoding: probe.prefix(512), as: UTF8.self).lowercased()
            return !head.contains("<sami") && !head.contains("<html") && !head.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<")
        case "iso", "toast", "dvdmedia": return !starts("RIFF")
        case "cdr": return !starts("RIFF")   // CorelDRAW drawings share the extension
        case "img":
            // Raw disks start with a partition map; UDIF ones are checked by their trailer instead.
            if probe.count >= 512, probe[510] == 0x55, probe[511] == 0xAA { return true }
            if starts("ER") || (probe.count >= 520 && probe[512..<520].elementsEqual(Array("EFI PART".utf8))) { return true }
            return false
        default: return false
        }
    }

    /// Detection that may also read the 512-byte UDIF trailer, for `.img` files that hold UDIF data.
    static func sniff(_ url: URL, probe: [UInt8], ext: String, isDirectory: Bool) -> Bool {
        if sniff(probe: probe, ext: ext, isDirectory: isDirectory) { return true }
        guard !isDirectory, ext == "img" || ext == "dmg" else { return false }
        return UDIFImage.trailer(of: url) != nil
    }

    // MARK: Opening

    init(url: URL) throws {
        self.url = url
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { throw DiskImageError.notADiskImage }
        if isDirectory.boolValue {
            let bundle = try SparseBundleDevice(url: url)
            declaredSize = bundle.size
            container = bundle.isEncrypted ? .encrypted : .sparseBundle
            device = bundle.isEncrypted ? nil : bundle
            udif = nil
            encryption = bundle.isEncrypted ? (try? Data(contentsOf: url.appendingPathComponent("token"))).flatMap { DiskEncryption(header: $0.prefix(4096)) } : nil
            let bands = url.appendingPathComponent("bands")
            let files = (try? FileManager.default.contentsOfDirectory(at: bands, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            fileSize = files.prefix(100_000).reduce(0) { $0 + UInt64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
            return
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let head = try handle.read(upToCount: 4096) ?? Data()
        let end = try handle.seekToEnd()
        fileSize = end
        let probe = [UInt8](head)

        if let header = DiskEncryption(header: head) {
            container = .encrypted; encryption = header; device = nil; udif = nil
            return
        }
        if end >= 8 {
            try handle.seek(toOffset: end - 8)
            if let tail = try handle.read(upToCount: 8), let v1 = DiskEncryption(trailer: tail) {
                container = .encrypted; encryption = v1; device = nil; udif = nil
                return
            }
        }
        encryption = nil
        if SparseImageDevice.isSparseImage(probe) {
            container = .sparseImage; device = try SparseImageDevice(url: url); udif = nil
        } else if ASIFDevice.isASIF(probe) {
            container = .asif; device = try ASIFDevice(url: url); udif = nil
        } else if UDIFImage.trailer(of: url) != nil {
            let image = try UDIFImage(url: url)
            container = .udif; device = image; udif = image
        } else {
            container = .raw; device = try FileDiskDevice(url: url); udif = nil
        }
    }

    // MARK: Facts

    /// hdiutil's format code ("UDZO") and a plain description ("Compressed (zlib)").
    var format: (code: String, description: String, compression: String?) {
        switch container {
        case .udif: return udif!.format
        case .sparseImage: return ("UDSP", String(localized: "Sparse image", bundle: .greeceKit, comment: "A disk image format"), nil)
        case .sparseBundle: return ("UDSB", String(localized: "Sparse bundle", bundle: .greeceKit, comment: "A disk image format"), nil)
        case .asif: return ("ASIF", String(localized: "Apple sparse image", bundle: .greeceKit, comment: "A disk image format"), nil)
        case .encrypted: return ("", String(localized: "Encrypted", bundle: .greeceKit, comment: "A disk image that needs a password to open"), nil)
        case .raw:
            if let device, FileSystemKind.detect(device) == .iso9660 {
                return ("ISO", String(localized: "CD/DVD image (ISO 9660)", bundle: .greeceKit, comment: "A disk image format"), nil)
            }
            return url.pathExtension.lowercased() == "cdr" ? ("UDTO", String(localized: "DVD/CD master", bundle: .greeceKit, comment: "A disk image format"), nil)
                                                           : ("RAW", String(localized: "Raw disk image", bundle: .greeceKit, comment: "A disk image format"), nil)
        }
    }

    /// The size of the disk inside, when known.
    var virtualSize: UInt64? {
        if let device { return device.size }
        if let declaredSize, declaredSize > 0 { return declaredSize }
        return encryption?.dataSize.flatMap { $0 > 0 ? $0 : nil }
    }

    /// Where the image's code signature is (UDIF only): signed and notarized images keep it after the data.
    var codeSignatureRange: (offset: UInt64, length: UInt64)? {
        guard let trailer = udif?.trailer, trailer.codeSignatureLength > 0, trailer.codeSignatureLength <= 16 << 20,
              trailer.codeSignatureOffset < fileSize, trailer.codeSignatureLength <= fileSize - trailer.codeSignatureOffset else { return nil }
        return (trailer.codeSignatureOffset, trailer.codeSignatureLength)
    }

    private var cachedMap: PartitionMap?

    var partitionMap: PartitionMap {
        if let cachedMap { return cachedMap }
        let map = device.map(PartitionMap.read) ?? PartitionMap(scheme: .none, partitions: [])
        cachedMap = map
        return map
    }

    // MARK: Volume

    struct ContainedApp {
        var path: String
        var name: String
        var version: String?
        var build: String?
        var bundleID: String?
        var minimumSystem: String?
        var icon: NSImage?
    }

    struct Contents {
        var volumeName: String
        var fileSystem: FileSystemKind
        var entries: [VolumeEntry]
        var truncated: Bool
        var usedBytes: UInt64?
        var capacity: UInt64?
        var apps: [ContainedApp]
        var applicationsLink: Bool
        var backgroundImage: String?
        /// Readable volumes beyond the one listed.
        var otherVolumes: Int

        var fileCount: Int { entries.lazy.filter { !$0.isDirectory }.count }
        var folderCount: Int { entries.lazy.filter { $0.isDirectory }.count }
        var totalBytes: UInt64 { entries.reduce(0) { $1.isDirectory ? $0 : $0.saturatingAdd($1.size) } }
    }

    /// The first readable volume.
    func openVolume() -> DiskFileSystem? {
        guard let device else { return nil }
        var candidates = partitionMap.readable.map { (SliceDevice(device, start: $0.offset, length: $0.length) as DiskDevice, $0.fileSystem!) }
        // Hybrid ISOs carry an MBR or GPT for USB booting; the ISO file system spans the whole disk.
        if candidates.isEmpty, FileSystemKind.detect(device) == .iso9660 { candidates = [(device, .iso9660)] }
        for (slice, kind) in candidates {
            if let volume = try? DiskFileSystems.open(slice, kind: kind) { return volume }
        }
        return nil
    }

    /// Lists the volume and reads the apps on it, within the limits.
    func contents(limit: Int = 50_000, deadline: DiskDeadline = DiskDeadline(seconds: 1.5)) -> Contents? {
        guard let volume = openVolume(), var listing = try? volume.entries(limit: limit, deadline: deadline) else { return nil }
        // File system bookkeeping that Finder never shows.
        listing.entries.removeAll { entry in
            let first = entry.path.split(separator: "/", maxSplits: 1).first.map(String.init) ?? entry.path
            return DiskImage.systemItems.contains(first)
        }
        let topLevel = listing.entries.filter { !$0.path.contains("/") }
        var apps: [ContainedApp] = []
        for entry in topLevel where entry.isDirectory && entry.path.lowercased().hasSuffix(".app") {
            if apps.count >= 8 || deadline.expired { break }
            apps.append(DiskImage.readApp(entry.path, on: volume))
        }
        let link = topLevel.contains { entry in
            entry.isSymlink && (entry.path == "Applications" || ((try? volume.linkTarget(entry.path)) ?? nil) == "/Applications")
        }
        let background = listing.entries.first { entry in
            let lower = entry.path.lowercased()
            return !entry.isDirectory && (lower.hasPrefix(".background/") || lower.hasPrefix(".background.")) &&
                ["png", "jpg", "jpeg", "tif", "tiff", "heic"].contains((lower as NSString).pathExtension)
        }?.path
        let readable = partitionMap.readable.count
        return Contents(volumeName: volume.volumeName, fileSystem: volume.kind, entries: listing.entries, truncated: listing.truncated,
                        usedBytes: volume.usedBytes, capacity: volume.capacity, apps: apps, applicationsLink: link,
                        backgroundImage: background, otherVolumes: max(0, readable - 1))
    }

    static let systemItems: Set<String> = [".fseventsd", ".Trashes", ".Spotlight-V100", ".DocumentRevisions-V100", ".TemporaryItems",
                                           ".HFS+ Private Directory Data\r", "\u{0}\u{0}\u{0}\u{0}HFS+ Private Data", ".journal",
                                           ".journal_info_block", ".PKInstallSandboxManager-SystemSoftware"]

    static func readApp(_ path: String, on volume: DiskFileSystem) -> ContainedApp {
        var app = ContainedApp(path: path, name: (path as NSString).deletingPathExtension)
        guard let data = try? volume.readFile(path + "/Contents/Info.plist", limit: 1 << 20),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else { return app }
        func text(_ key: String) -> String? { (plist[key] as? String).map { Format.clean($0, limit: 120) }.flatMap { $0.isEmpty ? nil : $0 } }
        app.name = text("CFBundleDisplayName") ?? text("CFBundleName") ?? app.name
        app.version = text("CFBundleShortVersionString")
        app.build = text("CFBundleVersion")
        app.bundleID = text("CFBundleIdentifier")
        app.minimumSystem = text("LSMinimumSystemVersion")
        if var icon = text("CFBundleIconFile"), !icon.contains("/"), !icon.contains("..") {
            if (icon as NSString).pathExtension.isEmpty { icon += ".icns" }
            if let iconData = try? volume.readFile(path + "/Contents/Resources/" + icon, limit: 8 << 20) {
                app.icon = NSImage(data: iconData)
            }
        }
        return app
    }
}
