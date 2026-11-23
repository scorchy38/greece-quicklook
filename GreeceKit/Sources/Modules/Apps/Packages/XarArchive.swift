import Foundation
import Security
import CryptoKit

/// A xar archive, the container of flat installer packages: a big-endian header, a zlib-compressed
/// XML table of contents, then a heap holding the checksum, the signatures and every member.
///
/// Header: "xar!", u16 header size, u16 version, u64 TOC compressed length, u64 TOC uncompressed
/// length, u32 checksum algorithm (0 none, 1 SHA-1, 2 MD5, 3 named in the header after byte 28).
final class XarArchive {
    struct Entry {
        let path: String
        let isDirectory: Bool
        let isSymlink: Bool
        let mode: UInt16?
        /// Extracted size.
        let size: UInt64
        /// Archived length in the heap.
        let length: UInt64
        let offset: UInt64
        let encoding: String?
        let modified: Date?
        var name: String { (path as NSString).lastPathComponent }
    }

    struct Signature {
        /// "RSA" (the classic xar signature) or "CMS".
        let style: String
        let offset: UInt64
        let size: UInt64
        /// DER certificates, leaf first.
        let certificates: [Data]
    }

    enum Failure: Error, Equatable { case notXar, corrupt(String), tooLarge }

    static let magic: [UInt8] = Array("xar!".utf8)
    static let tocCompressedLimit = 64 << 20
    static let tocLimit = 128 << 20
    static let entryLimit = 200_000

    let url: URL
    let data: Data
    let version: UInt16
    let checksumStyle: String
    let tocCompressedLength: Int
    let tocLength: Int
    let toc: PackageXMLNode
    let entries: [Entry]
    let entriesTruncated: Bool
    let heapStart: Int
    let creationDate: Date?
    let signature: Signature?
    let cmsSignature: Signature?
    /// The checksum stored in the heap, and whether it matches the compressed TOC.
    let storedChecksum: Data?
    let checksumMatches: Bool?

    private let index: [String: Int]

