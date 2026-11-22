import AppKit

/// Provisioning profiles (.mobileprovision, .provisionprofile) and configuration profiles (.mobileconfig).
enum ProfilePage {

    // MARK: - Provisioning profiles

    static func provisioningPage(for url: URL, modified: String?) throws -> InspectorPage {
        let data = try readLimited(url, limit: ProvisioningProfile.maxSize)
        guard let profile = ProvisioningProfile(data: data) else { throw PreviewError.unsupported }
        let expiry = profile.expires.map { Format.expiry($0) }
        var page = InspectorPage(
            header: InspectorHeader(icon: .symbol("person.text.rectangle.fill", expiry?.tone == .critical ? .gray : .blue), title: profile.name,
                                    subtitle: Format.joined([profile.kind.profileTitle, profile.platformNames.nilIfEmpty]),
                                    identifier: profile.applicationIdentifier),
            summary: FileSummary(symbol: "person.text.rectangle",
                                 title: String(localized: "Provisioning Profile", bundle: .greeceKit, comment: "A kind of file; also the name of one that has none"),
                                 details: [profile.kind.title, expiry?.text].compactMap { $0 }, trailing: modified))
        page.badges.append(InspectorBadge("kind", symbol: kindSymbol(profile.kind), title: profile.kind.title, tone: .accent))
        if let expiry {
            page.badges.append(InspectorBadge("expiry", symbol: expiry.tone == .critical ? "clock.badge.xmark" : "clock",
                                              title: expiry.tone == .critical ? String(localized: "Expired", bundle: .greeceKit, comment: "Badge: a profile or certificate that has expired")
                                                                              : expiry.text,
                                              tone: expiry.tone == .neutral ? .positive : expiry.tone,
                                              help: profile.expires.map { date in
                                                  let when = Format.dateTime(date)
                                                  return String(localized: "Valid until \(when)", bundle: .greeceKit, comment: "Badge tooltip. The argument is a date and time")
                                              }))
        }
        if profile.isXcodeManaged {
            page.badges.append(InspectorBadge("managed", symbol: "hammer", title: String(localized: "Xcode Managed", bundle: .greeceKit, comment: "Badge on a provisioning profile"),
                                              tone: .neutral, help: String(localized: "Created and renewed automatically by Xcode.", bundle: .greeceKit)))
        }

        var overview: [InspectorItem] = []
        if let team = profile.teamName { overview.append(.field(teamTitle, profile.teamIDs.first.map { "\(team) (\($0))" } ?? team)) }
        if let app = profile.appIDName { overview.append(.field(String(localized: "App ID", bundle: .greeceKit, comment: "Inspector row title: the name of an Apple App ID"), app)) }
        if let identifier = profile.applicationIdentifier {
            overview.append(.field(String(localized: "Application Identifier", bundle: .greeceKit, comment: "Inspector row title"), identifier, mono: true))
        }
        if let created = profile.created {
            overview.append(.field(String(localized: "Created", bundle: .greeceKit, comment: "Inspector row title; its value is a date"), Format.dateTime(created)))
        }
        if let expires = profile.expires, let expiry {
            overview.append(InspectorItem(title: expiresTitle, subtitle: expiry.text, value: Format.dateTime(expires), tone: expiry.tone))
        }
        if let uuid = profile.uuid { overview.append(.field("UUID", uuid, mono: true)) }
        page.sections.append(InspectorSection("profile", title: profileTitle, rows: overview.map(InspectorRow.item)))

        page.sections.append(devicesSection(profile))
        if let capabilities = capabilitiesSection(profile.entitlements) { page.sections.append(capabilities) }
        if !profile.certificates.isEmpty {
            let rows = profile.certificates.map { certificate -> InspectorRow in
                var details: [InspectorItem] = []
                if let unit = certificate.organizationalUnit {
                    details.append(.field(String(localized: "Team ID", bundle: .greeceKit, comment: "Inspector row title: an Apple developer team’s identifier"), unit, mono: true))
                }
                if let issuer = certificate.issuer {
                    details.append(.field(String(localized: "Issued By", bundle: .greeceKit, comment: "Inspector row title; its value names a certificate authority"), issuer))
                }
                details.append(.field("SHA-1", Format.grouped(hex: certificate.sha1), mono: true))
                let expiry = certificate.notAfter.map { Format.expiry($0) }
                return .item(InspectorItem(symbol: "person.text.rectangle", title: certificate.commonName, subtitle: expiry?.text,
                                           tone: expiry?.tone ?? .neutral, help: "SHA-1 " + certificate.sha1, details: details))
            }
            page.sections.append(InspectorSection("certificates", title: String(localized: "Developer Certificates", bundle: .greeceKit, comment: "Section title"),
                                                  footer: String(localized: "Code signed with one of these certificates can use this profile.", bundle: .greeceKit),
                                                  rows: rows, visibleLimit: 6))
        }
        page.sections.append(signerSection(certificates: profile.signer.map(CertificateSummary.init(certificate:)), intact: profile.signatureIntact))
        return page
    }

