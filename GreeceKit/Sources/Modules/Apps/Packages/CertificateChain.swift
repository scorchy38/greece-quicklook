import Foundation
import Security
import CryptoKit

/// Offline checks that a package's certificates really chain to Apple, without trustd or the network.
enum CertificateChain {
    /// SHA-256 of Apple Root CA, the anchor of Developer ID, Mac App Store and Apple software chains.
    static let appleRootFingerprints: Set<String> = [
        "b0b1730ecbc7ff4505142c49f1295e6eda6bcaed7e2c68c5be91b5a11001f024",
    ]

    /// True when the system trusts the chain (at `date`, offline) and its anchor is one of Apple's roots.
    /// If trust evaluation isn't available (a sandbox without trustd), falls back to checking each
    /// signature in the chain cryptographically up to Apple Root CA.
    static func chainsToApple(_ ders: [Data], at date: Date?) -> Bool {
        let certificates = ders.prefix(8).compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }
        guard !certificates.isEmpty else { return false }
        var trustRef: SecTrust?
        if SecTrustCreateWithCertificates(certificates as CFArray, SecPolicyCreateBasicX509(), &trustRef) == errSecSuccess,
           let trust = trustRef {
            SecTrustSetNetworkFetchAllowed(trust, false)
            if let date { SecTrustSetVerifyDate(trust, date as CFDate) }
            if SecTrustEvaluateWithError(trust, nil) {
                let chain = (SecTrustCopyCertificateChain(trust) as? [SecCertificate]) ?? []
                if let anchor = chain.last {
                    var name: CFString?
                    SecCertificateCopyCommonName(anchor, &name)
                    if (name as String?)?.hasPrefix("Apple Root CA") == true { return true }
                }
            }
        }
        return signaturesChainToAppleRoot(Array(ders.prefix(8)))
    }

    /// Each certificate is signed by the next one's key, and the last is Apple Root CA (self-signed).
    static func signaturesChainToAppleRoot(_ ders: [Data]) -> Bool {
        guard let root = ders.last, appleRootFingerprints.contains(SHA256.hash(data: root).map { String(format: "%02x", $0) }.joined()) else {
            return false
        }
        for index in ders.indices {
            let issuer = index + 1 < ders.count ? ders[index + 1] : ders[index]
            guard verify(ders[index], signedBy: issuer) else { return false }
        }
        return true
    }

    /// Verifies a certificate's signature with the issuer certificate's public key.
    static func verify(_ der: Data, signedBy issuerDER: Data) -> Bool {
        guard let parts = split(der), let algorithm = algorithm(forOID: parts.algorithm),
              let issuer = SecCertificateCreateWithData(nil, issuerDER as CFData), let key = SecCertificateCopyKey(issuer),
              SecKeyIsAlgorithmSupported(key, .verify, algorithm) else { return false }
        var error: Unmanaged<CFError>?
        let ok = SecKeyVerifySignature(key, algorithm, parts.tbs as CFData, parts.signature as CFData, &error)
        error?.release()
        return ok
    }

    /// Certificate ::= SEQUENCE { tbsCertificate, signatureAlgorithm, signatureValue BIT STRING }
    static func split(_ der: Data) -> (tbs: Data, algorithm: [UInt8], signature: Data)? {
        let bytes = [UInt8](der)
        guard let outer = element(bytes, at: 0), outer.tag == 0x30 else { return nil }
        guard let tbs = element(bytes, at: outer.contentStart), tbs.tag == 0x30,
              let algorithm = element(bytes, at: tbs.end), algorithm.tag == 0x30,
              let oid = element(bytes, at: algorithm.contentStart), oid.tag == 0x06,
              let signature = element(bytes, at: algorithm.end), signature.tag == 0x03,
              signature.end <= outer.end, signature.contentStart < signature.end else { return nil }
        return (Data(bytes[tbs.start..<tbs.end]), Array(bytes[oid.contentStart..<oid.end]),
                Data(bytes[(signature.contentStart + 1)..<signature.end]))   // skip the unused-bits byte
    }

    private struct Element { let tag: UInt8; let start: Int; let contentStart: Int; let end: Int }

    /// One DER TLV with a definite length, bounds-checked.
    private static func element(_ bytes: [UInt8], at position: Int) -> Element? {
        guard position >= 0, position + 2 <= bytes.count else { return nil }
        let tag = bytes[position]
        var length = Int(bytes[position + 1])
        var header = 2
        if length & 0x80 != 0 {
            let count = length & 0x7F
            guard count >= 1, count <= 4, position + 2 + count <= bytes.count else { return nil }
            length = 0
            for byte in bytes[(position + 2)..<(position + 2 + count)] { length = length << 8 | Int(byte) }
            header += count
        }
        let contentStart = position + header
        guard length >= 0, contentStart + length <= bytes.count else { return nil }
        return Element(tag: tag, start: position, contentStart: contentStart, end: contentStart + length)
    }

    private static func algorithm(forOID oid: [UInt8]) -> SecKeyAlgorithm? {
        let rsa: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01]      // 1.2.840.113549.1.1
        let ecdsa: [UInt8] = [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04]                // 1.2.840.10045.4
        if oid.count == rsa.count + 1, oid.starts(with: rsa) {
            switch oid.last {
            case 5: return .rsaSignatureMessagePKCS1v15SHA1
            case 11: return .rsaSignatureMessagePKCS1v15SHA256
            case 12: return .rsaSignatureMessagePKCS1v15SHA384
            case 13: return .rsaSignatureMessagePKCS1v15SHA512
            default: return nil
            }
        }
        if oid == ecdsa + [0x01] { return .ecdsaSignatureMessageX962SHA1 }
        if oid.count == ecdsa.count + 2, oid.starts(with: ecdsa + [0x03]) {
            switch oid.last {
            case 2: return .ecdsaSignatureMessageX962SHA256
            case 3: return .ecdsaSignatureMessageX962SHA384
            case 4: return .ecdsaSignatureMessageX962SHA512
            default: return nil
            }
        }
        return nil
    }
}