    init(url: URL) throws {
        self.url = url
        data = try Data(contentsOf: url, options: .alwaysMapped)
        let header = BinaryReader(data, bigEndian: true)
        guard data.count >= 28, data.prefix(4).elementsEqual(Self.magic),
              let headerSize = header.u16(at: 4).map(Int.init), headerSize >= 28, headerSize <= 4096,
              let version = header.u16(at: 6),
              let compressed = header.u64(at: 8), let uncompressed = header.u64(at: 16),
              let algorithm = header.u32(at: 24) else { throw Failure.notXar }
        guard compressed <= UInt64(Self.tocCompressedLimit), uncompressed <= UInt64(Self.tocLimit) else { throw Failure.tooLarge }
        tocCompressedLength = Int(compressed)
        tocLength = Int(uncompressed)
        guard header.has(tocCompressedLength, at: headerSize) else { throw Failure.corrupt("table of contents runs past the end") }
        self.version = version
        heapStart = headerSize + tocCompressedLength

        switch algorithm {
        case 0: checksumStyle = "none"
        case 1: checksumStyle = "sha1"
        case 2: checksumStyle = "md5"
        default: checksumStyle = header.cString(at: 28, maxLength: max(0, headerSize - 28))?.lowercased().nilIfEmpty ?? "unknown"
        }

        let compressedTOC = data.subdata(in: headerSize..<heapStart)
        // The uncompressed length is only a hint from the header; the limit is ours.
        guard let inflated = PackageDecompression.zlib(compressedTOC, limit: Self.tocLimit) else {
            throw Failure.corrupt("table of contents doesn’t decompress")
        }
        if inflated.truncated { throw Failure.tooLarge }
        let root = try PackageXMLNode.parse(inflated.data)
        guard root.name == "xar", let tocNode = root.child("toc") else { throw Failure.corrupt("no table of contents") }
        toc = tocNode

        creationDate = tocNode.value("creation-time").flatMap(Self.date)

        // Table of contents checksum: stored in the heap, computed over the compressed TOC.
        if let checksum = tocNode.child("checksum"), let offset = checksum.value("offset").flatMap(UInt64.init),
           let size = checksum.value("size").flatMap(Int.init), size > 0, size <= 64,
           case let (sum, overflow) = UInt64(heapStart).addingReportingOverflow(offset), !overflow,
           let start = Int(exactly: sum), header.has(size, at: start) {
            let stored = data.subdata(in: start..<(start + size))
            storedChecksum = stored
            let style = (checksum["style"] ?? checksumStyle).lowercased()
            checksumMatches = Self.digest(compressedTOC, style: style).map { $0 == stored }
        } else {
            storedChecksum = nil
            checksumMatches = nil
        }

        func readSignature(_ node: PackageXMLNode?) -> Signature? {
            guard let node, let offset = node.value("offset").flatMap(UInt64.init), let size = node.value("size").flatMap(UInt64.init) else { return nil }
            let certificates = node.descendants("X509Certificate", limit: 16).compactMap {
                Data(base64Encoded: $0.trimmedText, options: .ignoreUnknownCharacters)
            }
            return Signature(style: node["style"] ?? "RSA", offset: offset, size: size, certificates: certificates)
        }
        signature = readSignature(tocNode.child("signature"))
        cmsSignature = readSignature(tocNode.child("x-signature"))

        // Members: nested <file> elements, walked iteratively.
        var entries: [Entry] = []
        var truncated = false
        var stack: [(PackageXMLNode, String, Int)] = tocNode.children("file").reversed().map { ($0, "", 0) }
        while let (node, parent, depth) = stack.popLast() {
            if entries.count >= Self.entryLimit { truncated = true; break }
            let rawName = node.value("name") ?? "?"
            let name = rawName.replacingOccurrences(of: "/", with: "∕")
            let path = parent.isEmpty ? name : parent + "/" + name
            let type = node.value("type") ?? "file"
            let dataNode = node.child("data")
            entries.append(Entry(
                path: path,
                isDirectory: type == "directory",
                isSymlink: type == "symlink",
                mode: node.value("mode").flatMap { UInt16($0, radix: 8) },
                size: dataNode?.value("size").flatMap(UInt64.init) ?? 0,
                length: dataNode?.value("length").flatMap(UInt64.init) ?? 0,
                offset: dataNode?.value("offset").flatMap(UInt64.init) ?? 0,
                encoding: dataNode?.child("encoding")?["style"],
                modified: node.value("mtime").flatMap(Self.date)))
            if depth < 32 {
                for child in node.children("file").reversed() { stack.append((child, path, depth + 1)) }
            }
        }
        self.entries = entries
        entriesTruncated = truncated
        var index: [String: Int] = [:]
        for (position, entry) in entries.enumerated() where index[entry.path] == nil { index[entry.path] = position }
        self.index = index
    }

    func entry(_ path: String) -> Entry? { index[path].map { entries[$0] } }

    /// The member's decoded contents, never more than `limit` bytes.
    func contents(of entry: Entry, limit: Int) -> PackageDecompression.Output? {
        guard !entry.isDirectory, let raw = heap(offset: entry.offset, length: entry.length) else { return nil }
        let encoding = entry.encoding ?? "application/octet-stream"
        switch encoding {
        case "application/x-gzip", "application/zlib", "application/x-zlib": return PackageDecompression.zlib(raw, limit: limit)
        case "application/x-bzip2": return PackageDecompression.bunzip2(raw, limit: limit)
        case "application/x-xz", "application/x-lzma": return PackageDecompression.unxz(raw, limit: limit)
        default: return PackageDecompression.Output(data: raw.prefix(limit), truncated: raw.count > limit)
        }
    }

    func contents(of path: String, limit: Int) -> PackageDecompression.Output? {
        entry(path).flatMap { contents(of: $0, limit: limit) }
    }