    /// The summary shown inside an app's page for its embedded profile.
    static func embeddedSection(_ profile: ProvisioningProfile) -> InspectorSection {
        var rows: [InspectorItem] = []
        rows.append(InspectorItem(symbol: kindSymbol(profile.kind), title: profile.name, value: profile.kind.title))
        if let team = profile.teamName { rows.append(.field(teamTitle, profile.teamIDs.first.map { "\(team) (\($0))" } ?? team)) }
        if let expires = profile.expires {
            let expiry = Format.expiry(expires)
            rows.append(InspectorItem(title: expiresTitle, subtitle: expiry.text, value: Format.date(expires), tone: expiry.tone))
        }
        if profile.provisionsAllDevices {
            rows.append(.field(devicesTitle, anyDeviceText))
        } else if !profile.devices.isEmpty {
            rows.append(.field(devicesTitle, String(localized: "\(profile.devices.count) devices", bundle: .greeceKit,
                                                    comment: "Devices a provisioning profile lets an app run on. The argument is a count")))
        }
        return InspectorSection("embeddedProfile", title: String(localized: "Provisioning Profile", bundle: .greeceKit, comment: "A kind of file; also the name of one that has none"),
                                rows: rows.map(InspectorRow.item))
    }

    private static var teamTitle: String {
        String(localized: "Team", bundle: .greeceKit, comment: "Inspector row title: an Apple developer team")
    }

    private static var expiresTitle: String {
        String(localized: "Expires", bundle: .greeceKit, comment: "Inspector row title; its value is a date")
    }

    private static var profileTitle: String {
        String(localized: "Profile", bundle: .greeceKit, comment: "Section title: facts about a provisioning or configuration profile")
    }

    private static var devicesTitle: String {
        String(localized: "Devices", bundle: .greeceKit, comment: "Section or row title: the devices a provisioning profile covers")
    }

    private static var anyDeviceText: String {
        String(localized: "Any device", bundle: .greeceKit, comment: "A provisioning profile that isn’t limited to registered devices")
    }

    private static func devicesSection(_ profile: ProvisioningProfile) -> InspectorSection {
        if profile.provisionsAllDevices {
            return InspectorSection("devices", title: devicesTitle, rows: [
                .item(InspectorItem(symbol: "iphone.gen3", title: anyDeviceText,
                                    subtitle: String(localized: "Enterprise and Developer ID profiles aren’t limited to registered devices.", bundle: .greeceKit))),
            ])
        }
        if profile.devices.isEmpty {
            let text = profile.kind == .appStore || profile.kind == .macAppStore
                ? String(localized: "App Store profiles don’t list devices.", bundle: .greeceKit)
                : String(localized: "No devices are registered.", bundle: .greeceKit)
            return InspectorSection("devices", title: devicesTitle, rows: [.item(InspectorItem(symbol: "iphone.gen3", title: text))])
        }
        let rows = profile.devices.map { InspectorRow.item(InspectorItem(symbol: "iphone.gen3", title: $0, mono: true)) }
        return InspectorSection("devices", title: String(localized: "Devices (\(profile.devices.count))", bundle: .greeceKit,
                                                         comment: "Section title: the devices a provisioning profile covers. The argument is a count"),
                                rows: rows, visibleLimit: 5)
    }

