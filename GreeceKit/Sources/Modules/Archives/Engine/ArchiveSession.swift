import Foundation

/// An archive opened for browsing: lists its entries (progressively, for big ones) and extracts any
/// single entry on demand. Extraction is thread-safe; each call opens its own reader.
final class ArchiveSession: @unchecked Sendable {
    let url: URL
    let volumes: ArchiveVolumes
    /// What the outermost bytes are (gzip for a .tar.gz).
    let format: ArchiveFormat
    let archiveSize: UInt64

    /// How entries are read.
    enum Layout {
        /// Greece's own central-directory reader.
        case zip(RandomAccessFile, spanned: Bool)
        /// Anything libarchive opens directly, including compressed tarballs.
        case libarchive(Origin, LibArchive.Formats)
        /// File list from the RPM header; files from the cpio payload.
        case rpm(RPMHeader, payload: Origin)
    }

    /// Where libarchive's bytes come from. Re-creatable, so every extraction gets a fresh reader.
    indirect enum Origin {
        case files([URL])
        case window(RandomAccessFile, offset: UInt64, length: UInt64)
        case memory(Data)
        /// Decoded by Greece's zstd first.
        case zstd(Origin)
    }

    private(set) var layout: Layout
    /// Package metadata members found while opening (a .deb's control archive, a gem's metadata).
    private(set) var packageMembers: [String: Data] = [:]

