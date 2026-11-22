import Foundation
import Security
import CryptoKit

/// What a person needs to know about one certificate: who, issued by whom, valid until when.
struct CertificateSummary: Equatable {
    var commonName: String
    var organization: String?
    var organizationalUnit: String?
    var issuer: String?
    var notBefore: Date?
    var notAfter: Date?
    var sha256: String
    var sha1: String

    init(certificate: SecCertificate) {
        let der = SecCertificateCopyData(certificate) as Data
        sha256 = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
        sha1 = Insecure.SHA1.hash(data: der).map { String(format: "%02x", $0) }.joined()
        var name: CFString?
        SecCertificateCopyCommonName(certificate, &name)
        commonName = (name as String?) ?? (SecCertificateCopySubjectSummary(certificate) as String?) ?? "Unnamed certificate"

        let keys = [kSecOIDX509V1SubjectName, kSecOIDX509V1IssuerName, kSecOIDX509V1ValidityNotBefore, kSecOIDX509V1ValidityNotAfter] as CFArray
        guard let values = SecCertificateCopyValues(certificate, keys, nil) as? [String: Any] else { return }
        func value(_ key: CFString) -> Any? { (values[key as String] as? [String: Any])?[kSecPropertyKeyValue as String] }
        func component(_ list: Any?, _ oid: CFString) -> String? {
            guard let entries = list as? [[String: Any]] else { return nil }
            for entry in entries where (entry[kSecPropertyKeyLabel as String] as? String) == (oid as String) {
                if let text = entry[kSecPropertyKeyValue as String] as? String { return text }
            }
            return nil
        }
        let subject = value(kSecOIDX509V1SubjectName)
        organization = component(subject, kSecOIDOrganizationName)
        organizationalUnit = component(subject, kSecOIDOrganizationalUnitName)
        issuer = component(value(kSecOIDX509V1IssuerName), kSecOIDCommonName)
        func date(_ key: CFString) -> Date? {
            if let number = value(key) as? NSNumber { return Date(timeIntervalSinceReferenceDate: number.doubleValue) }
            if let text = value(key) as? String, let seconds = Double(text) { return Date(timeIntervalSinceReferenceDate: seconds) }
            return nil
        }
        notBefore = date(kSecOIDX509V1ValidityNotBefore)
        notAfter = date(kSecOIDX509V1ValidityNotAfter)
    }

    init?(der: Data) {
        guard der.count < 64 * 1024, let certificate = SecCertificateCreateWithData(nil, der as CFData) else { return nil }
        self.init(certificate: certificate)
    }

    var isSelfSigned: Bool { issuer != nil && issuer == commonName }
}

/// How code or an installer was signed, judged from its leaf certificate.
enum SignerKind: Equatable {
    case apple                 // Apple's own software
    case appStore              // re-signed by the Mac App Store or the iOS App Store
    case testFlight
    case developerID
    case development
    case distribution          // Ad hoc, enterprise, or awaiting App Store review
    case adHoc                 // no certificate at all
    case other(String)

    init(leafCommonName name: String?) {
        guard let name else { self = .adHoc; return }
        switch true {
        case name.hasPrefix("Developer ID"): self = .developerID
        case name == "Apple Mac OS Application Signing", name == "Apple iPhone OS Application Signing",
             name.hasPrefix("Apple Mac OS Installer Signing"): self = .appStore
        case name.hasPrefix("TestFlight"): self = .testFlight
        case name == "Software Signing", name.hasPrefix("Apple Code Signing"), name == "Apple iPhone OS Provisioning Profile Signing",
             name.hasPrefix("Apple Software Update"), name == "Apple Installer Signing", name.hasPrefix("Apple Software Signing"):
            self = .apple
        case name.hasPrefix("Apple Development"), name.hasPrefix("Mac Developer"), name.hasPrefix("iPhone Developer"):
            self = .development
        case name.hasPrefix("Apple Distribution"), name.hasPrefix("iPhone Distribution"),
             name.hasPrefix("3rd Party Mac Developer"), name.hasPrefix("Mac App Distribution"), name.hasPrefix("Mac Installer Distribution"):
            self = .distribution
        default: self = .other(name)
        }
    }