    static func capabilitiesSection(_ entitlements: [String: Any]) -> InspectorSection? {
        var rows: [InspectorItem] = []
        var privateKeys: [String] = []
        for key in entitlements.keys.sorted() where !EntitlementCatalog.hidden.contains(key) {
            let value = entitlements[key]!
            if let flag = value as? Bool, !flag { continue }
            if EntitlementCatalog.isPrivate(key) { privateKeys.append(key); continue }
            let entry = EntitlementCatalog.describe(key, value: value) ?? CatalogEntry(title: key, symbol: "key", tint: .gray)
            rows.append(InspectorItem(symbol: entry.symbol, tint: entry.tint, title: entry.title, subtitle: BundlePage.describe(value),
                                      tone: entry.tone, help: key))
        }
        rows.sort { BundlePage.rank($0.tone) > BundlePage.rank($1.tone) }
        if let group = BundlePage.privateGroup(privateKeys) { rows.append(group) }
        guard !rows.isEmpty else { return nil }
        return InspectorSection("capabilities", title: String(localized: "Capabilities", bundle: .greeceKit, comment: "Section title: what an app’s entitlements let it use"),
                                footer: String(localized: "What apps signed with this profile may use.", bundle: .greeceKit),
                                rows: rows.map(InspectorRow.item), visibleLimit: 12)
    }

    private static func signerSection(certificates: [CertificateSummary], intact: Bool?) -> InspectorSection {
        var rows: [InspectorRow] = []
        if certificates.isEmpty {
            rows.append(.note(InspectorNote(symbol: "xmark.seal", text: String(localized: "Not signed.", bundle: .greeceKit), tone: .caution)))
        } else {
            if intact == false {
                rows.append(.note(InspectorNote(symbol: "exclamationmark.octagon.fill",
                                                text: String(localized: "The signature doesn’t match the contents. The profile was modified.", bundle: .greeceKit),
                                                tone: .critical)))
            }
            rows += CertificateRows.chain(certificates).map(InspectorRow.item)
        }
        return InspectorSection("signer", title: String(localized: "Signed By", bundle: .greeceKit, comment: "Section title: who signed the file"), rows: rows)
    }

    private static func kindSymbol(_ kind: ProvisioningProfile.Kind) -> String {
        switch kind {
        case .development, .macDevelopment: return "hammer"
        case .adHoc: return "person.2"
        case .appStore, .macAppStore: return "bag"
        case .enterprise: return "building.2"
        case .developerID: return "checkmark.seal"
        }
    }

    // MARK: - Configuration profiles