    init(url: URL, format hint: ArchiveFormat? = nil) throws {
        self.url = url
        volumes = ArchiveVolumes.discover(url)
        let probe = FileProbe(url: volumes.first, length: 8192)
        let ext = url.pathExtension.lowercased()
        guard let detected = ArchiveSniffer.format(of: probe.bytes, ext: ext) ?? (volumes.kind == .spannedZIP ? .zip : nil)
                ?? (ArchiveSniffer.isISO9660(url) ? .iso : nil) ?? hint else {
            throw ArchiveError.unsupported("Greece doesn’t recognise this archive’s format.")
        }
        format = detected
        archiveSize = volumes.urls.reduce(UInt64(0)) { total, part in
            total.saturatingAdd(UInt64((try? part.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0))
        }

        switch detected {
        case .zip:
            layout = .zip(try RandomAccessFile(volumes.urls), spanned: volumes.kind == .spannedZIP)
        case .zstd:
            layout = .libarchive(.zstd(.files(volumes.urls)), [.containers, .raw])
        case .rpm:
            let file = try RandomAccessFile(volumes.first)
            let header = try RPMHeader(file)
            let payload = Origin.window(file, offset: header.payloadOffset, length: file.size - min(header.payloadOffset, file.size))
            layout = .rpm(header, payload: header.payloadCompressor == "zstd" ? .zstd(payload) : payload)
        case .ar, .deb:
            let file = try RandomAccessFile(volumes.first)
            let members = ARArchive.members(file)
            if let data = members.first(where: { $0.name.hasPrefix("data.tar") }) {
                let window = Origin.window(file, offset: data.offset, length: data.size)
                layout = .libarchive(data.name.hasSuffix(".zst") ? .zstd(window) : window, .tarOnly)
                if let control = members.first(where: { $0.name.hasPrefix("control.tar") }), control.size < 16 * 1024 * 1024 {
                    let controlWindow = Origin.window(file, offset: control.offset, length: control.size)
                    packageMembers = ArchiveSession.smallFiles(in: control.name.hasSuffix(".zst") ? .zstd(controlWindow) : controlWindow,
                                                               named: ["control", "conffiles", "md5sums"])
                }
            } else {
                layout = .libarchive(.files(volumes.urls), .containers)
            }
        case .gzip, .bzip2, .xz, .lzma, .lzip, .compress:
            layout = .libarchive(.files(volumes.urls), [.containers, .raw])
        default:
            layout = .libarchive(.files(volumes.urls), .containers)
        }

        if case .tar = detected, ext == "gem" { try openGem() }
    }

    /// A gem is a plain tar of metadata.gz and data.tar.gz; its files live in the inner tarball.
    private func openGem() throws {
        let members = ArchiveSession.smallFiles(in: .files(volumes.urls), named: ["metadata.gz", "data.tar.gz"], limit: 256 * 1024 * 1024)
        if let metadata = members["metadata.gz"] { packageMembers["metadata.gz"] = metadata }
        if let data = members["data.tar.gz"] { layout = .libarchive(.memory(data), .tarOnly) }
    }

    /// Reads a few named members (matched by last path component) wholly into memory.
    static func smallFiles(in origin: Origin, named names: Set<String>, limit: UInt64 = 4 * 1024 * 1024) -> [String: Data] {
        guard let reader = try? open(origin, formats: [.tarOnly, .containers]) else { return [:] }
        var found: [String: Data] = [:]
        var seen = 0
        while found.count < names.count, seen < 10_000, let header = try? reader.nextHeader() {
            seen += 1
            let (entry, _) = reader.entry(header, unicodeNames: false)
            let name = (entry.path as NSString).lastPathComponent
            guard names.contains(name), found[name] == nil, !entry.isDirectory else { continue }
            var data = Data()
            if let (_, complete) = try? reader.readData(limit: limit, { data.append(contentsOf: $0) }), complete { found[name] = data }
        }
        return found
    }

    static func open(_ origin: Origin, formats: LibArchive.Formats) throws -> LibArchive {
        switch origin {
        case .files(let urls): return try LibArchive(.files(urls), formats: formats)
        case .window(let file, let offset, let length): return try LibArchive(.window(file, offset: offset, length: length), formats: formats)
        case .memory(let data): return try LibArchive(.memory(data), formats: formats)
        case .zstd(let inner): return try LibArchive(.stream(ZstdSource(try source(inner))), formats: formats)
        }
    }

    private static func source(_ origin: Origin) throws -> ByteSource {
        switch origin {
        case .files(let urls): return RangeSource(try RandomAccessFile(urls))
        case .window(let file, let offset, let length): return RangeSource(file, offset: offset, length: length)
        case .memory(let data): return MemorySource(data)
        case .zstd(let inner): return try ZstdSource(try source(inner))
        }
    }

    // MARK: - Listing

    func makeLister() -> ArchiveLister { ArchiveLister(session: self) }

    /// Lists everything (up to the entry limit), optionally within a time budget.
    func listAll(budget: TimeInterval? = nil) throws -> ArchiveListing {
        let lister = makeLister()
        let deadline = budget.map { CFAbsoluteTimeGetCurrent() + $0 }
        while !lister.isFinished {
            try lister.step(until: deadline ?? .infinity)
            if let deadline, CFAbsoluteTimeGetCurrent() >= deadline, !lister.isFinished {
                lister.stop()
                break
            }
        }
        return lister.listing
    }

    // MARK: - Extraction

    /// Streams an entry's bytes, up to `limit`. Returns how many were delivered and whether that was all.
    @discardableResult
    func extract(_ entry: ArchiveEntry, limit: UInt64, cancel: CancelToken? = nil,
                 deliver: (UnsafeRawBufferPointer) throws -> Void) throws -> (UInt64, Bool) {
        if entry.isDirectory { throw ArchiveError.unsupported("Folders have no contents to extract.") }
        if entry.isEncrypted { throw ArchiveError.encrypted }
        switch layout {
        case .zip(let file, _):
            if ZIPReader.canExtract(entry) {
                return try ZIPReader.extract(entry, from: file, limit: limit, cancel: cancel, deliver: deliver)
            }
            // bzip2, LZMA, xz, PPMd inside a ZIP: libarchive walks the same central directory in the same order.
            return try extractByIndex(entry, origin: .files(volumes.urls), formats: .containers, limit: limit, cancel: cancel, deliver: deliver)
        case .libarchive(let origin, let formats):
            return try extractByIndex(entry, origin: origin, formats: formats, limit: limit, cancel: cancel, deliver: deliver)
        case .rpm(_, let payload):
            let reader = try ArchiveSession.open(payload, formats: .cpioOnly)
            let wanted = ArchiveSession.normalized(entry.path)
            while let header = try reader.nextHeader() {
                if cancel?.isCancelled == true { throw ArchiveError.cancelled }
                let (candidate, _) = reader.entry(header, unicodeNames: false)
                if ArchiveSession.normalized(candidate.path) == wanted {
                    return try reader.readData(limit: limit, cancel: cancel, deliver)
                }
            }
            throw ArchiveError.corrupt("“\((entry.path as NSString).lastPathComponent)” isn’t in the payload")
        }
    }

    private func extractByIndex(_ entry: ArchiveEntry, origin: Origin, formats: LibArchive.Formats, limit: UInt64,
                                cancel: CancelToken?, deliver: (UnsafeRawBufferPointer) throws -> Void) throws -> (UInt64, Bool) {
        let reader = try ArchiveSession.open(origin, formats: formats)
        while let _ = try reader.nextHeader() {
            if cancel?.isCancelled == true { throw ArchiveError.cancelled }
            if reader.headerIndex == entry.index { return try reader.readData(limit: limit, cancel: cancel, deliver) }
            if reader.headerIndex > entry.index { break }
        }
        throw ArchiveError.corrupt("“\((entry.path as NSString).lastPathComponent)” couldn’t be found again")
    }

    /// Extracts many entries in archive order with one reader, so a solid archive decodes once.
    /// `deliver` gets each entry's bytes (nil if it was over `limit` or unreadable); return false to stop.
    func extractInOrder(_ entries: [ArchiveEntry], limit: UInt64, cancel: CancelToken? = nil,
                        deliver: (ArchiveEntry, Data?) -> Bool) {
        let wanted = Dictionary(entries.map { ($0.index, $0) }, uniquingKeysWith: { first, _ in first })
        if case .libarchive(let origin, let formats) = layout, let reader = try? ArchiveSession.open(origin, formats: formats) {
            var remaining = wanted.count
            while remaining > 0, cancel?.isCancelled != true, let header = try? reader.nextHeader() {
                _ = header
                guard let entry = wanted[reader.headerIndex] else { continue }
                remaining -= 1
                var data = Data()
                let result = try? reader.readData(limit: limit, cancel: cancel) { data.append(contentsOf: $0) }
                if !deliver(entry, result?.1 == true ? data : nil) { return }
            }
            return
        }
        for entry in entries.sorted(by: { $0.index < $1.index }) where cancel?.isCancelled != true {
            if !deliver(entry, data(entry, limit: limit, cancel: cancel)) { return }
        }
    }

    /// True when any single entry can be read without decoding the ones before it.
    var hasRandomAccess: Bool {
        if case .zip = layout { return true }
        return false
    }

    /// An entry's bytes in memory, or nil if it's larger than `limit` or can't be read.
    func data(_ entry: ArchiveEntry, limit: UInt64, cancel: CancelToken? = nil) -> Data? {
        var data = Data()
        if entry.size > 0, entry.size <= limit { data.reserveCapacity(Int(entry.size)) }
        guard let (_, complete) = try? extract(entry, limit: limit, cancel: cancel, deliver: { data.append(contentsOf: $0) }), complete else { return nil }
        return data
    }

    static func normalized(_ path: String) -> String {
        var path = path.replacingOccurrences(of: "\\", with: "/")
        while path.hasPrefix("./") { path.removeFirst(2) }
        while path.hasPrefix("/") { path.removeFirst() }
        while path.hasSuffix("/") { path.removeLast() }
        return path
    }
}

/// Bytes already in memory, read forwards.
final class MemorySource: ByteSource {
    private let data: Data
    private var position = 0
    init(_ data: Data) { self.data = data }
    func read(upTo count: Int) throws -> Data {
        let end = min(data.count, position + max(count, 0))
        defer { position = end }
        return data.subdata(in: (data.startIndex + position)..<(data.startIndex + end))
    }
}

/// Lists an archive a batch at a time, so a huge one can appear while it's still being read.
final class ArchiveLister {
    let session: ArchiveSession
    private(set) var listing: ArchiveListing
    private(set) var isFinished = false
    private var reader: LibArchive?
    private var pendingNames: [(index: Int, bytes: [UInt8])] = []
    private var encoding: NameDecoder.Candidate?
    private var unicodeNames = false
    private var started = false

