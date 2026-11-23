import Foundation
import Security

/// How an APK or App Bundle is signed: which schemes, and by whom.
struct AndroidSignature: Equatable {
    /// "v1 (JAR)", "v2", "v3", "v3.1", in order.
    var schemes: [String] = []
    /// The first signer's certificate chain, leaf first, as DER.
    var certificates: [Data] = []
    var signerCount = 0
    /// v3 proof-of-rotation: the app moved to a new signing key.
    var keyRotated = false
    /// A SourceStamp block names the store that built the APK.
    var hasSourceStamp = false
    /// Google Play adds a metadata block to the APKs it serves.
    var hasPlayMetadata = false

    var isSigned: Bool { !schemes.isEmpty }

    /// The well-known key Android Studio uses for debug builds.
    var isDebugCertificate: Bool {
        guard let leaf = certificates.first, let summary = CertificateSummary(der: leaf) else { return false }
        return summary.commonName == "Android Debug"
    }
}

enum AndroidSigning {
    static let v2ID: UInt32 = 0x7109_871a
    static let v3ID: UInt32 = 0xf053_68c0
    static let v31ID: UInt32 = 0x1b93_ad61
    static let sourceStampV2ID: UInt32 = 0x6dff_800d
    static let sourceStampV1ID: UInt32 = 0x2b09_189e
    static let playMetadataID: UInt32 = 0x2146_444e
    static let proofOfRotationID: UInt32 = 0x3ba0_6f8c

    static func signature(of zip: ZIPArchive) -> AndroidSignature {
        var result = AndroidSignature()
        // v1: META-INF/*.RSA|DSA|EC are detached PKCS#7 SignedData.
        let v1Files = zip.members.filter { member in
            let path = member.path.uppercased()
            guard path.hasPrefix("META-INF/"), !path.dropFirst(9).contains("/") else { return false }
            return path.hasSuffix(".RSA") || path.hasSuffix(".DSA") || path.hasSuffix(".EC")
        }
        var v1Chain: [Data] = []
        for file in v1Files.prefix(8) {
            guard let pkcs7 = try? zip.contents(of: file, limit: 1 << 20) else { continue }
            let chain = certificates(inPKCS7: pkcs7)
            if v1Chain.isEmpty { v1Chain = chain }
        }
        if !v1Files.isEmpty { result.schemes.append("v1 (JAR)") }

        let block = signingBlock(of: zip)
        var blockChain: [Data] = []
        for (id, value) in block {
            switch id {
            case v2ID, v3ID, v31ID:
                result.schemes.append(id == v2ID ? "v2" : id == v3ID ? "v3" : "v3.1")
                let signers = parseSigners(value, isV3: id != v2ID)
                result.signerCount = max(result.signerCount, signers.count)
                if signers.contains(where: \.rotated) { result.keyRotated = true }
                // The newest scheme's certificate wins: after rotation it's the current key.
                if let first = signers.first, !first.certificates.isEmpty { blockChain = first.certificates }
            case sourceStampV1ID, sourceStampV2ID:
                result.hasSourceStamp = true
            case playMetadataID:
                result.hasPlayMetadata = true
            default:
                break
            }
        }
        if result.signerCount == 0 && !v1Files.isEmpty { result.signerCount = v1Files.count }
        result.certificates = blockChain.isEmpty ? v1Chain : blockChain
        return result
    }

    /// The APK Signing Block's ID-value pairs, read straight from the archive: its footer (size
    /// and magic) ends where the shared ZIP reader found the central directory.
    static func signingBlock(of zip: ZIPArchive) -> [(UInt32, Data)] {
        let directory = zip.centralDirectoryOffset
        guard directory >= 32 else { return [] }
        let footer = BinaryReader(zip.bytes(at: directory - 24, count: 24))
        guard footer.bytes(at: 8, count: 16) == Data("APK Sig Block 42".utf8), let size = footer.u64(at: 0),
              size >= 24, size < directory, let length = Int(exactly: size + 8) else { return [] }
        let block = zip.bytes(at: directory - size - 8, count: length)
        return signingBlock(block, centralDirectory: block.count)
    }