    static func configurationPage(for url: URL, modified: String?) throws -> InspectorPage {
        let data = try readLimited(url, limit: 8 << 20)
        var plistData = data
        var container: SignedContainer?
        if SignedContainer.looksSigned([UInt8](data.prefix(4))) {
            container = SignedContainer(der: data)
            guard let content = container?.content else { throw PreviewError.unsupported }
            plistData = content
        }
        guard let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any] else {
            throw PreviewError.unsupported
        }
        let profile = ConfigurationProfile(plist: plist)
        let signed = String(localized: "Signed", bundle: .greeceKit, comment: "Badge")
        let unsigned = String(localized: "Unsigned", bundle: .greeceKit, comment: "Badge")
        var page = InspectorPage(
            header: InspectorHeader(icon: .symbol("gearshape.2.fill", .gray), title: profile.name,
                                    subtitle: profile.organization, identifier: profile.identifier),
            summary: FileSummary(symbol: "gearshape.2",
                                 title: String(localized: "Configuration Profile", bundle: .greeceKit, comment: "A kind of file; also the name of one that has none"),
                                 details: [String(localized: "\(profile.payloads.count) payloads", bundle: .greeceKit,
                                                  comment: "Info bar detail: the settings a configuration profile installs. The argument is a count"),
                                           container == nil ? unsigned : signed],
                                 trailing: modified))
        if let container, !container.certificates.isEmpty {
            let leaf = CertificateSummary(certificate: container.certificates[0])
            if container.signatureIntact == false {
                page.badges.append(InspectorBadge("signed", symbol: "exclamationmark.octagon.fill",
                                                  title: String(localized: "Modified", bundle: .greeceKit, comment: "Badge: a signed profile was changed after signing"), tone: .critical,
                                                  help: String(localized: "The signature doesn’t match the contents.", bundle: .greeceKit)))
            } else if SignedContainer.isTrusted(container.certificates) {
                page.badges.append(InspectorBadge("signed", symbol: "checkmark.seal.fill",
                                                  title: String(localized: "Verified", bundle: .greeceKit, comment: "Badge: signed by a certificate this Mac trusts"), tone: .positive,
                                                  help: String(localized: "Signed by \(leaf.commonName), a certificate this Mac trusts.", bundle: .greeceKit,
                                                               comment: "Badge tooltip. The argument is the certificate’s name")))
            } else {
                page.badges.append(InspectorBadge("signed", symbol: "checkmark.seal", title: signed, tone: .neutral,
                                                  help: String(localized: "Signed by \(leaf.commonName), but this Mac doesn’t trust that certificate, so System Settings will call it unverified.",
                                                               bundle: .greeceKit, comment: "Badge tooltip. The argument is the certificate’s name")))
            }
        } else {
            page.badges.append(InspectorBadge("signed", symbol: "seal", title: unsigned, tone: .caution,
                                              help: String(localized: "Nothing vouches for who made this profile.", bundle: .greeceKit)))
        }
        if profile.payloads.contains(where: { $0.type == "com.apple.mdm" }) {
            page.badges.append(InspectorBadge("mdm", symbol: "building.2.fill", title: String(localized: "Device Management", bundle: .greeceKit, comment: "Badge: a profile that enrolls the Mac in MDM"),
                                              tone: .caution,
                                              help: String(localized: "Enrolls the Mac in remote management: the organization can install apps, change settings and erase it.", bundle: .greeceKit)))
        }
        if profile.payloads.contains(where: { $0.type == "com.apple.security.root" }) {
            page.badges.append(InspectorBadge("root", symbol: "exclamationmark.shield.fill",
                                              title: String(localized: "Root Certificate", bundle: .greeceKit, comment: "Badge: a profile that installs a certificate authority"), tone: .caution,
                                              help: String(localized: "Installs a certificate authority. If trusted, it can intercept encrypted connections.", bundle: .greeceKit)))
        }
        if profile.removalDisallowed {
            page.badges.append(InspectorBadge("removal", symbol: "lock.fill", title: String(localized: "Can’t Be Removed", bundle: .greeceKit, comment: "Badge on a configuration profile"),
                                              tone: .caution,
                                              help: String(localized: "PayloadRemovalDisallowed is set.", bundle: .greeceKit, comment: "Badge tooltip. PayloadRemovalDisallowed is a setting’s name: keep it as is")))
        }
        if profile.isEncrypted {
            page.badges.append(InspectorBadge("encrypted", symbol: "lock.doc", title: String(localized: "Encrypted Payloads", bundle: .greeceKit, comment: "Badge on a configuration profile"),
                                              tone: .neutral))
        }