    init(session: ArchiveSession) {
        self.session = session
        listing = ArchiveListing(format: session.format, container: .other, entries: [], archiveSize: session.archiveSize)
        listing.volumes = session.volumes.count
    }

    func stop() {
        if !isFinished { listing.truncated = true }
        isFinished = true
        reader = nil
    }

    /// Reads entries until `deadline` or the end. Returns the entries added by this step.
    @discardableResult
    func step(until deadline: CFAbsoluteTime) throws -> [ArchiveEntry] {
        guard !isFinished else { return [] }
        defer { if isFinished { reader = nil } }
        let before = listing.entries.count

        switch session.layout {
        case .zip(let file, let spanned):
            let read = try ZIPReader.read(file, spanned: spanned)
            listing = read
            listing.archiveSize = session.archiveSize
            listing.volumes = session.volumes.count
            isFinished = true
            return listing.entries
        case .rpm(let header, _):
            listing.format = .rpm
            listing.entries = header.entries()
            listing.truncated = listing.entries.count >= ArchiveReader.entryLimit
            listing.variant = header.isSource ? "Source RPM" : nil
            listing.compression = ArchiveFormat(rawValue: header.payloadCompressor)
            isFinished = true
            return listing.entries
        case .libarchive(let origin, let formats):
            if !started {
                started = true
                do {
                    reader = try ArchiveSession.open(origin, formats: formats)
                } catch ArchiveError.encrypted {
                    listing.headerEncrypted = true
                    isFinished = true
                    return []
                }
            }
            guard let reader else { isFinished = true; return [] }
            var count = 0
            while true {
                let header: OpaquePointer?
                do {
                    header = try reader.nextHeader()
                } catch ArchiveError.encrypted {
                    listing.headerEncrypted = true
                    isFinished = true
                    break
                } catch {
                    if listing.entries.isEmpty && !(reader.format != nil || reader.isRaw) { throw error }
                    listing.damage = (error as? ArchiveError).flatMap { if case .corrupt(let reason) = $0 { return reason } else { return nil } } ?? error.localizedDescription
                    isFinished = true
                    break
                }
                guard let header else { isFinished = true; break }
                if listing.entries.isEmpty && count == 0 { describe(reader) }
                if reader.isRaw {
                    try readSingleFile(reader)
                    isFinished = true
                    break
                }
                let (entry, raw) = reader.entry(header, unicodeNames: unicodeNames)
                var adjusted = entry
                adjusted.path = ArchiveSession.normalized(entry.path) + (entry.isDirectory ? "/" : "")
                if adjusted.path == "/" || adjusted.path.isEmpty { continue }
                if let raw { pendingNames.append((listing.entries.count, raw)) }
                listing.entries.append(adjusted)
                count += 1
                if listing.entries.count >= ArchiveReader.entryLimit { listing.truncated = true; isFinished = true; break }
                if count % 64 == 0, CFAbsoluteTimeGetCurrent() >= deadline { break }
            }
            if isFinished, reader.isEmpty, listing.entries.isEmpty { listing.container = .other }
            resolveNames()
        }
        return Array(listing.entries[before...])
    }

