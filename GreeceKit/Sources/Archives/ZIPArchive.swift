import Foundation

/// A ZIP read for its members: the container behind IPA and APK apps, EPUB books, KMZ maps and
/// zipped shapefiles, 3MF models, dotLottie animations and Procreate swatches.
///
/// The central directory is read once, at most `memberLimit` members. Members are read on
/// demand with `pread` (or from memory), so a large archive costs only the members opened.
/// Every read is bounded: a member is refused when it claims, or turns out, to be larger than
/// the caller's limit, and names that climb out of the archive (`..`) are never found.
final class ZIPArchive {
    static let memberLimit = 200_000

    let source: any RandomAccessSource
    let members: [ZIPMember]
    /// The listing stopped at `memberLimit`.
    let truncated: Bool
    /// Where the central directory starts: an APK Signing Block ends right before it.
    let centralDirectoryOffset: UInt64

    private let exact: [String: Int]
    private let lock = NSLock()
    private var lenient: (normalized: [String: Int], folded: [String: Int])?

    /// Maps the file, as every module's reader did: pages are read only when a member touches them,
    /// and Deflate reads its input straight from the mapping.
    convenience init(url: URL, memberLimit: Int = ZIPArchive.memberLimit) throws {
        try self.init(source: InMemoryFile(Data(contentsOf: url, options: .alwaysMapped)), memberLimit: memberLimit)
    }

    convenience init(data: Data, memberLimit: Int = ZIPArchive.memberLimit) throws {
        try self.init(source: InMemoryFile(data), memberLimit: memberLimit)
    }

    init(source: any RandomAccessSource, memberLimit: Int = ZIPArchive.memberLimit) throws {
        let directory = try ZIPReader.directory(source, limit: memberLimit)
        self.source = source
        members = directory.members
        truncated = directory.truncated
        centralDirectoryOffset = directory.offset
        var exact: [String: Int] = [:]
        exact.reserveCapacity(members.count)
        // Backwards, so the first of several members with one name is the one kept.
        for index in members.indices.reversed() { exact[members[index].path] = index }
        self.exact = exact
    }

    /// The archive's size in bytes.
    var size: UInt64 { source.size }

    // MARK: - Finding members

    /// The member stored under exactly this name (the first, if several are).
    func member(_ path: String) -> ZIPMember? {
        guard !Self.hasParentComponent(path), let index = exact[path] else { return nil }
        return members[index]
    }

    /// The member with this name, forgiving what archive makers and the files inside them get
    /// wrong: backslashes, a leading "./" or "/", and letter case (an exact match wins).
    func member(named path: String) -> ZIPMember? {
        let wanted = Self.normalize(path)
        guard !wanted.isEmpty, !Self.hasParentComponent(wanted) else { return nil }
        if let index = exact[path] ?? exact[wanted] { return members[index] }
        let indexes = lenientIndexes()
        guard let index = indexes.normalized[wanted] ?? indexes.folded[wanted.lowercased()] else { return nil }
        return members[index]
    }

    private func lenientIndexes() -> (normalized: [String: Int], folded: [String: Int]) {
        lock.lock()
        defer { lock.unlock() }
        if let lenient { return lenient }
        var normalized: [String: Int] = [:], folded: [String: Int] = [:]
        normalized.reserveCapacity(members.count)
        folded.reserveCapacity(members.count)
        for (index, member) in members.enumerated() {
            let name = Self.normalize(member.path)
            if normalized[name] == nil { normalized[name] = index }
            let lower = name.lowercased()
            if folded[lower] == nil { folded[lower] = index }
        }
        lenient = (normalized, folded)
        return (normalized, folded)
    }

    /// "/" separators, no leading "./" or "/".
    static func normalize(_ path: String) -> String {
        var path = path.contains("\\") ? path.replacingOccurrences(of: "\\", with: "/") : path
        while true {
            if path.hasPrefix("./") { path.removeFirst(2) } else if path.hasPrefix("/") { path.removeFirst() } else { break }
        }
        return path
    }