        var overview: [InspectorItem] = []
        if let description = profile.description { overview.append(InspectorItem(title: Format.clean(description, limit: 600))) }
        if let organization = profile.organization {
            overview.append(.field(String(localized: "Organization", bundle: .greeceKit, comment: "Inspector row title"), organization))
        }
        if let identifier = profile.identifier {
            overview.append(.field(String(localized: "Identifier", bundle: .greeceKit, comment: "Inspector row title"), identifier, mono: true))
        }
        if let scope = profile.scope {
            overview.append(.field(String(localized: "Installs For", bundle: .greeceKit, comment: "Inspector row title; its value says who a profile installs for"),
                                   scope == "System" ? String(localized: "All users", bundle: .greeceKit, comment: "Who a package or profile installs for")
                                                     : String(localized: "Current user", bundle: .greeceKit, comment: "A package or profile installs only for the person using the Mac")))
        }
        if let expiry = profile.expires {
            let text = Format.expiry(expiry)
            overview.append(InspectorItem(title: expiresTitle, subtitle: text.text, value: Format.date(expiry), tone: text.tone))
        }
        if let uuid = profile.uuid { overview.append(.field("UUID", uuid, mono: true)) }
        if !overview.isEmpty { page.sections.append(InspectorSection("overview", title: profileTitle, rows: overview.map(InspectorRow.item))) }

        let yes = String(localized: "Yes", bundle: .greeceKit), no = String(localized: "No", bundle: .greeceKit)
        let payloadRows = profile.payloads.map { payload -> InspectorRow in
            let entry = PayloadCatalog.describe(payload.type)
            var details: [InspectorItem] = []
            for (key, value) in payload.settings.prefix(30) {
                details.append(.field(key, BundlePage.describe(value) ?? (value is Bool ? ((value as? Bool) == true ? yes : no) : "…"), help: key))
            }
            return .item(InspectorItem(symbol: entry.symbol, tint: entry.tint, title: payload.displayName ?? entry.title,
                                       subtitle: payload.displayName == nil ? payload.summary : Format.joined([entry.title, payload.summary]),
                                       tone: entry.tone, help: payload.type, details: details))
        }
        if !payloadRows.isEmpty {
            page.sections.append(InspectorSection("payloads", title: String(localized: "Payloads", bundle: .greeceKit, comment: "Section title: the settings a configuration profile installs"),
                                                  footer: String(localized: "What installing this profile changes.", bundle: .greeceKit),
                                                  rows: payloadRows, visibleLimit: 12))
        }
        if let container, !container.certificates.isEmpty {
            page.sections.append(signerSection(certificates: container.certificates.map(CertificateSummary.init(certificate:)), intact: container.signatureIntact))
        }
        return page
    }

    static func readLimited(_ url: URL, limit: Int) throws -> Data {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard size <= limit else { throw PreviewError.unsupported }
        return try Data(contentsOf: url)
    }
}

/// A configuration profile's payloads, flattened for display.
struct ConfigurationProfile {
    struct Payload {
        var type: String
        var displayName: String?
        var identifier: String?
        var summary: String?
        var settings: [(String, Any)]
    }

    var name: String
    var organization: String?
    var identifier: String?
    var description: String?
    var uuid: String?
    var scope: String?
    var expires: Date?
    var removalDisallowed: Bool
    var isEncrypted: Bool
    var payloads: [Payload]