    private func describe(_ reader: LibArchive) {
        listing.variant = reader.formatName
        if reader.isRaw {
            listing.container = .compressedFile
            listing.compression = session.format == .zstd ? .zstd : reader.compression ?? session.format
            listing.format = listing.compression ?? session.format
            return
        }
        let inner = reader.format ?? session.format
        listing.format = session.format == .deb || session.format == .ar && inner == .tar ? .deb : inner
        listing.container = inner == .tar && listing.format != .deb ? .tar : .other
        if session.format == .zstd { listing.compression = .zstd } else { listing.compression = reader.compression }
        if case .libarchive(.memory, _) = session.layout { listing.compression = nil }
        unicodeNames = [.sevenZip, .xar, .iso, .rar].contains(inner)
        if listing.format == .deb { listing.compression = nil }
    }

    /// A lone compressed file: name it, measure it and keep its beginning for an inline preview.
    private func readSingleFile(_ reader: LibArchive) throws {
        var name = (session.volumes.displayName as NSString).deletingPathExtension
        if session.format == .gzip, let original = GzipHeader.originalName(session.volumes.first) { name = original }
        if name.isEmpty { name = "data" }
        var prefix = Data()
        var total: UInt64 = 0
        let deadline = CFAbsoluteTimeGetCurrent() + 2
        var measured = true
        struct OutOfTime: Error {}
        do {
            // Measure by decoding, but give up on the exact size of something enormous.
            try reader.readData(limit: .max) { chunk in
                if prefix.count < TextFile.defaultLimit {
                    prefix.append(contentsOf: chunk.prefix(TextFile.defaultLimit - prefix.count))
                }
                total = total.saturatingAdd(UInt64(chunk.count))
                if CFAbsoluteTimeGetCurrent() > deadline { throw OutOfTime() }
            }
        } catch is OutOfTime {
            measured = false
        } catch {
            listing.damage = error.localizedDescription
        }
        if session.format == .gzip, session.volumes.count == 1, let isize = GzipHeader.trailerSize(session.volumes.first), isize >= total {
            total = isize
            measured = true
        }
        let modified = try? session.volumes.first.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        var entry = ArchiveEntry(path: name, isDirectory: false, size: total, compressedSize: session.archiveSize, modified: modified)
        entry.index = 0
        listing.entries = [entry]
        listing.innerPrefix = prefix
        listing.truncated = !measured
    }

    /// Names libarchive couldn't decode share one legacy encoding: decide it once, from all of them.
    private func resolveNames() {
        guard !pendingNames.isEmpty else { return }
        if encoding == nil {
            encoding = NameDecoder.choose(pendingNames.map(\.bytes), fallback: nil)
            listing.nameEncoding = encoding?.name
        }
        guard let encoding else { return }
        for (index, bytes) in pendingNames where index < listing.entries.count {
            let isDirectory = listing.entries[index].isDirectory
            listing.entries[index].path = ArchiveSession.normalized(NameDecoder.decode(bytes, with: encoding)) + (isDirectory ? "/" : "")
        }
        pendingNames.removeAll()
    }
}
