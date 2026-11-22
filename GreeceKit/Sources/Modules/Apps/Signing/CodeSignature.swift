import Foundation
import Security
import CryptoKit

/// An embedded code signature (the superblob at LC_CODE_SIGNATURE, or a disk image's), parsed
/// in-process: identity, flags, entitlements, certificates and the code directory hash.
struct CodeSignature {
    struct Flags: OptionSet {
        let rawValue: UInt32
        static let adhoc = Flags(rawValue: 0x2)
        static let hard = Flags(rawValue: 0x100)
        static let kill = Flags(rawValue: 0x200)
        static let restrict = Flags(rawValue: 0x800)
        static let enforcement = Flags(rawValue: 0x1000)
        static let libraryValidation = Flags(rawValue: 0x2000)
        static let runtime = Flags(rawValue: 0x10000)
        static let linkerSigned = Flags(rawValue: 0x20000)
    }

    var identifier: String?
    var teamID: String?
    var flags: Flags = []
    var hashType: UInt8 = 0
    var platform: UInt8 = 0
    var pageSize: Int = 0
    var codeLimit: UInt64 = 0
    var version: UInt32 = 0
    /// The hardened runtime version (the SDK it was built against).
    var runtimeVersion: String?
    /// The code directory hash, truncated to 20 bytes like `codesign` prints it.
    var cdhash: Data?
    /// Every code directory's hash, full length (tickets may list either).
    var cdhashes: [Data] = []
    var entitlements: [String: Any] = [:]
    var hasEntitlements = false
    var certificates: [SecCertificate] = []
    var signingTime: Date?
    var timestamp: Date?
    var requirementsText: String?
    var ticket: NotarizationTicket?

    var isAdHoc: Bool { flags.contains(.adhoc) || certificates.isEmpty }
    var hasHardenedRuntime: Bool { flags.contains(.runtime) }
    var isPlatformBinary: Bool { platform != 0 }

    var leafName: String? {
        guard let leaf = certificates.first else { return nil }
        var name: CFString?
        SecCertificateCopyCommonName(leaf, &name)
        return name as String?
    }

    var signer: SignerKind {
        if isAdHoc { return .adHoc }
        return SignerKind(leafCommonName: leafName)
    }

    var hashName: String {
        switch hashType {
        case 1: return "SHA-1"
        case 2: return "SHA-256"
        case 3: return String(localized: "SHA-256 (truncated)", bundle: .greeceKit, comment: "A hash algorithm, in a tooltip")
        case 4: return "SHA-384"
        default: return String(localized: "Unknown", bundle: .greeceKit, comment: "An unknown hash algorithm, in a tooltip")
        }
    }

    static let superBlobMagic: UInt32 = 0xFADE_0CC0
    static let maxBlobs = 64

    init?(data: Data) {
        let blob = data.startIndex == 0 ? data : Data(data)
        guard blob.count >= 12, blob.be32(0) == Self.superBlobMagic else { return nil }
        let length = min(Int(blob.be32(4)), blob.count)
        let count = min(Int(blob.be32(8)), Self.maxBlobs)
        var best: (type: UInt8, hash: Data)?
        for index in 0..<count {
            let entry = 12 + index * 8
            guard entry + 8 <= length else { break }
            let type = blob.be32(entry)
            let offset = Int(blob.be32(entry + 4))
            guard offset + 8 <= length else { continue }
            let magic = blob.be32(offset)
            let size = Int(blob.be32(offset + 4))
            guard size >= 8, offset + size <= length else { continue }
            let body = blob.subdata(in: offset..<(offset + size))
            switch magic {
            case 0xFADE_0C02: // code directory (primary at slot 0, alternates at 0x1000+)
                let hashType = body.count > 37 ? body[37] : 0
                let digest = Self.digest(body, type: hashType)
                if let digest { cdhashes.append(digest) }
                // Prefer the strongest directory for identity and the reported cdhash.
                if type == 0 || best == nil || hashType > (best?.type ?? 0) {
                    parseCodeDirectory(body)
                    if let digest { best = (hashType, digest) }
                }
            case 0xFADE_7171: // XML entitlements
                hasEntitlements = true
                if size > 8, size < 1 << 20,
                   let plist = try? PropertyListSerialization.propertyList(from: body.subdata(in: 8..<size), options: [], format: nil) as? [String: Any] {
                    entitlements = plist
                }
            case 0xFADE_7172: // DER entitlements, only if there's no XML copy
                hasEntitlements = true
            case 0xFADE_0B01: // CMS signature wrapper
                if size > 8 { parseCMS(body.subdata(in: 8..<size)) }
            case 0xFADE_0C01: // requirements
                if type == 2 { requirementsText = nil }
            default:
                break
            }
            _ = type
        }
        cdhash = best.map { Data($0.hash.prefix(20)) }
        ticket = NotarizationTicket(searching: blob)
    }