    /// From the `validation-category` code signing reports (more reliable than names when present).
    init?(validationCategory: Int) {
        switch validationCategory {
        case 1: self = .apple
        case 2: self = .testFlight
        case 3: self = .development
        case 4: self = .appStore
        case 5: self = .distribution
        case 6: self = .developerID
        default: return nil
        }
    }

    var title: String {
        switch self {
        case .apple: return "Apple"
        case .appStore: return "App Store"
        case .testFlight: return "TestFlight"
        case .developerID: return "Developer ID"
        case .development: return "Development"
        case .distribution: return "Distribution"
        case .adHoc: return "Ad Hoc"
        case .other: return "Signed"
        }
    }

    var badge: InspectorBadge {
        switch self {
        case .apple: return InspectorBadge("signer", symbol: "apple.logo", title: "Apple", tone: .positive, help: "Signed by Apple as part of its own software.")
        case .appStore: return InspectorBadge("signer", symbol: "bag", title: "App Store", tone: .positive, help: "Signed by Apple for distribution through the App Store.")
        case .testFlight: return InspectorBadge("signer", symbol: "airplane", title: "TestFlight", tone: .accent, help: "Signed by Apple for beta testing through TestFlight.")
        case .developerID: return InspectorBadge("signer", symbol: "checkmark.seal", title: "Developer ID", tone: .positive, help: "Signed with a Developer ID certificate for distribution outside the App Store.")
        case .development: return InspectorBadge("signer", symbol: "hammer", title: "Development", tone: .caution, help: "Signed with a development certificate. It runs only on registered devices or the developer’s Mac.")
        case .distribution: return InspectorBadge("signer", symbol: "shippingbox", title: "Distribution", tone: .accent, help: "Signed with a distribution certificate (ad hoc, enterprise or App Store submission).")
        case .adHoc: return InspectorBadge("signer", symbol: "signature", title: "Ad Hoc", tone: .caution, help: "Signed without a certificate. Gatekeeper treats it as coming from an unidentified developer.")
        case .other: return InspectorBadge("signer", symbol: "signature", title: "Signed", tone: .neutral, help: "Signed with a certificate that isn’t one of Apple’s developer certificates.")
        }
    }

    static let unsignedBadge = InspectorBadge("signer", symbol: "xmark.seal", title: "Unsigned", tone: .critical, help: "Not code signed. macOS won’t run it without an explicit exception.")
}

enum CertificateRows {
    /// One row per certificate, leaf first, each expanding to its details.
    static func chain(_ certificates: [CertificateSummary], now: Date = Date()) -> [InspectorItem] {
        certificates.enumerated().map { index, certificate in
            var details: [InspectorItem] = []
            if let organization = certificate.organization { details.append(.field("Organization", organization)) }
            if let unit = certificate.organizationalUnit { details.append(.field("Unit", unit, mono: unit.count == 10)) }
            if let issuer = certificate.issuer { details.append(.field("Issued By", issuer)) }
            if let start = certificate.notBefore { details.append(.field("Valid From", Format.date(start))) }
            if let end = certificate.notAfter {
                let expiry = Format.expiry(end, now: now)
                details.append(.field("Valid Until", Format.date(end), tone: expiry.tone == .critical ? .critical : .neutral))
            }
            details.append(.field("SHA-256", Format.grouped(hex: certificate.sha256), mono: true))
            details.append(.field("SHA-1", Format.grouped(hex: certificate.sha1), mono: true))

            var subtitle: String?
            var tone = InspectorTone.neutral
            if let end = certificate.notAfter {
                let expiry = Format.expiry(end, now: now)
                subtitle = expiry.text
                tone = expiry.tone
            }
            let role = index == 0 ? "Signed by" : (index == certificates.count - 1 && certificate.isSelfSigned ? "Root" : "Intermediate")
            return InspectorItem(symbol: index == 0 ? "person.text.rectangle" : (role == "Root" ? "building.columns" : "arrow.turn.down.right"),
                                 title: certificate.commonName, subtitle: subtitle, value: index == 0 ? nil : role,
                                 tone: tone, help: "SHA-256 " + certificate.sha256, details: details)
        }
    }
}
