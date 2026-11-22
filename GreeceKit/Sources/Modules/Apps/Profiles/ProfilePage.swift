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
                                    subtitle: Format.joined([profile.kind.rawValue + " Profile", profile.platformNames.nilIfEmpty]),
                                    identifier: profile.applicationIdentifier),
            summary: FileSummary(symbol: "person.text.rectangle", title: "Provisioning Profile",
                                 details: [profile.kind.rawValue, expiry?.text].compactMap { $0 }, trailing: modified))
        page.badges.append(InspectorBadge("kind", symbol: kindSymbol(profile.kind), title: profile.kind.rawValue, tone: .accent))
        if let expiry {
            page.badges.append(InspectorBadge("expiry", symbol: expiry.tone == .critical ? "clock.badge.xmark" : "clock",
                                              title: expiry.tone == .critical ? "Expired" : expiry.text, tone: expiry.tone == .neutral ? .positive : expiry.tone,
                                              help: profile.expires.map { "Valid until " + Format.dateTime($0) }))
        }
        if profile.isXcodeManaged {
            page.badges.append(InspectorBadge("managed", symbol: "hammer", title: "Xcode Managed", tone: .neutral, help: "Created and renewed automatically by Xcode."))
        }

        var overview: [InspectorItem] = []
        if let team = profile.teamName { overview.append(.field("Team", profile.teamIDs.first.map { "\(team) (\($0))" } ?? team)) }
        if let app = profile.appIDName { overview.append(.field("App ID", app)) }
        if let identifier = profile.applicationIdentifier { overview.append(.field("Application Identifier", identifier, mono: true)) }
        if let created = profile.created { overview.append(.field("Created", Format.dateTime(created))) }
        if let expires = profile.expires, let expiry {
            overview.append(InspectorItem(title: "Expires", subtitle: expiry.text, value: Format.dateTime(expires), tone: expiry.tone))
        }
        if let uuid = profile.uuid { overview.append(.field("UUID", uuid, mono: true)) }
        page.sections.append(InspectorSection("profile", title: "Profile", rows: overview.map(InspectorRow.item)))

        page.sections.append(devicesSection(profile))
        if let capabilities = capabilitiesSection(profile.entitlements) { page.sections.append(capabilities) }
        if !profile.certificates.isEmpty {
            let rows = profile.certificates.map { certificate -> InspectorRow in
                var details: [InspectorItem] = []
                if let unit = certificate.organizationalUnit { details.append(.field("Team ID", unit, mono: true)) }
                if let issuer = certificate.issuer { details.append(.field("Issued By", issuer)) }
                details.append(.field("SHA-1", Format.grouped(hex: certificate.sha1), mono: true))
                let expiry = certificate.notAfter.map { Format.expiry($0) }
                return .item(InspectorItem(symbol: "person.text.rectangle", title: certificate.commonName, subtitle: expiry?.text,
                                           tone: expiry?.tone ?? .neutral, help: "SHA-1 " + certificate.sha1, details: details))
            }
            page.sections.append(InspectorSection("certificates", title: "Developer Certificates",
                                                  footer: "Code signed with one of these certificates can use this profile.", rows: rows, visibleLimit: 6))
        }
        page.sections.append(signerSection(certificates: profile.signer.map(CertificateSummary.init(certificate:)), intact: profile.signatureIntact))
        return page
    }

    /// The summary shown inside an app's page for its embedded profile.
    static func embeddedSection(_ profile: ProvisioningProfile) -> InspectorSection {
        var rows: [InspectorItem] = []
        rows.append(InspectorItem(symbol: kindSymbol(profile.kind), title: profile.name, value: profile.kind.rawValue))
        if let team = profile.teamName { rows.append(.field("Team", profile.teamIDs.first.map { "\(team) (\($0))" } ?? team)) }
        if let expires = profile.expires {
            let expiry = Format.expiry(expires)
            rows.append(InspectorItem(title: "Expires", subtitle: expiry.text, value: Format.date(expires), tone: expiry.tone))
        }
        if profile.provisionsAllDevices {
            rows.append(.field("Devices", "Any device"))
        } else if !profile.devices.isEmpty {
            rows.append(.field("Devices", Format.count(profile.devices.count, "device")))
        }
        return InspectorSection("embeddedProfile", title: "Provisioning Profile", rows: rows.map(InspectorRow.item))
    }

    private static func devicesSection(_ profile: ProvisioningProfile) -> InspectorSection {
        if profile.provisionsAllDevices {
            return InspectorSection("devices", title: "Devices", rows: [.item(InspectorItem(symbol: "iphone.gen3", title: "Any device",
                                                                                             subtitle: "Enterprise and Developer ID profiles aren’t limited to registered devices."))])
        }
        if profile.devices.isEmpty {
            let text = profile.kind == .appStore || profile.kind == .macAppStore ? "App Store profiles don’t list devices." : "No devices are registered."
            return InspectorSection("devices", title: "Devices", rows: [.item(InspectorItem(symbol: "iphone.gen3", title: text))])
        }
        let rows = profile.devices.map { InspectorRow.item(InspectorItem(symbol: "iphone.gen3", title: $0, mono: true)) }
        return InspectorSection("devices", title: "Devices (\(profile.devices.count.formatted()))", rows: rows, visibleLimit: 5)
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
        return InspectorSection("capabilities", title: "Capabilities", footer: "What apps signed with this profile may use.",
                                rows: rows.map(InspectorRow.item), visibleLimit: 12)
    }

    private static func signerSection(certificates: [CertificateSummary], intact: Bool?) -> InspectorSection {
        var rows: [InspectorRow] = []
        if certificates.isEmpty {
            rows.append(.note(InspectorNote(symbol: "xmark.seal", text: "Not signed.", tone: .caution)))
        } else {
            if intact == false {
                rows.append(.note(InspectorNote(symbol: "exclamationmark.octagon.fill", text: "The signature doesn’t match the contents. The profile was modified.", tone: .critical)))
            }
            rows += CertificateRows.chain(certificates).map(InspectorRow.item)
        }
        return InspectorSection("signer", title: "Signed By", rows: rows)
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
        var page = InspectorPage(
            header: InspectorHeader(icon: .symbol("gearshape.2.fill", .gray), title: profile.name,
                                    subtitle: profile.organization, identifier: profile.identifier),
            summary: FileSummary(symbol: "gearshape.2", title: "Configuration Profile",
                                 details: [Format.count(profile.payloads.count, "payload"), container == nil ? "Unsigned" : "Signed"], trailing: modified))
        if let container, !container.certificates.isEmpty {
            let leaf = CertificateSummary(certificate: container.certificates[0])
            if container.signatureIntact == false {
                page.badges.append(InspectorBadge("signed", symbol: "exclamationmark.octagon.fill", title: "Modified", tone: .critical,
                                                  help: "The signature doesn’t match the contents."))
            } else if SignedContainer.isTrusted(container.certificates) {
                page.badges.append(InspectorBadge("signed", symbol: "checkmark.seal.fill", title: "Verified", tone: .positive,
                                                  help: "Signed by \(leaf.commonName), a certificate this Mac trusts."))
            } else {
                page.badges.append(InspectorBadge("signed", symbol: "checkmark.seal", title: "Signed", tone: .neutral,
                                                  help: "Signed by \(leaf.commonName), but this Mac doesn’t trust that certificate, so System Settings will call it unverified."))
            }
        } else {
            page.badges.append(InspectorBadge("signed", symbol: "seal", title: "Unsigned", tone: .caution, help: "Nothing vouches for who made this profile."))
        }
        if profile.payloads.contains(where: { $0.type == "com.apple.mdm" }) {
            page.badges.append(InspectorBadge("mdm", symbol: "building.2.fill", title: "Device Management", tone: .caution,
                                              help: "Enrolls the Mac in remote management: the organization can install apps, change settings and erase it."))
        }
        if profile.payloads.contains(where: { $0.type == "com.apple.security.root" }) {
            page.badges.append(InspectorBadge("root", symbol: "exclamationmark.shield.fill", title: "Root Certificate", tone: .caution,
                                              help: "Installs a certificate authority. If trusted, it can intercept encrypted connections."))
        }
        if profile.removalDisallowed {
            page.badges.append(InspectorBadge("removal", symbol: "lock.fill", title: "Can’t Be Removed", tone: .caution, help: "PayloadRemovalDisallowed is set."))
        }
        if profile.isEncrypted {
            page.badges.append(InspectorBadge("encrypted", symbol: "lock.doc", title: "Encrypted Payloads", tone: .neutral))
        }

        var overview: [InspectorItem] = []
        if let description = profile.description { overview.append(InspectorItem(title: Format.clean(description, limit: 600))) }
        if let organization = profile.organization { overview.append(.field("Organization", organization)) }
        if let identifier = profile.identifier { overview.append(.field("Identifier", identifier, mono: true)) }
        if let scope = profile.scope { overview.append(.field("Installs For", scope == "System" ? "All users" : "Current user")) }
        if let expiry = profile.expires {
            let text = Format.expiry(expiry)
            overview.append(InspectorItem(title: "Expires", subtitle: text.text, value: Format.date(expiry), tone: text.tone))
        }
        if let uuid = profile.uuid { overview.append(.field("UUID", uuid, mono: true)) }
        if !overview.isEmpty { page.sections.append(InspectorSection("overview", title: "Profile", rows: overview.map(InspectorRow.item))) }

        let payloadRows = profile.payloads.map { payload -> InspectorRow in
            let entry = PayloadCatalog.describe(payload.type)
            var details: [InspectorItem] = []
            for (key, value) in payload.settings.prefix(30) {
                details.append(.field(key, BundlePage.describe(value) ?? (value is Bool ? ((value as? Bool) == true ? "Yes" : "No") : "…"), help: key))
            }
            return .item(InspectorItem(symbol: entry.symbol, tint: entry.tint, title: payload.displayName ?? entry.title,
                                       subtitle: payload.displayName == nil ? payload.summary : Format.joined([entry.title, payload.summary]),
                                       tone: entry.tone, help: payload.type, details: details))
        }
        if !payloadRows.isEmpty {
            page.sections.append(InspectorSection("payloads", title: "Payloads", footer: "What installing this profile changes.", rows: payloadRows, visibleLimit: 12))
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
        name = Format.clean((plist["PayloadDisplayName"] as? String) ?? "Configuration Profile", limit: 200)
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
        case "com.apple.wifi.managed": return string("SSID_STR").map { "Network “\($0)”" }
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
        "com.apple.wifi.managed": .init(title: "Wi-Fi", symbol: "wifi", tint: .blue),
        "com.apple.vpn.managed": .init(title: "VPN", symbol: "lock.shield.fill", tint: .blue, tone: .caution),
        "com.apple.vpn.managed.applayer": .init(title: "Per-app VPN", symbol: "lock.shield.fill", tint: .blue, tone: .caution),
        "com.apple.mdm": .init(title: "Device management", symbol: "building.2.fill", tint: .gray, tone: .caution),
        "com.apple.security.root": .init(title: "Root certificate", symbol: "exclamationmark.shield.fill", tint: .orange, tone: .caution),
        "com.apple.security.pkcs1": .init(title: "Certificate", symbol: "checkmark.seal.fill", tint: .gray),
        "com.apple.security.pem": .init(title: "Certificate", symbol: "checkmark.seal.fill", tint: .gray),
        "com.apple.security.pkcs12": .init(title: "Identity", symbol: "person.badge.key.fill", tint: .gray),
        "com.apple.security.scep": .init(title: "Certificate request (SCEP)", symbol: "person.badge.key", tint: .gray),
        "com.apple.security.acme": .init(title: "Certificate request (ACME)", symbol: "person.badge.key", tint: .gray),
        "com.apple.webClip.managed": .init(title: "Web clip", symbol: "safari.fill", tint: .blue),
        "com.apple.mail.managed": .init(title: "Mail account", symbol: "envelope.fill", tint: .blue),
        "com.apple.eas.account": .init(title: "Exchange account", symbol: "envelope.badge.shield.half.filled", tint: .blue),
        "com.apple.caldav.account": .init(title: "Calendar account", symbol: "calendar", tint: .red),
        "com.apple.carddav.account": .init(title: "Contacts account", symbol: "person.crop.circle.fill", tint: .brown),
        "com.apple.ldap.account": .init(title: "Directory account", symbol: "person.3.fill", tint: .gray),
        "com.apple.dnsSettings.managed": .init(title: "Encrypted DNS", symbol: "network", tint: .blue, tone: .caution),
        "com.apple.dnsProxy.managed": .init(title: "DNS proxy", symbol: "network", tint: .blue, tone: .caution),
        "com.apple.webcontent-filter": .init(title: "Content filter", symbol: "line.3.horizontal.decrease.circle.fill", tint: .orange, tone: .caution),
        "com.apple.proxy.http.global": .init(title: "Global HTTP proxy", symbol: "arrow.triangle.branch", tint: .orange, tone: .caution),
        "com.apple.applicationaccess": .init(title: "Restrictions", symbol: "hand.raised.fill", tint: .red),
        "com.apple.applicationaccess.new": .init(title: "Restrictions", symbol: "hand.raised.fill", tint: .red),
        "com.apple.TCC.configuration-profile-policy": .init(title: "Privacy permissions", symbol: "hand.raised.square.fill", tint: .blue, tone: .caution),
        "com.apple.system-extension-policy": .init(title: "Allowed system extensions", symbol: "puzzlepiece.extension.fill", tint: .orange, tone: .caution),
        "com.apple.syspolicy.kernel-extension-policy": .init(title: "Allowed kernel extensions", symbol: "cpu", tint: .orange, tone: .caution),
        "com.apple.servicemanagement": .init(title: "Managed login items", symbol: "power", tint: .gray),
        "com.apple.notificationsettings": .init(title: "Notifications", symbol: "bell.badge.fill", tint: .red),
        "com.apple.loginwindow": .init(title: "Login window", symbol: "person.crop.square", tint: .gray),
        "com.apple.ManagedClient.preferences": .init(title: "App settings", symbol: "slider.horizontal.3", tint: .gray),
        "com.apple.extensiblesso": .init(title: "Single sign-on", symbol: "person.badge.key.fill", tint: .blue),
        "com.apple.relay.managed": .init(title: "Network relay", symbol: "arrow.triangle.swap", tint: .blue, tone: .caution),
        "com.apple.security.firewall": .init(title: "Firewall", symbol: "flame.fill", tint: .orange),
        "com.apple.MCX.FileVault2": .init(title: "FileVault", symbol: "lock.fill", tint: .gray),
        "com.apple.mobiledevice.passwordpolicy": .init(title: "Passcode policy", symbol: "lock.rectangle.stack.fill", tint: .gray),
        "com.apple.screensaver": .init(title: "Screen saver", symbol: "sparkles.tv", tint: .indigo),
        "com.apple.SoftwareUpdate": .init(title: "Software Update", symbol: "arrow.triangle.2.circlepath", tint: .gray),
        "com.apple.dock": .init(title: "Dock", symbol: "dock.rectangle", tint: .gray),
        "com.apple.font": .init(title: "Font", symbol: "textformat", tint: .gray),
        "com.apple.airprint": .init(title: "AirPrint", symbol: "printer.fill", tint: .gray),
        "com.apple.cellular": .init(title: "Cellular", symbol: "antenna.radiowaves.left.and.right", tint: .green),
        "com.apple.google-oauth": .init(title: "Google account", symbol: "person.crop.circle", tint: .blue),
        "com.apple.associated-domains": .init(title: "Associated domains", symbol: "link", tint: .blue),
    ]
}
