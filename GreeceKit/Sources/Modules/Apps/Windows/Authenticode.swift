import Foundation
import Security
import CryptoKit

/// A Windows Authenticode signature: the PKCS #7 SignedData in the PE certificate table.
/// Greece reads who signed, when, with which digest, and whether the file still matches that
/// digest. It can't check the certificates against Windows' trust store.
struct AuthenticodeSignature {
    enum DigestAlgorithm: String {
        case md5 = "MD5", sha1 = "SHA-1", sha256 = "SHA-256", sha384 = "SHA-384", sha512 = "SHA-512"
    }

    enum Integrity: Equatable {
        case matches
        case modified
        case notChecked(String)
    }

    /// The signer's chain, leaf first.
    var chain: [CertificateSummary] = []
    /// Everything else in the signature (timestamping authorities, cross-certificates).
    var otherCertificates: [CertificateSummary] = []
    var signingTime: Date?
    var digestAlgorithm: DigestAlgorithm?
    var digest: Data?
    /// Dual-signed files (SHA-1 plus SHA-256) nest a second signature.
    var nestedSignatures = 0
    var signatureCount = 0

    var signer: CertificateSummary? { chain.first }

    static let maxTableSize = 4 << 20

    // MARK: - Reading

    init?(file: PEFile) {
        guard let table = file.certificateTable, table.count <= Self.maxTableSize else { return nil }
        let reader = BinaryReader(file.data)
        var position = table.lowerBound
        var blobs: [Data] = []
        // WIN_CERTIFICATE entries: length, revision, type (2 = PKCS #7), then the blob, 8-byte aligned.
        while position + 8 <= table.upperBound, blobs.count < 8 {
            guard let length = reader.u32(at: position).map(Int.init), length >= 8, position + length <= table.upperBound,
                  let type = reader.u16(at: position + 6) else { break }
            if type == 2, let blob = reader.bytes(at: position + 8, count: length - 8) { blobs.append(blob) }
            position += (length + 7) & ~7
        }
        guard let blob = blobs.first else { return nil }
        self.init(pkcs7: blob)
        signatureCount = blobs.count
    }

    init?(pkcs7 blob: Data) {
        var decoderRef: CMSDecoder?
        var certificates: [SecCertificate] = []
        var signerCertificate: SecCertificate?
        if CMSDecoderCreate(&decoderRef) == errSecSuccess, let decoder = decoderRef {
            let status = blob.withUnsafeBytes { buffer -> OSStatus in
                guard let base = buffer.baseAddress else { return errSecParam }
                return CMSDecoderUpdateMessage(decoder, base, buffer.count)
            }
            if status == errSecSuccess, CMSDecoderFinalizeMessage(decoder) == errSecSuccess {
                var all: CFArray?
                if CMSDecoderCopyAllCerts(decoder, &all) == errSecSuccess, let list = all as? [SecCertificate] {
                    certificates = Array(list.prefix(32))
                }
                var signers = 0
                if CMSDecoderGetNumSigners(decoder, &signers) == errSecSuccess, signers > 0 {
                    var leaf: SecCertificate?
                    if CMSDecoderCopySignerCert(decoder, 0, &leaf) == errSecSuccess { signerCertificate = leaf }
                    var time: CFAbsoluteTime = 0
                    if CMSDecoderCopySignerSigningTime(decoder, 0, &time) == errSecSuccess, time > 0 {
                        signingTime = Date(timeIntervalSinceReferenceDate: time)
                    }
                }
            }
        }
        // CMS can refuse unusual encodings: read the certificates straight from the DER.
        if certificates.isEmpty {
            certificates = DER.certificates(inSignedData: blob).prefix(32).compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }
        }
        guard !certificates.isEmpty || signerCertificate != nil else { return nil }