    /// True if any component is "..", which would climb out of the archive.
    static func hasParentComponent(_ path: String) -> Bool {
        guard path.contains("..") else { return false }
        return path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).contains("..")
    }

    // MARK: - Reading members

    /// A member's whole contents. Throws if it's encrypted, compressed with a method Greece
    /// doesn't decode, damaged, runs past the end of the archive, or is larger than `limit`
    /// once uncompressed, whatever its header claims: inflation stops at the limit.
    func contents(of member: ZIPMember, limit: Int) throws -> Data {
        if member.isEncrypted { throw ArchiveError.encrypted }
        guard ZIPReader.supports(member.method) else { throw ArchiveError.unsupported(ZIPReader.methodName(member.method)) }
        let limit = UInt64(max(limit, 0))
        guard member.size <= limit else { throw ArchiveError.tooLarge }
        let range = try ZIPReader.locate(localHeader: member.localHeaderOffset, compressedSize: member.compressedSize, in: source)
        guard !range.pastEnd else { throw ArchiveError.corrupt("“\((member.path as NSString).lastPathComponent)” runs past the end") }

        if member.method == 0 {
            guard range.length <= limit else { throw ArchiveError.tooLarge }
            let bytes = source.read(at: range.start, count: Int(range.length))
            return bytes.startIndex == 0 ? bytes : Data(bytes)
        }
        var output = Data()
        var complete: Bool, endedEarly: Bool
        if member.method == 8 {
            (output, complete, endedEarly) = try ZIPReader.inflateWhole(range, expectedSize: member.size, from: source, limit: limit)
        } else {
            output.reserveCapacity(Int(member.size))
            let result = try ZIPReader.extract(range, method: member.method, from: source, limit: limit) { buffer in
                if let base = buffer.baseAddress { output.append(base.assumingMemoryBound(to: UInt8.self), count: buffer.count) }
                return true
            }
            (complete, endedEarly) = (result.complete, result.endedEarly)
        }
        guard complete else { throw ArchiveError.tooLarge }
        // A cut-off stream keeps what decoded; one that decoded nothing at all is damaged.
        if endedEarly, output.isEmpty, range.length > 0 { throw ArchiveError.corrupt("damaged member") }
        return output
    }

    /// The contents of the member stored under exactly `path`, or nil if it's missing or unreadable.
    func contents(of path: String, limit: Int = 32 << 20) -> Data? {
        member(path).flatMap { try? contents(of: $0, limit: limit) }
    }

    /// The contents of the member `member(named:)` finds, or nil if it's missing or unreadable.
    func contents(named path: String, limit: Int = 32 << 20) -> Data? {
        member(named: path).flatMap { try? contents(of: $0, limit: limit) }
    }

    /// Streams a member's uncompressed bytes in chunks, never more than `maximum` of them
    /// whatever the headers claim. Return false from `body` to stop early. A member cut off by
    /// the end of the archive delivers what's there.
    func stream(_ member: ZIPMember, maximum: UInt64 = .max, chunkSize: Int = 1 << 20, _ body: (Data) throws -> Bool) throws {
        if member.isEncrypted { throw ArchiveError.encrypted }
        let range = try ZIPReader.locate(localHeader: member.localHeaderOffset, compressedSize: member.compressedSize, in: source)
        if member.method == 0 {
            // Stored: hand over the chunks as read, without copying them again.
            var position = range.start
            let end = range.start + min(range.length, maximum)
            while position < end {
                let chunk = source.read(at: position, count: Int(min(UInt64(max(chunkSize, 4096)), end - position)))
                if chunk.isEmpty { return }
                position += UInt64(chunk.count)
                if try !body(chunk.startIndex == 0 ? chunk : Data(chunk)) { return }
            }
            return
        }
        if member.method == 8 {
            // Deflate: each chunk is inflated into memory that becomes its Data, without a copy.
            try ZIPReader.inflateChunks(range, from: source, maximum: maximum, chunkSize: chunkSize, deliver: body)
            return
        }
        _ = try ZIPReader.extract(range, method: member.method, from: source, limit: maximum, chunkSize: chunkSize) { buffer in
            guard let base = buffer.baseAddress else { return true }
            return try body(Data(bytes: base, count: buffer.count))
        }
    }

    /// Raw bytes of the archive itself, e.g. the APK Signing Block before the central directory.
    func bytes(at offset: UInt64, count: Int) -> Data { source.read(at: offset, count: count) }
}