    init(plist: [String: Any]) {
        name = Format.clean((plist["PayloadDisplayName"] as? String)
                            ?? String(localized: "Configuration Profile", bundle: .greeceKit, comment: "A kind of file; also the name of one that has none"), limit: 200)
        organization = (plist["PayloadOrganization"] as? String).map { Format.clean($0, limit: 200) }
        identifier = (plist["PayloadIdentifier"] as? String).map { Format.clean($0, limit: 200) }
        description = (plist["PayloadDescription"] as? String).map { Format.clean($0, limit: 600) }
        uuid = plist["PayloadUUID"] as? String
        scope = plist["PayloadScope"] as? String
        expires = plist["RemovalDate"] as? Date ?? plist["ExpirationDate"] as? Date
        removalDisallowed = plist["PayloadRemovalDisallowed"] as? Bool ?? false
        isEncrypted = plist["EncryptedPayloadContent"] != nil
        let content = (plist["PayloadContent"] as? [[String: Any]]) ?? []
        let ignored: Set<String> = ["PayloadType", "PayloadVersion", "PayloadUUID", "PayloadIdentifier", "PayloadDisplayName", "PayloadDescription", "PayloadOrganization", "PayloadEnabled"]
        payloads = content.prefix(200).map { item in
            let type = item["PayloadType"] as? String ?? "Unknown"
            var settings: [(String, Any)] = []
            for key in item.keys.sorted() where !ignored.contains(key) { settings.append((key, item[key]!)) }
            return Payload(type: type, displayName: (item["PayloadDisplayName"] as? String).map { Format.clean($0, limit: 120) },
                           identifier: item["PayloadIdentifier"] as? String, summary: ConfigurationProfile.summary(type: type, item: item),
                           settings: settings)
        }
    }

    /// The one fact that matters most for each payload type.
    static func summary(type: String, item: [String: Any]) -> String? {
        func string(_ key: String) -> String? { (item[key] as? String).map { Format.clean($0, limit: 120) } }
        switch type {
        case "com.apple.wifi.managed":
            return string("SSID_STR").map { network in
                String(localized: "Network “\(network)”", bundle: .greeceKit, comment: "A Wi-Fi setting in a configuration profile. The argument is the network’s name")
            }
        case "com.apple.vpn.managed": return string("UserDefinedName") ?? string("VPNType")
        case "com.apple.mdm": return string("ServerURL")
        case "com.apple.webClip.managed": return string("URL")
        case "com.apple.dnsSettings.managed":
            return ((item["DNSSettings"] as? [String: Any])?["ServerURL"] as? String) ?? ((item["DNSSettings"] as? [String: Any])?["DNSProtocol"] as? String)
        case "com.apple.security.root", "com.apple.security.pkcs1", "com.apple.security.pem", "com.apple.security.pkcs12":
            if let data = item["PayloadContent"] as? Data, let certificate = CertificateSummary(der: data) { return certificate.commonName }
            return string("PayloadCertificateFileName")
        case "com.apple.ManagedClient.preferences":
            return (item["PayloadContent"] as? [String: Any]).map { $0.keys.sorted().prefix(3).joined(separator: ", ") }
        case "com.apple.TCC.configuration-profile-policy":
            return (item["Services"] as? [String: Any]).map { $0.keys.sorted().prefix(4).joined(separator: ", ") }
        default: return nil
        }
    }
}

enum PayloadCatalog {
    static func describe(_ type: String) -> CatalogEntry {
        entries[type] ?? CatalogEntry(title: type.split(separator: ".").last.map { String($0).capitalized } ?? type, symbol: "gearshape", tint: .gray)
    }