    /// The ID-value pairs of the APK Signing Block that sits right before the central directory.
    static func signingBlock(_ input: Data, centralDirectory: Int) -> [(UInt32, Data)] {
        let reader = BinaryReader(input)
        guard centralDirectory >= 32, centralDirectory <= reader.count,
              reader.bytes(at: centralDirectory - 16, count: 16) == Data("APK Sig Block 42".utf8),
              let size = reader.u64(at: centralDirectory - 24), size >= 24, size < UInt64(centralDirectory),
              let start = Int(exactly: UInt64(centralDirectory) - size - 8), start >= 0,
              reader.u64(at: start) == size else { return [] }
        var pairs: [(UInt32, Data)] = []
        var offset = start + 8
        let end = centralDirectory - 24
        while offset + 12 <= end, pairs.count < 64 {
            guard let length = reader.u64(at: offset), length >= 4, length <= UInt64(end - offset - 8),
                  let id = reader.u32(at: offset + 8),
                  let value = reader.bytes(at: offset + 12, count: Int(length) - 4) else { break }
            pairs.append((id, value))
            offset += 8 + Int(length)
        }
        return pairs
    }

    struct Signer {
        var certificates: [Data]
        var rotated: Bool
    }

    /// v2/v3 signer blocks: length-prefixed sequences all the way down.
    static func parseSigners(_ value: Data, isV3: Bool) -> [Signer] {
        var signers: [Signer] = []
        guard let list = lengthPrefixed(value, at: 0) else { return [] }
        for signer in sequence(list).prefix(16) {
            guard let signedData = lengthPrefixed(signer, at: 0),
                  let digests = lengthPrefixed(signedData, at: 0) else { continue }
            let certificatesAt = 4 + digests.count
            guard let certificateList = lengthPrefixed(signedData, at: certificatesAt) else { continue }
            let certificates = sequence(certificateList).prefix(8).filter { $0.count < 64 * 1024 }
            var rotated = false
            if isV3 {
                // signed data: digests, certificates, minSDK, maxSDK, additional attributes.
                let attributesAt = certificatesAt + 4 + certificateList.count + 8
                if let attributes = lengthPrefixed(signedData, at: attributesAt) {
                    rotated = sequence(attributes).contains { BinaryReader($0).u32(at: 0) == proofOfRotationID }
                }
            }
            signers.append(Signer(certificates: Array(certificates), rotated: rotated))
        }
        return signers
    }

    /// The u32-length-prefixed field at `offset`.
    private static func lengthPrefixed(_ data: Data, at offset: Int) -> Data? {
        let reader = BinaryReader(data)
        guard let length = reader.u32(at: offset).map(Int.init) else { return nil }
        return reader.bytes(at: offset + 4, count: length)
    }

    /// Splits a run of u32-length-prefixed items.
    private static func sequence(_ data: Data) -> [Data] {
        var items: [Data] = []
        var offset = 0
        while offset + 4 <= data.count, items.count < 256, let item = lengthPrefixed(data, at: offset) {
            items.append(item)
            offset += 4 + item.count
        }
        return items
    }

    /// Certificates from a PKCS#7 / CMS SignedData blob (detached content is fine).
    static func certificates(inPKCS7 data: Data) -> [Data] {
        guard !data.isEmpty, data.count < 1 << 20 else { return [] }
        var decoder: CMSDecoder?
        guard CMSDecoderCreate(&decoder) == errSecSuccess, let decoder else { return [] }
        let status = data.withUnsafeBytes { buffer -> OSStatus in
            guard let base = buffer.baseAddress else { return errSecParam }
            return CMSDecoderUpdateMessage(decoder, base, buffer.count)
        }
        guard status == errSecSuccess, CMSDecoderFinalizeMessage(decoder) == errSecSuccess else { return [] }
        var certificates: CFArray?
        guard CMSDecoderCopyAllCerts(decoder, &certificates) == errSecSuccess,
              let list = certificates as? [SecCertificate] else { return [] }
        return list.prefix(8).map { SecCertificateCopyData($0) as Data }
    }
}