    /// Raw heap bytes, or nil when the range falls outside the file.
    func heap(offset: UInt64, length: UInt64) -> Data? {
        let (start, overflow) = UInt64(heapStart).addingReportingOverflow(offset)
        guard !overflow, let position = Int(exactly: start), let count = Int(exactly: length),
              BinaryReader(data).has(count, at: position) else { return nil }
        return data.subdata(in: position..<(position + count))
    }

    // MARK: Signatures

    enum Verdict: Equatable { case valid, invalid, unknown }

    /// Checks the classic RSA signature over the stored TOC checksum with the leaf certificate's key.
    func verifyRSASignature() -> Verdict {
        guard let signature, let leaf = signature.certificates.first, let checksum = storedChecksum,
              let blob = heap(offset: signature.offset, length: signature.size), !blob.isEmpty,
              let certificate = SecCertificateCreateWithData(nil, leaf as CFData),
              let key = SecCertificateCopyKey(certificate) else { return .unknown }
        let algorithm: SecKeyAlgorithm
        switch checksum.count {
        case 20: algorithm = .rsaSignatureDigestPKCS1v15SHA1
        case 32: algorithm = .rsaSignatureDigestPKCS1v15SHA256
        case 48: algorithm = .rsaSignatureDigestPKCS1v15SHA384
        case 64: algorithm = .rsaSignatureDigestPKCS1v15SHA512
        default: return .unknown
        }
        guard SecKeyIsAlgorithmSupported(key, .verify, algorithm) else { return .unknown }
        var error: Unmanaged<CFError>?
        let ok = SecKeyVerifySignature(key, algorithm, checksum as CFData, blob as CFData, &error)
        error?.release()
        return ok ? .valid : .invalid
    }

    /// The CMS signature's trusted timestamp (or signing time), when it has one.
    func cmsSigningDate() -> (date: Date, trusted: Bool)? {
        guard let cms = cmsSignature, let blob = heap(offset: cms.offset, length: cms.size), !blob.isEmpty, blob.count < 1 << 20,
              let checksum = storedChecksum else { return nil }
        var decoderRef: CMSDecoder?
        guard CMSDecoderCreate(&decoderRef) == errSecSuccess, let decoder = decoderRef else { return nil }
        let added = blob.withUnsafeBytes { buffer -> OSStatus in
            guard let base = buffer.baseAddress else { return errSecParam }
            return CMSDecoderUpdateMessage(decoder, base, buffer.count)
        }
        guard added == errSecSuccess else { return nil }
        CMSDecoderSetDetachedContent(decoder, checksum as CFData)
        guard CMSDecoderFinalizeMessage(decoder) == errSecSuccess else { return nil }
        var time: CFAbsoluteTime = 0
        if CMSDecoderCopySignerTimestamp(decoder, 0, &time) == errSecSuccess, time > 0 {
            return (Date(timeIntervalSinceReferenceDate: time), true)
        }
        if CMSDecoderCopySignerSigningTime(decoder, 0, &time) == errSecSuccess, time > 0 {
            return (Date(timeIntervalSinceReferenceDate: time), false)
        }
        return nil
    }

    // MARK: Helpers

    static func digest(_ data: Data, style: String) -> Data? {
        switch style {
        case "sha1": return Data(Insecure.SHA1.hash(data: data))
        case "md5": return Data(Insecure.MD5.hash(data: data))
        case "sha256": return Data(SHA256.hash(data: data))
        case "sha384": return Data(SHA384.hash(data: data))
        case "sha512": return Data(SHA512.hash(data: data))
        default: return nil
        }
    }

    static func date(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: trimmed) { return date }
        // TOC creation times often omit the zone ("2026-05-18T12:14:00"): they're UTC.
        return formatter.date(from: trimmed + "Z")
    }

    static func sniff(_ bytes: [UInt8]) -> Bool { bytes.starts(with: magic) }
}
