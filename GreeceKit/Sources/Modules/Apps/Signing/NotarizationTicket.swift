import Foundation

/// A stapled notarization ticket ("s8ch"): Apple's signed list of the code directory hashes it
/// notarized, and when. `stapler` writes it to `Contents/CodeResources` in bundles, into the code
/// signature of disk images, and to the end of flat installer packages.
///
/// Layout: "s8ch", u32 version, u32 certificate-chain length, u32 body length, the chain (DER),
/// then the body: "g8tk", u16 version, u16 hash length, u32 count, u32 reserved, u64 time (Unix),
/// then `count` entries of a hash-type byte and `hash length` bytes, then Apple's signature.
struct NotarizationTicket: Equatable {
    struct Entry: Equatable {
        let hashType: UInt8
        let hash: Data
    }

    let notarizedAt: Date?
    let entries: [Entry]

    static let magic: [UInt8] = Array("s8ch".utf8)

    init?(data: Data) {
        let reader = BinaryReader(data)
        guard data.count >= 16, data.prefix(4).elementsEqual(Self.magic),
              let chainLength = reader.u32(at: 8).map(Int.init), let bodyLength = reader.u32(at: 12).map(Int.init) else { return nil }
        let body = 16 + chainLength
        guard bodyLength >= 24, reader.has(bodyLength, at: body),
              reader.bytes(at: body, count: 4) == Data("g8tk".utf8),
              let hashLength = reader.u16(at: body + 6).map(Int.init), (16...64).contains(hashLength),
              let declared = reader.u32(at: body + 8).map(Int.init) else { return nil }
        let seconds = reader.u64(at: body + 16) ?? 0
        notarizedAt = seconds > 1_500_000_000 && seconds < 4_000_000_000 ? Date(timeIntervalSince1970: TimeInterval(seconds)) : nil
        let fits = (bodyLength - 24) / (hashLength + 1)
        var entries: [Entry] = []
        for index in 0..<min(declared, fits, 100_000) {
            let position = body + 24 + index * (hashLength + 1)
            guard let type = reader.u8(at: position), let hash = reader.bytes(at: position + 1, count: hashLength) else { break }
            entries.append(Entry(hashType: type, hash: hash))
        }
        self.entries = entries
    }

    /// Finds a ticket inside a larger blob (a signature superblob, the tail of a package).
    init?(searching data: Data) {
        guard let start = data.firstRange(of: Self.magic) else { return nil }
        self.init(data: data.subdata(in: (data.startIndex + start)..<data.endIndex))
    }

    /// True if the ticket lists this code directory hash (full or truncated, any length).
    func covers(_ cdhash: Data) -> Bool {
        guard !cdhash.isEmpty else { return false }
        return entries.contains { entry in
            let length = min(entry.hash.count, cdhash.count)
            return entry.hash.prefix(length) == cdhash.prefix(length)
        }
    }

    /// Reads a bundle's stapled ticket, if any. Bundles keep it in `Contents/CodeResources` (a file).
    static func stapled(inBundle url: URL) -> NotarizationTicket? {
        for candidate in [url.appendingPathComponent("Contents/CodeResources"), url.appendingPathComponent("CodeResources")] {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory), !isDirectory.boolValue,
                  let size = (try? candidate.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size < 4 << 20,
                  let data = try? Data(contentsOf: candidate) else { continue }
            if let ticket = NotarizationTicket(data: data) { return ticket }
        }
        return nil
    }

    /// Reads a ticket from the last `window` bytes of a file (flat packages append it).
    static func stapled(atEndOf url: URL, window: Int = 256 * 1024) -> NotarizationTicket? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return nil }
        let start = end > UInt64(window) ? end - UInt64(window) : 0
        guard (try? handle.seek(toOffset: start)) != nil, let tail = try? handle.readToEnd() else { return nil }
        // The last ticket wins: re-stapling appends a fresh one.
        var offset = 0
        var found: NotarizationTicket?
        while let position = tail.firstRange(of: magic, from: offset) {
            if let ticket = NotarizationTicket(data: tail.subdata(in: position..<tail.count)) { found = ticket }
            offset = position + 4
        }
        return found
    }
}