        let summaries = certificates.map(CertificateSummary.init(certificate:))
        var remaining = summaries
        var chain: [CertificateSummary] = []
        // The SignerInfo names its certificate by issuer and serial number. CMS sometimes reports the
        // timestamp's signer instead, so the DER decides when it can.
        let leaf = DER.signerCertificate(inSignedData: blob).flatMap(CertificateSummary.init(der:))
            ?? signerCertificate.map(CertificateSummary.init(certificate:)) ?? Self.guessLeaf(summaries)
        if let leaf {
            chain.append(leaf)
            remaining.removeAll { $0.sha256 == leaf.sha256 }
            while chain.count < 8, let current = chain.last, !current.isSelfSigned {
                // Prefer a self-signed root over a cross-signed copy with the same name.
                let candidates = remaining.indices.filter { remaining[$0].commonName == current.issuer }
                guard let index = candidates.first(where: { remaining[$0].isSelfSigned }) ?? candidates.first else { break }
                chain.append(remaining.remove(at: index))
            }
        }
        self.chain = chain
        otherCertificates = remaining

        if let (algorithm, digest) = DER.indirectDataDigest(inSignedData: blob) {
            digestAlgorithm = algorithm
            self.digest = digest
        }
        // The countersignature or timestamp token is when it was signed; CMS's own answer comes last.
        signingTime = DER.counterSignatureTime(in: blob) ?? signingTime
        nestedSignatures = DER.count(of: DER.nestedSignatureOID, in: blob)
    }

    /// The certificate of the timestamping authority that countersigned, if any.
    var timestampAuthority: CertificateSummary? {
        let candidates = otherCertificates.filter { certificate in
            let name = certificate.commonName.lowercased()
            return name.contains("timestamp") || name.contains("time stamp") || name.contains("tsa") || name.contains("time-stamp")
        }
        // The authority's own certificate, not the CA that issued it.
        let issuers = Set(otherCertificates.compactMap(\.issuer))
        return candidates.first { !issuers.contains($0.commonName) } ?? candidates.first
    }

    /// Without a signer record, the leaf is the certificate nobody else names as issuer.
    private static func guessLeaf(_ certificates: [CertificateSummary]) -> CertificateSummary? {
        let issuers = Set(certificates.compactMap(\.issuer))
        return certificates.first { !issuers.contains($0.commonName) && !$0.isSelfSigned } ?? certificates.first
    }

    // MARK: - Integrity

    static let maxHashedSize = 1 << 30

    /// Recomputes the Authenticode digest: the whole file except the checksum, the certificate
    /// table's directory entry and the table itself.
    func integrity(of file: PEFile) -> Integrity {
        guard let algorithm = digestAlgorithm, let expected = digest else { return .notChecked("The signature has no file digest.") }
        guard file.fileSize <= Self.maxHashedSize else { return .notChecked("Files over \(Format.bytes(Self.maxHashedSize)) aren’t checked.") }
        guard let computed = Self.digest(of: file, algorithm: algorithm) else { return .notChecked("The file’s layout couldn’t be hashed.") }
        return computed == expected ? .matches : .modified
    }

    static func digest(of file: PEFile, algorithm: DigestAlgorithm) -> Data? {
        let checksum = file.checksumOffset
        let entry = file.directoriesOffset + 4 * 8
        let end = file.certificateTable?.lowerBound ?? file.fileSize
        guard checksum + 4 <= entry, entry + 8 <= end, end <= file.fileSize else { return nil }
        let ranges = [0..<checksum, (checksum + 4)..<entry, (entry + 8)..<end]
        func run<H: HashFunction>(_ hasher: inout H) {
            file.data.withUnsafeBytes { buffer in
                for range in ranges where !range.isEmpty {
                    var start = range.lowerBound
                    while start < range.upperBound {
                        let next = min(range.upperBound, start + (4 << 20))
                        hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: buffer[start..<next]))
                        start = next
                    }
                }
            }
        }
        switch algorithm {
        case .md5: var h = Insecure.MD5(); run(&h); return Data(h.finalize())
        case .sha1: var h = Insecure.SHA1(); run(&h); return Data(h.finalize())
        case .sha256: var h = SHA256(); run(&h); return Data(h.finalize())
        case .sha384: var h = SHA384(); run(&h); return Data(h.finalize())
        case .sha512: var h = SHA512(); run(&h); return Data(h.finalize())
        }
    }

    // MARK: - DER

    /// Just enough DER to walk PKCS #7: definite lengths, bounded depth, never past the end.
    enum DER {
        struct Node {
            let tag: UInt8
            let start: Int
            let contentStart: Int
            let end: Int
        }

        static let nestedSignatureOID: [UInt8] = [0x06, 0x0A, 0x2B, 0x06, 0x01, 0x04, 0x01, 0x82, 0x37, 0x02, 0x04, 0x01]
        static let signingTimeOID: [UInt8] = [0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x09, 0x05]
        static let tstInfoOID: [UInt8] = [0x06, 0x0B, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x09, 0x10, 0x01, 0x04]

        static func node(_ bytes: [UInt8], at position: Int, limit: Int) -> Node? {
            guard position >= 0, position + 2 <= limit, limit <= bytes.count else { return nil }
            let tag = bytes[position]
            var cursor = position + 1
            let first = bytes[cursor]
            cursor += 1
            var length = 0
            if first < 0x80 {
                length = Int(first)
            } else {
                let count = Int(first & 0x7F)
                guard count >= 1, count <= 4, cursor + count <= limit else { return nil }
                for _ in 0..<count { length = length << 8 | Int(bytes[cursor]); cursor += 1 }
            }
            guard length >= 0, cursor + length <= limit else { return nil }
            return Node(tag: tag, start: position, contentStart: cursor, end: cursor + length)
        }

        static func children(_ bytes: [UInt8], of parent: Node) -> [Node] {
            var result: [Node] = []
            var cursor = parent.contentStart
            while cursor < parent.end, result.count < 64, let child = node(bytes, at: cursor, limit: parent.end) {
                result.append(child)
                cursor = child.end
            }
            return result
        }

        /// ContentInfo → [0] → SignedData's children.
        static func signedData(_ bytes: [UInt8]) -> [Node]? {
            guard let info = node(bytes, at: 0, limit: bytes.count), info.tag == 0x30 else { return nil }
            let parts = children(bytes, of: info)
            guard parts.count >= 2, parts[1].tag == 0xA0, let signed = children(bytes, of: parts[1]).first, signed.tag == 0x30 else { return nil }
            return children(bytes, of: signed)
        }

        /// The certificate the first SignerInfo identifies by issuer and serial number.
        static func signerCertificate(inSignedData data: Data) -> Data? {
            let bytes = [UInt8](data.prefix(maxTableSize))
            guard let parts = signedData(bytes), let signerInfos = parts.last(where: { $0.tag == 0x31 }),
                  let signerInfo = children(bytes, of: signerInfos).first, signerInfo.tag == 0x30 else { return nil }
            let fields = children(bytes, of: signerInfo)
            guard fields.count >= 2, fields[1].tag == 0x30 else { return nil }
            let identifier = children(bytes, of: fields[1])
            guard identifier.count >= 2, identifier[0].tag == 0x30, identifier[1].tag == 0x02 else { return nil }
            let issuer = bytes[identifier[0].start..<identifier[0].end]
            let serial = bytes[identifier[1].start..<identifier[1].end]
            for certificate in certificates(inSignedData: data) {
                let der = [UInt8](certificate)
                guard let root = node(der, at: 0, limit: der.count), let tbs = children(der, of: root).first else { continue }
                var tbsFields = children(der, of: tbs)
                if tbsFields.first?.tag == 0xA0 { tbsFields.removeFirst() }   // explicit version
                guard tbsFields.count >= 3 else { continue }
                if der[tbsFields[0].start..<tbsFields[0].end].elementsEqual(serial),
                   der[tbsFields[2].start..<tbsFields[2].end].elementsEqual(issuer) {
                    return certificate
                }
            }
            return nil
        }

        static func certificates(inSignedData data: Data) -> [Data] {
            let bytes = [UInt8](data.prefix(maxTableSize))
            guard let parts = signedData(bytes), let set = parts.first(where: { $0.tag == 0xA0 }) else { return [] }
            return children(bytes, of: set).filter { $0.tag == 0x30 }.prefix(32).map { Data(bytes[$0.start..<$0.end]) }
        }

        /// SpcIndirectDataContent's DigestInfo: the algorithm and the file digest it signs.
        static func indirectDataDigest(inSignedData data: Data) -> (DigestAlgorithm, Data)? {
            let bytes = [UInt8](data.prefix(maxTableSize))
            guard let parts = signedData(bytes), parts.count >= 3 else { return nil }
            // version, digestAlgorithms, contentInfo { type, [0] { SpcIndirectDataContent } }
            let contentInfo = children(bytes, of: parts[2])
            guard contentInfo.count >= 2, contentInfo[1].tag == 0xA0,
                  let indirect = children(bytes, of: contentInfo[1]).first, indirect.tag == 0x30 else { return nil }
            let fields = children(bytes, of: indirect)
            guard fields.count >= 2, fields[1].tag == 0x30 else { return nil }
            let digestInfo = children(bytes, of: fields[1])
            guard digestInfo.count >= 2, digestInfo[0].tag == 0x30, digestInfo[1].tag == 0x04,
                  let oid = children(bytes, of: digestInfo[0]).first, oid.tag == 0x06 else { return nil }
            let algorithm: DigestAlgorithm
            switch Array(bytes[oid.contentStart..<oid.end]) {
            case [0x2B, 0x0E, 0x03, 0x02, 0x1A]: algorithm = .sha1
            case [0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01]: algorithm = .sha256
            case [0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x02]: algorithm = .sha384
            case [0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x03]: algorithm = .sha512
            case [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x02, 0x05]: algorithm = .md5
            default: return nil
            }
            return (algorithm, Data(bytes[digestInfo[1].contentStart..<digestInfo[1].end]))
        }

        /// The legacy countersignature's signingTime, or an RFC 3161 token's genTime.
        static func counterSignatureTime(in data: Data) -> Date? {
            let bytes = [UInt8](data.prefix(maxTableSize))
            if let found = data.firstRange(of: signingTimeOID) {
                // SET { UTCTime | GeneralizedTime }
                let set = found + signingTimeOID.count
                if let wrapper = node(bytes, at: set, limit: bytes.count), wrapper.tag == 0x31,
                   let time = node(bytes, at: wrapper.contentStart, limit: wrapper.end), let date = parseTime(bytes, time) {
                    return date
                }
            }
            if let found = data.firstRange(of: tstInfoOID) {
                // The token's TSTInfo holds genTime, the first GeneralizedTime after its type.
                var cursor = found + tstInfoOID.count
                let stop = min(bytes.count - 2, cursor + 512)
                while cursor < stop {
                    if bytes[cursor] == 0x18, let time = node(bytes, at: cursor, limit: bytes.count), let date = parseTime(bytes, time) { return date }
                    cursor += 1
                }
            }
            return nil
        }

        static func parseTime(_ bytes: [UInt8], _ node: Node) -> Date? {
            guard node.end - node.contentStart <= 32 else { return nil }
            let text = String(decoding: bytes[node.contentStart..<node.end], as: UTF8.self)
            let digits = text.prefix { $0.isNumber }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")
            switch (node.tag, digits.count) {
            case (0x17, 12...): formatter.dateFormat = "yyMMddHHmmss"; return formatter.date(from: String(digits.prefix(12)))
            case (0x18, 14...): formatter.dateFormat = "yyyyMMddHHmmss"; return formatter.date(from: String(digits.prefix(14)))
            default: return nil
            }
        }

        static func count(of pattern: [UInt8], in data: Data) -> Int {
            var count = 0
            var offset = 0
            while count < 16, let found = data.firstRange(of: pattern, from: offset) {
                count += 1
                offset = found + pattern.count
            }
            return count
        }
    }
}