    private mutating func parseCodeDirectory(_ body: Data) {
        let reader = BinaryReader(body, bigEndian: true)
        version = reader.u32(at: 8) ?? 0
        flags = Flags(rawValue: reader.u32(at: 12) ?? 0)
        if let identOffset = reader.u32(at: 20).map(Int.init) { identifier = reader.cString(at: identOffset, maxLength: 1024) }
        codeLimit = UInt64(reader.u32(at: 32) ?? 0)
        hashType = reader.u8(at: 37) ?? 0
        platform = reader.u8(at: 38) ?? 0
        pageSize = (reader.u8(at: 39)).map { $0 == 0 ? 0 : 1 << Int(min($0, 30)) } ?? 0
        if version >= 0x20200, let teamOffset = reader.u32(at: 48).map(Int.init), teamOffset > 0 {
            teamID = reader.cString(at: teamOffset, maxLength: 64)
        }
        if version >= 0x20300, let limit64 = reader.u64(at: 56), limit64 > 0 { codeLimit = limit64 }
        if version >= 0x20500, let runtime = reader.u32(at: 88), runtime > 0 {
            runtimeVersion = MachOFile.osVersion(runtime)
        }
    }

    private mutating func parseCMS(_ der: Data) {
        guard der.count > 16, der.count < 1 << 20 else { return }
        var decoder: CMSDecoder?
        guard CMSDecoderCreate(&decoder) == errSecSuccess, let decoder else { return }
        let status = der.withUnsafeBytes { buffer -> OSStatus in
            guard let base = buffer.baseAddress else { return errSecParam }
            return CMSDecoderUpdateMessage(decoder, base, der.count)
        }
        guard status == errSecSuccess, CMSDecoderFinalizeMessage(decoder) == errSecSuccess else { return }
        var certificates: CFArray?
        if CMSDecoderCopyAllCerts(decoder, &certificates) == errSecSuccess, let list = certificates as? [SecCertificate] {
            self.certificates = Self.orderedChain(list)
        }
        var time = CFAbsoluteTime()
        if CMSDecoderCopySignerSigningTime(decoder, 0, &time) == errSecSuccess { signingTime = Date(timeIntervalSinceReferenceDate: time) }
        var stamp = CFAbsoluteTime()
        if CMSDecoderCopySignerTimestamp(decoder, 0, &stamp) == errSecSuccess { timestamp = Date(timeIntervalSinceReferenceDate: stamp) }
    }

    /// Leaf first, then each issuer, then the root (CMS bags are unordered).
    static func orderedChain(_ certificates: [SecCertificate]) -> [SecCertificate] {
        guard certificates.count > 1 else { return certificates }
        func subject(_ certificate: SecCertificate) -> Data? { SecCertificateCopyNormalizedSubjectSequence(certificate) as Data? }
        func issuer(_ certificate: SecCertificate) -> Data? { SecCertificateCopyNormalizedIssuerSequence(certificate) as Data? }
        let issuers = Set(certificates.compactMap { certificate -> Data? in
            let own = subject(certificate)
            return issuer(certificate) == own ? nil : issuer(certificate)
        })
        // The leaf is the certificate that issued nothing else in the bag.
        guard var current = certificates.first(where: { subject($0).map { !issuers.contains($0) } ?? false }) ?? certificates.first else { return certificates }
        var ordered = [current]
        while ordered.count < certificates.count,
              let next = certificates.first(where: { candidate in
                  !ordered.contains { $0 === candidate } && subject(candidate) == issuer(current)
              }) {
            ordered.append(next)
            current = next
        }
        for certificate in certificates where !ordered.contains(where: { $0 === certificate }) { ordered.append(certificate) }
        return ordered
    }

    private static func digest(_ body: Data, type: UInt8) -> Data? {
        switch type {
        case 1: return Data(Insecure.SHA1.hash(data: body))
        case 2, 3: return Data(SHA256.hash(data: body))
        case 4: return Data(SHA384.hash(data: body))
        default: return nil
        }
    }

    /// The team ID from the start of a superblob ("" when ad hoc), without hashing or decoding CMS.
    /// Works on a truncated signature as long as the primary code directory's header is inside it.
    static func teamIdentity(in data: Data) -> String? {
        let blob = data.startIndex == 0 ? data : Data(data)
        let reader = BinaryReader(blob, bigEndian: true)
        guard reader.u32(at: 0) == superBlobMagic, let count = reader.u32(at: 8).map(Int.init) else { return nil }
        for index in 0..<min(count, maxBlobs) {
            guard let type = reader.u32(at: 12 + index * 8), let offset = reader.u32(at: 16 + index * 8).map(Int.init) else { break }
            guard type == 0, reader.u32(at: offset) == 0xFADE_0C02 else { continue }
            let version = reader.u32(at: offset + 8) ?? 0
            let flags = Flags(rawValue: reader.u32(at: offset + 12) ?? 0)
            if version >= 0x20200, let teamOffset = reader.u32(at: offset + 48).map(Int.init), teamOffset > 0,
               let team = reader.cString(at: offset + teamOffset, maxLength: 64), !team.isEmpty {
                return team
            }
            return flags.contains(.adhoc) ? "" : nil
        }
        return nil
    }

    /// Reads the signature of the preferred slice of a Mach-O file.
    static func read(from source: RandomAccessBytes, macho: MachOFile, limit: Int = 8 << 20) -> CodeSignature? {
        guard let slice = macho.preferredSlice, let range = slice.codeSignature else { return nil }
        let length = Int(min(UInt64(limit), UInt64(range.count)))
        guard let data = source.read(range.lowerBound, length) else { return nil }
        return CodeSignature(data: data)
    }
}