    static let entries: [String: CatalogEntry] = [
        "com.apple.wifi.managed": .init(title: String(localized: "Wi-Fi", bundle: .greeceKit, comment: "A kind of setting a configuration profile installs"), symbol: "wifi", tint: .blue),
        "com.apple.vpn.managed": .init(title: String(localized: "VPN", bundle: .greeceKit, comment: "A kind of setting a configuration profile installs"), symbol: "lock.shield.fill", tint: .blue, tone: .caution),
        "com.apple.vpn.managed.applayer": .init(title: String(localized: "Per-app VPN", bundle: .greeceKit, comment: "A kind of setting a configuration profile installs"), symbol: "lock.shield.fill", tint: .blue, tone: .caution),
        "com.apple.mdm": .init(title: String(localized: "Device management", bundle: .greeceKit, comment: "A kind of setting a configuration profile installs"), symbol: "building.2.fill", tint: .gray, tone: .caution),
        "com.apple.security.root": .init(title: String(localized: "Root certificate", bundle: .greeceKit, comment: "A kind of setting a configuration profile installs"), symbol: "exclamationmark.shield.fill", tint: .orange, tone: .caution),
        "com.apple.security.pkcs1": .init(title: String(localized: "Certificate", bundle: .greeceKit, comment: "A kind of setting a configuration profile installs"), symbol: "checkmark.seal.fill", tint: .gray),
        "com.apple.security.pem": .init(title: String(localized: "Certificate", bundle: .greeceKit, comment: "A kind of setting a configuration profile installs"), symbol: "checkmark.seal.fill", tint: .gray),
        "com.apple.security.pkcs12": .init(title: String(localized: "Identity", bundle: .greeceKit, comment: "A kind of setting a configuration profile installs"), symbol: "person.badge.key.fill", tint: .gray),
        "com.apple.security.scep": .init(title: String(localized: "Certificate request (SCEP)", bundle: .greeceKit, comment: "A kind of setting a configuration profile installs"), symbol: "person.badge.key", tint: .gray),
        "com.apple.security.acme": .init(title: String(localized: "Certificate request (ACME)", bundle: .greeceKit, comment: "A kind of setting a configuration profile installs"), symbol: "person.badge.key", tint: .gray),
        "com.apple.webClip.managed": .init(title: String(localized: "Web clip", bundle: .greeceKit, comment: "A kind of setting a configuration profile installs"), symbol: "safari.fill", tint: .blue),
        "com.apple.mail.managed": .init(title: String(localized: "Mail account", bundle: .greeceKit, comment: "A kind of setting a configuration profile installs"), symbol: "envelope.fill", tint: .blue),
        "com.apple.eas.account": .init(title: String(localized: "Exchange account", bundle: .greeceKit, comment: "A kind of setting a configuration profile installs"), symbol: "envelope.badge.shield.half.filled", tint: .blue),
        "com.apple.caldav.account": .init(title: String(localized: "Calendar account", bundle: .greeceKit, comment: "A kind of setting a configuration profile installs"), symbol: "calendar", tint: .red),
        "com.apple.carddav.account": .init(title: String(localized: "Contacts account", bundle: .greeceKit, comment: "A kind of setting a configuration profile installs"), symbol: "person.crop.circle.fill", tint: .brown),
        "com.apple.ldap.account": .init(title: String(localized: "Directory account", bundle: .greeceKit, comment: "A kind of setting a configuration profile installs"), symbol: "person.3.fill", tint: .gray),
        "com.apple.dnsSettings.managed": .init(title: String(localized: "Encrypted DNS", bundle: .greeceKit, comment: "A kind of setting a configuration profile installs"), symbol: "network", tint: .blue, tone: .caution),
        "com.apple.dnsProxy.managed": .init(title: String(localized: "DNS proxy", bundle: .greeceKit, comment: "A kind of setting a configuration profile installs"), symbol: "network", tint: .blue, tone: .caution),
        "com.apple.webcontent-filter": .init(title: String(localized: "Content filter", bundle: .greeceKit, comment: "A kind of setting a configuration profile installs"), symbol: "line.3.horizontal.decrease.circle.fill", tint: .orange, tone: .caution),
        "com.apple.proxy.http.global": .init(title: String(localized: "Global HTTP proxy", bundle: .greeceKit, comment: "A kind of setting a configuration profile installs"), symbol: "arrow.triangle.branch", tint: .orange, tone: .caution),
        "com.apple.applicationaccess": .init(title: String(localized: "Restrictions", bundle: .greeceKit, comment: "A kind of setting a configuration profile installs"), symbol: "hand.raised.fill", tint: .red),
        "com.apple.applicationaccess.new": .init(title: String(localized: "Restrictions", bundle: .greeceKit, comment: "A kind of setting a configuration profile installs"), symbol: "hand.raised.fill", tint: .red),
        "com.apple.TCC.configuration-profile-policy": .init(title: String(localized: "Privacy permissions", bundle: .greeceKit, comment: "A kind of setting a configuration profile installs"), symbol: "hand.raised.square.fill", tint: .blue, tone: .caution),
        "com.apple.system-extension-policy": .init(title: String(localized: "Allowed system extensions", bundle: .greeceKit, comment: "A kind of setting a configuration profile installs"), symbol: "puzzlepiece.extension.fill", tint: .orange, tone: .caution),
        "com.apple.syspolicy.kernel-extension-policy": .init(title: String(localized: "Allowed kernel extensions", bundle: .greeceKit, comment: "A kind of setting a configuration profile installs"), symbol: "cpu", tint: .orange, tone: .caution),
        "com.apple.servicemanagement": .init(title: String(localized: "Managed login items", bundle: .greeceKit, comment: "A kind of setting a configuration profile installs"), symbol: "power", tint: .gray),
        "com.apple.notificationsettings": .init(title: String(localized: "Notifications", bundle: .greeceKit, comment: "A kind of setting a configuration profile installs"), symbol: "bell.badge.fill", tint: .red),
        "com.apple.loginwindow": .init(title: String(localized: "Login window", bundle: .greeceKit, comment: "A kind of setting a configuration profile installs"), symbol: "person.crop.square", tint: .gray),
        "com.apple.ManagedClient.preferences": .init(title: String(localized: "App settings", bundle: .greeceKit, comment: "A kind of setting a configuration profile installs"), symbol: "slider.horizontal.3", tint: .gray),
        "com.apple.extensiblesso": .init(title: String(localized: "Single sign-on", bundle: .greeceKit, comment: "A kind of setting a configuration profile installs"), symbol: "person.badge.key.fill", tint: .blue),
        "com.apple.relay.managed": .init(title: String(localized: "Network relay", bundle: .greeceKit, comment: "A kind of setting a configuration profile installs"), symbol: "arrow.triangle.swap", tint: .blue, tone: .caution),
        "com.apple.security.firewall": .init(title: String(localized: "Firewall", bundle: .greeceKit, comment: "A kind of setting a configuration profile installs"), symbol: "flame.fill", tint: .orange),
        "com.apple.MCX.FileVault2": .init(title: "FileVault", symbol: "lock.fill", tint: .gray),
        "com.apple.mobiledevice.passwordpolicy": .init(title: String(localized: "Passcode policy", bundle: .greeceKit, comment: "A kind of setting a configuration profile installs"), symbol: "lock.rectangle.stack.fill", tint: .gray),
        "com.apple.screensaver": .init(title: String(localized: "Screen saver", bundle: .greeceKit, comment: "A kind of setting a configuration profile installs"), symbol: "sparkles.tv", tint: .indigo),
        "com.apple.SoftwareUpdate": .init(title: String(localized: "Software Update", bundle: .greeceKit, comment: "A kind of setting a configuration profile installs"), symbol: "arrow.triangle.2.circlepath", tint: .gray),
        "com.apple.dock": .init(title: "Dock", symbol: "dock.rectangle", tint: .gray),
        "com.apple.font": .init(title: String(localized: "Font", bundle: .greeceKit, comment: "A kind of setting a configuration profile installs"), symbol: "textformat", tint: .gray),
        "com.apple.airprint": .init(title: "AirPrint", symbol: "printer.fill", tint: .gray),
        "com.apple.cellular": .init(title: String(localized: "Cellular", bundle: .greeceKit, comment: "A kind of setting a configuration profile installs"), symbol: "antenna.radiowaves.left.and.right", tint: .green),
        "com.apple.google-oauth": .init(title: String(localized: "Google account", bundle: .greeceKit, comment: "A kind of setting a configuration profile installs"), symbol: "person.crop.circle", tint: .blue),
        "com.apple.associated-domains": .init(title: String(localized: "Associated domains", bundle: .greeceKit, comment: "A kind of setting a configuration profile installs"), symbol: "link", tint: .blue),
    ]
}
