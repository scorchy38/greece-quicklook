import Foundation
import Security

/// A CMS (PKCS #7) signed message: provisioning profiles, signed configuration profiles,
/// Authenticode and JAR signatures. Decoded in-process with CMSDecoder.
struct SignedContainer {
    var content: Data?
    var certificates: [SecCertificate] = []
    var signerCertificate: SecCertificate?
    var signingTime: Date?
    /// The signature checked out cryptographically against the signer certificate (trust is separate).
    var signatureIntact: Bool?

    /// Evaluates the chain against this Mac's trust settings, offline. False when it can't be evaluated.
    static func isTrusted(_ certificates: [SecCertificate]) -> Bool {
        guard !certificates.isEmpty else { return false }
        var trust: SecTrust?
        guard SecTrustCreateWithCertificates(certificates as CFArray, SecPolicyCreateBasicX509(), &trust) == errSecSuccess, let trust else { return false }
        SecTrustSetNetworkFetchAllowed(trust, false)
        return SecTrustEvaluateWithError(trust, nil)
    }

    /// True when the bytes look like DER (SEQUENCE with definite or indefinite length).
    static func looksSigned(_ bytes: [UInt8]) -> Bool {
        bytes.count >= 2 && bytes[0] == 0x30 && (bytes[1] == 0x80 || (0x81...0x84).contains(bytes[1]))
    }

    init?(der: Data, limit: Int = 16 << 20) {
        guard der.count > 16, der.count <= limit else { return nil }
        var decoder: CMSDecoder?
        guard CMSDecoderCreate(&decoder) == errSecSuccess, let decoder else { return nil }
        let status = der.withUnsafeBytes { buffer -> OSStatus in
            guard let base = buffer.baseAddress else { return errSecParam }
            return CMSDecoderUpdateMessage(decoder, base, der.count)
        }
        guard status == errSecSuccess, CMSDecoderFinalizeMessage(decoder) == errSecSuccess else { return nil }

        var content: CFData?
        if CMSDecoderCopyContent(decoder, &content) == errSecSuccess { self.content = content as Data? }
        var all: CFArray?
        if CMSDecoderCopyAllCerts(decoder, &all) == errSecSuccess, let list = all as? [SecCertificate] {
            certificates = CodeSignature.orderedChain(list)
        }
        var signers = 0
        CMSDecoderGetNumSigners(decoder, &signers)
        if signers > 0 {
            var certificate: SecCertificate?
            if CMSDecoderCopySignerCert(decoder, 0, &certificate) == errSecSuccess { signerCertificate = certificate }
            var time = CFAbsoluteTime()
            if CMSDecoderCopySignerSigningTime(decoder, 0, &time) == errSecSuccess { signingTime = Date(timeIntervalSinceReferenceDate: time) }
            // Verify the signature itself without evaluating trust (no network, no keychain prompts).
            let policy = SecPolicyCreateBasicX509()
            var signerStatus = CMSSignerStatus.unsigned
            var verify: OSStatus = 0
            if CMSDecoderCopySignerStatus(decoder, 0, policy, false, &signerStatus, nil, &verify) == errSecSuccess {
                signatureIntact = signerStatus == .valid || signerStatus == .needsDetachedContent ? true
                    : signerStatus == .invalidSignature || signerStatus == .invalidCert ? false : nil
                if signerStatus == .unsigned { signatureIntact = nil }
            }
        }
        if let signer = signerCertificate, !certificates.isEmpty, !(certificates.first.map { CFEqual($0, signer) } ?? false) {
            certificates = [signer] + certificates.filter { !CFEqual($0, signer) }
        }
    }
}

/// An Apple provisioning profile: which team, app and devices it covers, and until when.
struct ProvisioningProfile {
    enum Kind: String {
        case development = "Development"
        case adHoc = "Ad Hoc"
        case appStore = "App Store"
        case enterprise = "Enterprise"
        case developerID = "Developer ID"
        case macDevelopment = "Mac Development"
        case macAppStore = "Mac App Store"
    }

    var name: String
    var appIDName: String?
    var applicationIdentifier: String?
    var teamName: String?
    var teamIDs: [String]
    var uuid: String?
    var platforms: [String]
    var created: Date?
    var expires: Date?
    var devices: [String]
    var provisionsAllDevices: Bool
    var entitlements: [String: Any]
    var certificates: [CertificateSummary]
    var isXcodeManaged: Bool
    var kind: Kind
    var signer: [SecCertificate]
    var signatureIntact: Bool?
    var timeToLive: Int?

    static let maxSize = 2 << 20

    init?(data: Data) {
        guard data.count <= Self.maxSize, let container = SignedContainer(der: data), let content = container.content,
              let plist = try? PropertyListSerialization.propertyList(from: content, options: [], format: nil) as? [String: Any] else { return nil }
        self.init(plist: plist)
        signer = container.certificates
        signatureIntact = container.signatureIntact
    }

    init?(plist: [String: Any]) {
        guard plist["Name"] != nil || plist["UUID"] != nil || plist["Entitlements"] != nil else { return nil }
        name = Format.clean(plist["Name"] as? String ?? "Provisioning Profile", limit: 200)
        appIDName = plist["AppIDName"] as? String
        teamName = plist["TeamName"] as? String
        teamIDs = (plist["TeamIdentifier"] as? [String]) ?? []
        uuid = plist["UUID"] as? String
        platforms = (plist["Platform"] as? [String]) ?? []
        created = plist["CreationDate"] as? Date
        expires = plist["ExpirationDate"] as? Date
        devices = Array(((plist["ProvisionedDevices"] as? [String]) ?? []).prefix(10_000))
        provisionsAllDevices = plist["ProvisionsAllDevices"] as? Bool ?? false
        entitlements = plist["Entitlements"] as? [String: Any] ?? [:]
        applicationIdentifier = (entitlements["application-identifier"] ?? entitlements["com.apple.application-identifier"]) as? String
        isXcodeManaged = plist["IsXcodeManaged"] as? Bool ?? false
        timeToLive = plist["TimeToLive"] as? Int
        certificates = ((plist["DeveloperCertificates"] as? [Data]) ?? []).prefix(64).compactMap { CertificateSummary(der: $0) }
        signer = []
        let debuggable = (entitlements["get-task-allow"] as? Bool) ?? (entitlements["com.apple.security.get-task-allow"] as? Bool) ?? false
        let mac = platforms.contains("OSX") || entitlements["com.apple.application-identifier"] != nil
        if provisionsAllDevices {
            kind = mac ? .developerID : .enterprise
        } else if debuggable {
            kind = mac ? .macDevelopment : .development
        } else if !devices.isEmpty {
            kind = .adHoc
        } else {
            kind = mac ? .macAppStore : .appStore
        }
    }

    var platformNames: String {
        let names = platforms.map { $0 == "OSX" ? "macOS" : $0 == "xrOS" ? "visionOS" : $0 }
        return names.isEmpty ? "" : ListFormatter.localizedString(byJoining: names)
    }
}
