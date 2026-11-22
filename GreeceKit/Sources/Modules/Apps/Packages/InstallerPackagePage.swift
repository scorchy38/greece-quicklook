import Foundation

/// The inspector page for an installer package: who signed it, whether Apple notarized it,
/// what it installs where, what runs in the background afterwards, and its scripts.
enum InstallerPackagePage {

    static func sniff(probe: [UInt8], ext: String, isDirectory: Bool = false) -> Bool {
        InstallerPackage.sniff(probe: probe, ext: ext, isDirectory: isDirectory)
    }

    static func page(for url: URL, settings: PreviewSettings) throws -> InspectorPage {
        let package = try InstallerPackage.read(url)
        return page(for: package, showHidden: settings.showHiddenFiles)
    }

    static func page(for package: InstallerPackage, showHidden: Bool = false, now: Date = Date()) -> InspectorPage {
        let distribution = package.distribution
        let components = package.components
        let single = components.count == 1 ? components.first : nil

        // Header.
        let fileName = package.url.deletingPathExtension().lastPathComponent
        let title = distribution?.title ?? fileName
        let version = distribution?.productVersion ?? single?.version
            ?? components.compactMap(\.version).first.flatMap { v in components.allSatisfy { $0.version == v || $0.version == nil } ? v : nil }
        let identifier = distribution?.productID ?? single?.identifier
        let header = InspectorHeader(icon: .contentType("com.apple.installer-package-archive"), title: title,
                                     subtitle: Format.version(version, build: nil), identifier: identifier)

        var page = InspectorPage(header: header, summary: summary(for: package, now: now))
        page.badges = badges(for: package)

        page.sections.append(signatureSection(package, now: now))
        page.sections += installsSections(package)
        page.sections += systemSections(package)
        if let section = scriptFindingsSection(package) { page.sections.append(section) }
        if let section = scriptsSection(package) { page.sections.append(section) }
        if let section = choicesSection(package) { page.sections.append(section) }
        if let section = requirementsSection(package) { page.sections.append(section) }
        if let section = packagesSection(package) { page.sections.append(section) }
        if let section = bundlesSection(package) { page.sections.append(section) }
        if let license = package.license, !license.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let licenseTitle = String(localized: "License Agreement", bundle: .greeceKit, comment: "Section title: a software license shown before installing")
            page.sections.append(InspectorSection("license", title: licenseTitle, rows: [
                .code(InspectorCode(symbol: "doc.text", title: licenseTitle,
                                    subtitle: String(localized: "Shown before installing", bundle: .greeceKit, comment: "Under an installer package’s license agreement"),
                                    text: license, grammar: "plaintext", truncated: license.count >= InstallerPackage.scriptLimit)),
            ]))
        }
        page.sections.append(infoSection(package))
        page.contents = contents(for: package, showHidden: showHidden)
        return page
    }

    // MARK: Badges

    /// The signer, trusting Apple's developer programmes only when the chain really leads to Apple.
    static func signerKind(_ signature: InstallerPackage.SignatureInfo) -> SignerKind {
        guard let leaf = signature.certificates.first else { return .adHoc }
        guard signature.chainsToApple else { return .other(leaf.commonName) }
        if ["Software Update", "Apple Software Update", "Software Signing"].contains(leaf.commonName) { return .apple }
        return SignerKind(leafCommonName: leaf.commonName)
    }

    static func badges(for package: InstallerPackage) -> [InspectorBadge] {
        var badges: [InspectorBadge] = []
        if let signature = package.signature, !signature.certificates.isEmpty {
            if signature.chainsToApple {
                badges.append(signerKind(signature).badge)
            } else {
                badges.append(InspectorBadge("signer", symbol: "exclamationmark.triangle",
                                             title: String(localized: "Untrusted Certificate", bundle: .greeceKit, comment: "Badge"), tone: .caution,
                                             help: String(localized: "Signed with a certificate that doesn’t lead to Apple. Installer treats it like an unsigned package.", bundle: .greeceKit,
                                                          comment: "Badge tooltip. Installer is the macOS app that installs packages")))
            }
            if signature.verdict == .invalid || signature.checksumMatches == false {
                badges.append(InspectorBadge("integrity", symbol: "exclamationmark.octagon",
                                             title: String(localized: "Signature Invalid", bundle: .greeceKit, comment: "Badge"), tone: .critical,
                                             help: String(localized: "The package changed after it was signed, or its signature is damaged.", bundle: .greeceKit)))
            }
        } else {
            badges.append(InspectorBadge("signer", symbol: "xmark.seal", title: String(localized: "Unsigned", bundle: .greeceKit, comment: "Badge"), tone: .critical,
                                         help: String(localized: "Not signed. Installer will say it comes from an unidentified developer.", bundle: .greeceKit,
                                                      comment: "Badge tooltip. Installer is the macOS app that installs packages")))
        }
        if let ticket = package.ticket {
            if package.ticketMatches {
                let help: String
                if let notarized = ticket.notarizedAt {
                    let date = Format.date(notarized)
                    help = String(localized: "Apple’s notarization ticket for this package is stapled to it (\(date)).", bundle: .greeceKit,
                                  comment: "Badge tooltip. The argument is the date Apple notarized the package")
                } else {
                    help = String(localized: "Apple’s notarization ticket for this package is stapled to it.", bundle: .greeceKit)
                }
                badges.append(InspectorBadge("notarization", symbol: "checkmark.shield",
                                             title: String(localized: "Notarized", bundle: .greeceKit, comment: "Badge"), tone: .positive, help: help))
            } else {
                badges.append(InspectorBadge("notarization", symbol: "exclamationmark.shield",
                                             title: String(localized: "Ticket Mismatch", bundle: .greeceKit, comment: "Badge: the stapled notarization ticket is for another package"),
                                             tone: .caution,
                                             help: String(localized: "A notarization ticket is stapled, but it doesn’t list this package.", bundle: .greeceKit)))
            }
        }
        if let badge = architectureBadge(package.distribution?.hostArchitectures ?? []) { badges.append(badge) }
        let scripts = package.allScripts
        if !scripts.isEmpty {
            let root = package.components.contains { $0.installsAsRoot && !$0.scripts.isEmpty } || !package.productScripts.isEmpty
            badges.append(InspectorBadge("scripts", symbol: "terminal", title: String(localized: "Runs Scripts", bundle: .greeceKit, comment: "Badge on an installer package"),
                                         tone: .caution,
                                         help: root ? String(localized: "Installer runs this package’s scripts with administrator privileges.", bundle: .greeceKit)
                                                    : String(localized: "Installer runs this package’s scripts during installation.", bundle: .greeceKit)))
        }
        let actions = package.components.compactMap { $0.postinstallAction?.lowercased() }
        if package.distribution?.requiresRestart == true || actions.contains(where: { $0.contains("restart") || $0.contains("shutdown") }) {
            badges.append(InspectorBadge("restart", symbol: "arrow.clockwise", title: String(localized: "Requires Restart", bundle: .greeceKit, comment: "Badge on an installer package"),
                                         tone: .caution, help: String(localized: "Your Mac restarts after installing.", bundle: .greeceKit)))
        } else if actions.contains(where: { $0.contains("logout") }) {
            badges.append(InspectorBadge("restart", symbol: "rectangle.portrait.and.arrow.right",
                                         title: String(localized: "Requires Logout", bundle: .greeceKit, comment: "Badge on an installer package"), tone: .caution,
                                         help: String(localized: "You’re logged out after installing.", bundle: .greeceKit)))
        }
        return badges
    }

    static func architectureBadge(_ architectures: [String]) -> InspectorBadge? {
        let lower = Set(architectures.map { $0.lowercased() })
        let arm = lower.contains("arm64") || lower.contains("arm64e")
        let intel = lower.contains("x86_64") || lower.contains("i386")
        switch (arm, intel) {
        case (true, true):
            return InspectorBadge("architecture", symbol: "cpu", title: String(localized: "Universal", bundle: .greeceKit, comment: "Badge: runs on every processor architecture"),
                                  tone: .neutral, help: String(localized: "Installer runs natively on Apple silicon and Intel.", bundle: .greeceKit))
        case (true, false):
            return InspectorBadge("architecture", symbol: "cpu", title: String(localized: "Apple silicon", bundle: .greeceKit, comment: "The Macs an installer runs on: only those with Apple silicon"),
                                  tone: .neutral, help: String(localized: "Installer opens it only on a Mac with Apple silicon.", bundle: .greeceKit))
        case (false, true):
            return InspectorBadge("architecture", symbol: "exclamationmark.triangle",
                                  title: String(localized: "Intel only", bundle: .greeceKit, comment: "Badge: an installer that runs natively only on Intel Macs"), tone: .caution,
                                  help: String(localized: "On a Mac with Apple silicon, Installer needs Rosetta to open it.", bundle: .greeceKit))
        default:
            return nil
        }
    }

    static func hostArchitectureText(_ architectures: [String]) -> String? {
        let lower = Set(architectures.map { $0.lowercased() })
        guard !lower.isEmpty else { return nil }
        let arm = lower.contains("arm64") || lower.contains("arm64e")
        let intel = lower.contains("x86_64") || lower.contains("i386")
        switch (arm, intel) {
        case (true, true): return String(localized: "Apple silicon and Intel", bundle: .greeceKit, comment: "The Macs an installer runs on")
        case (true, false): return String(localized: "Apple silicon", bundle: .greeceKit, comment: "The Macs an installer runs on: only those with Apple silicon")
        case (false, true): return String(localized: "Intel (Rosetta on Apple silicon)", bundle: .greeceKit, comment: "The Macs an installer runs on")
        default: return architectures.joined(separator: ", ")
        }
    }

    // MARK: Signature

    static func signatureSection(_ package: InstallerPackage, now: Date) -> InspectorSection {
        let sectionTitle = String(localized: "Signature", bundle: .greeceKit, comment: "Section title, and the row title for whether the signature checks out")
        var rows: [InspectorRow] = []
        if let signature = package.signature, let leaf = signature.certificates.first {
            let kind = signerKind(signature)
            let signer = leaf.organization ?? leaf.commonName.replacingOccurrences(of: #"^[^:]+:\s*"#, with: "", options: .regularExpression)
            rows.append(.item(InspectorItem(symbol: "signature", title: String(localized: "Signed By", bundle: .greeceKit, comment: "Inspector row title; its value is who signed the file"),
                                            value: signer, help: leaf.commonName)))
            if let team = leaf.organizationalUnit, team.count == 10, team.allSatisfy({ $0.isUppercase || $0.isNumber }) {
                rows.append(.item(.field(String(localized: "Team ID", bundle: .greeceKit, comment: "Inspector row title: an Apple developer team’s identifier"), team, mono: true)))
            }
            rows.append(.item(.field(String(localized: "Certificate", bundle: .greeceKit, comment: "Inspector row title; its value is the kind of signing certificate"),
                                     certificateKindText(kind, leaf: leaf, chainsToApple: signature.chainsToApple),
                                     tone: signature.chainsToApple ? .neutral : .caution,
                                     help: signature.chainsToApple ? leaf.commonName
                                                                   : String(localized: "The certificate chain doesn’t lead to one of Apple’s roots.", bundle: .greeceKit))))

            switch (signature.verdict, signature.checksumMatches) {
            case (_, false?):
                rows.append(.item(.field(sectionTitle, String(localized: "Contents changed after signing", bundle: .greeceKit), tone: .critical,
                                         help: String(localized: "The table of contents no longer matches its checksum.", bundle: .greeceKit))))
            case (.valid, _):
                rows.append(.item(.field(sectionTitle, String(localized: "Valid", bundle: .greeceKit, comment: "A signature that checks out"), tone: .positive,
                                         help: String(localized: "The signature over the package’s table of contents matches the signing certificate.", bundle: .greeceKit))))
            case (.invalid, _):
                rows.append(.item(.field(sectionTitle, String(localized: "Doesn’t match the certificate", bundle: .greeceKit, comment: "A signature that doesn’t check out"),
                                         tone: .critical,
                                         help: String(localized: "The RSA signature doesn’t verify with the signing certificate’s key.", bundle: .greeceKit))))
            case (.unknown, _):
                rows.append(.item(.field(sectionTitle, signature.hasCMS ? String(localized: "Present (CMS)", bundle: .greeceKit, comment: "A signature Greece found but didn’t check")
                                                                          : String(localized: "Not checked", bundle: .greeceKit, comment: "A signature Greece didn’t check"))))
            }
            if let date = signature.signedAt {
                rows.append(.item(.field(String(localized: "Signed [date]", defaultValue: "Signed", bundle: .greeceKit,
                                                comment: "Inspector row title; its value is the date and time the file was signed"),
                                         Format.dateTime(date),
                                         help: signature.trustedTimestamp ? String(localized: "From Apple’s trusted timestamp service.", bundle: .greeceKit)
                                                                          : String(localized: "The signing time the signer recorded.", bundle: .greeceKit))))
            }
            rows.append(.item(notarizationItem(package)))
            var chain = CertificateRows.chain(signature.certificates, now: now)
            // A trusted timestamp keeps a signature valid after its certificate expires.
            if signature.trustedTimestamp {
                for index in chain.indices where chain[index].tone == .critical { chain[index].tone = .neutral }
            }
            rows += chain.map { .item($0) }
            return InspectorSection("signature", title: sectionTitle, rows: rows)
        }
        rows.append(.note(InspectorNote(symbol: "exclamationmark.triangle",
                                        text: String(localized: "This package isn’t signed, so there’s no way to tell who made it or whether it changed since. Installer will warn that it’s from an unidentified developer.", bundle: .greeceKit),
                                        tone: .caution)))
        rows.append(.item(notarizationItem(package)))
        return InspectorSection("signature", title: sectionTitle, rows: rows)
    }

    static func certificateKindText(_ kind: SignerKind, leaf: CertificateSummary, chainsToApple: Bool) -> String {
        if !chainsToApple {
            return leaf.isSelfSigned ? String(localized: "Self-signed", bundle: .greeceKit, comment: "A certificate that vouches for itself")
                                     : String(localized: "Not issued by Apple", bundle: .greeceKit, comment: "A certificate")
        }
        if let prefix = leaf.commonName.split(separator: ":").first, leaf.commonName.contains(":") { return String(prefix) }
        switch kind {
        case .apple: return String(localized: "Apple Software", bundle: .greeceKit, comment: "A certificate Apple signs its own software with")
        case .other(let name): return name
        default: return kind.title
        }
    }

    static func notarizationItem(_ package: InstallerPackage) -> InspectorItem {
        let title = String(localized: "Notarization", bundle: .greeceKit, comment: "Inspector row title")
        guard let ticket = package.ticket else {
            return .field(title, String(localized: "No stapled ticket", bundle: .greeceKit, comment: "No notarization ticket is attached to the package"),
                          help: String(localized: "Gatekeeper can still find a ticket online when the package opens. Greece only reads what’s in the file.", bundle: .greeceKit))
        }
        if package.ticketMatches {
            let stapled = String(localized: "Ticket stapled", bundle: .greeceKit, comment: "A notarization ticket is attached to the package")
            return .field(title, Format.joined([stapled, ticket.notarizedAt.map(Format.date)]), tone: .positive,
                          help: String(localized: "Apple’s notarization ticket is stapled and lists this package’s checksum.", bundle: .greeceKit))
        }
        return .field(title, String(localized: "Ticket doesn’t list this package", bundle: .greeceKit), tone: .caution,
                      help: String(localized: "A ticket is stapled, but none of its entries matches this package’s checksum.", bundle: .greeceKit))
    }

    // MARK: Installs

    struct Destination {
        var path: String
        var files = 0
        var bytes: UInt64 = 0
        var isDirectory = false
    }

    /// System folders a package installs into, rather than items it owns.
    static let containers: Set<String> = [
        "Applications", "Applications/Utilities", "Library", "System", "System/Library", "System/Applications", "usr", "usr/local", "usr/local/bin",
        "usr/local/lib", "usr/local/share", "usr/local/include", "usr/local/sbin", "usr/local/etc", "usr/bin", "usr/lib", "usr/share", "usr/sbin",
        "usr/local/share/man", "usr/share/man", "opt", "private", "private/etc", "private/var", "etc", "var", "Users", "Users/Shared",
        "Library/Application Support", "Library/LaunchDaemons", "Library/LaunchAgents", "Library/Extensions", "Library/PrivilegedHelperTools",
        "Library/Frameworks", "Library/Preferences", "Library/Audio", "Library/Audio/Plug-Ins", "Library/Audio/Plug-Ins/HAL",
        "Library/Audio/Plug-Ins/Components", "Library/Audio/Plug-Ins/VST", "Library/Audio/Plug-Ins/VST3", "Library/Internet Plug-Ins",
        "Library/QuickLook", "Library/Spotlight", "Library/PreferencePanes", "Library/Fonts", "Library/Printers", "Library/Security",
        "Library/Security/SecurityAgentPlugins", "Library/Screen Savers", "Library/Input Methods", "Library/Services", "Library/Scripts",
        "Library/StartupItems", "Library/Apple", "Library/Apple/System", "Library/Apple/System/Library", "Library/Apple/usr",
        "Library/Apple/System/Library/Extensions", "Library/Apple/System/Library/PrivateFrameworks", "Library/Apple/System/Library/Frameworks",
        "Library/Apple/usr/libexec", "Library/Apple/usr/lib", "Library/Apple/usr/bin",
        "System/Library/Extensions", "System/Library/PrivateFrameworks", "System/Library/Frameworks", "System/Library/CoreServices",
        "System/Library/LaunchDaemons", "System/Library/LaunchAgents", "System/Library/Preferences",
        "System/Library/Filesystems", "System/Library/Services", "System/Library/Spotlight", "System/Library/QuickLook", "System/Library/Fonts",
        "Library/Apple/System/Library/LaunchDaemons", "Library/Apple/System/Library/LaunchAgents", "Library/Apple/System/Library/Preferences",
        "Library/Apple/System/Library/CoreServices", "Library/Apple/System/Library/Receipts", "Library/Apple/Library", "Library/Apple/Library/Bundles", "Library/Developer", "Library/Developer/CommandLineTools",
        "Library/Managed Preferences", "Library/Keychains", "Library/Documentation", "Library/Caches", "Library/Logs",
        "Library/Application Support/Apple", "private/etc/paths.d", "etc/paths.d", "Library/Filesystems", "Library/Image Capture",
        "Library/Image Capture/Devices", "Library/ColorSync", "Library/ColorSync/Profiles", "Library/Contextual Menu Items",
        "Library/Components", "Library/Modem Scripts", "Library/Widgets", "Library/Address Book Plug-Ins", "Library/Mail", "Library/Mail/Bundles",
    ]

    /// Top-level things a component installs, keyed by full path ("/Applications/zoom.us.app").
    static func destinations(_ package: InstallerPackage) -> [Destination] {
        var byPath: [String: Destination] = [:]
        var order: [String] = []
        for component in package.components {
            for entry in component.payload ?? [] {
                let full = component.installedPath(entry.path)
                let parts = full.split(separator: "/")
                guard !parts.isEmpty else { continue }
                var depth = 1
                while depth < parts.count && containers.contains(parts[0..<depth].joined(separator: "/")) { depth += 1 }
                let key = "/" + parts[0..<depth].joined(separator: "/")
                if depth == parts.count && entry.kind == .directory && containers.contains(parts.joined(separator: "/")) { continue }
                var destination = byPath[key] ?? Destination(path: key)
                if byPath[key] == nil { order.append(key) }
                if entry.kind == .directory {
                    if depth == parts.count { destination.isDirectory = true }
                } else {
                    destination.files += 1
                    if entry.kind == .file { destination.bytes = destination.bytes.saturatingAdd(entry.size) }
                    if depth < parts.count { destination.isDirectory = true }
                }
                byPath[key] = destination
            }
        }
        return order.compactMap { byPath[$0] }.sorted { $0.bytes > $1.bytes }
    }

    static func symbol(forPath path: String, isDirectory: Bool) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "app": return "macwindow"
        case "kext": return "puzzlepiece.extension"
        case "framework", "bundle", "plugin", "component", "driver", "vst", "vst3", "aaxplugin": return "shippingbox"
        case "dylib", "so", "a": return "building.columns"
        case "plist": return "doc.text"
        case "pkg", "mpkg": return "shippingbox"
        case "ttf", "otf", "ttc": return "textformat"
        case "prefpane": return "gearshape"
        case "qlgenerator", "appex": return "puzzlepiece"
        default: return isDirectory ? "folder" : "doc"
        }
    }

    /// "12 files": how many files a package or folder holds.
    private static func filesText(_ count: Int) -> String {
        String(localized: "\(count) files", bundle: .greeceKit, comment: "The argument is a count")
    }

    /// Who the package lets you install for, from its distribution's `domains`.
    static func domainsText(_ domains: [String]) -> String? {
        let allUsers = domains.contains("localSystem"), justYou = domains.contains("currentUserHome"), anyDisk = domains.contains("anywhere")
        switch (allUsers, justYou, anyDisk) {
        case (true, true, true): return String(localized: "All users or just you or any disk", bundle: .greeceKit, comment: "Who or where an installer package can install for")
        case (true, true, false): return String(localized: "All users or just you", bundle: .greeceKit, comment: "Who an installer package can install for")
        case (true, false, true): return String(localized: "All users or any disk", bundle: .greeceKit, comment: "Who or where an installer package can install for")
        case (false, true, true): return String(localized: "Just you or any disk", bundle: .greeceKit, comment: "Who or where an installer package can install for")
        case (true, false, false): return String(localized: "All users", bundle: .greeceKit, comment: "Who a package or profile installs for")
        case (false, true, false): return String(localized: "Just you", bundle: .greeceKit, comment: "Who an installer package can install for: only the person installing it")
        case (false, false, true): return String(localized: "Any disk", bundle: .greeceKit, comment: "Where an installer package can install")
        case (false, false, false): return nil
        }
    }

    /// Where things go (a list that can be long), then how Installer goes about it.
    static func installsSections(_ package: InstallerPackage) -> [InspectorSection] {
        let destinations = destinations(package)
        var rows: [InspectorRow] = destinations.prefix(200).map { destination in
            let subtitle = destination.isDirectory
                ? Format.joined([filesText(destination.files), destination.bytes > 0 ? Format.bytes(destination.bytes) : nil])
                : (destination.bytes > 0 ? Format.bytes(destination.bytes) : String(localized: "Empty file", bundle: .greeceKit))
            return .item(InspectorItem(symbol: symbol(forPath: destination.path, isDirectory: destination.isDirectory),
                                       title: destination.path, subtitle: subtitle, help: destination.path))
        }
        // Components without a readable payload still say where they go.
        for component in package.components where (component.payload ?? []).isEmpty {
            let size = component.installKBytes.map { Format.bytes(UInt64(max(0, $0)) * 1024) }
            let files = component.declaredFiles.map(filesText)
            rows.append(.item(InspectorItem(symbol: "folder", title: component.installLocation,
                                            subtitle: Format.joined([files, size]).nilIfEmpty
                                                ?? String(localized: "Contents unknown", bundle: .greeceKit, comment: "What a package installs isn’t known"),
                                            help: component.identifier)))
        }
        guard !rows.isEmpty || !package.components.isEmpty else { return [] }

        var facts: [InspectorItem] = []
        let root = package.components.contains { $0.installsAsRoot }
        if !package.components.isEmpty {
            facts.append(.field(installsAsTitle, root ? administratorText : currentUserText,
                                help: root ? String(localized: "Installer asks for an administrator password and writes files as root.", bundle: .greeceKit)
                                           : String(localized: "Installs without administrator privileges.", bundle: .greeceKit)))
        }
        if let domains = package.distribution?.domains, !domains.isEmpty, let text = domainsText(domains) {
            facts.append(.field(String(localized: "Install For", bundle: .greeceKit, comment: "Inspector row title; its value says who a package installs for"), text))
        }
        let relocatable = package.components.contains { $0.relocatable }
        if relocatable {
            facts.append(.field(String(localized: "Updates", bundle: .greeceKit, comment: "Inspector row title: how a package updates an app already installed"),
                                String(localized: "Existing copies where they are", bundle: .greeceKit, comment: "How a package updates an app: wherever you moved it"),
                                help: String(localized: "The package is relocatable: if you moved a previous version, Installer updates it there.", bundle: .greeceKit)))
        }
        let files = package.installedFiles
        if files > 0 { facts.append(.field(String(localized: "Files", bundle: .greeceKit, comment: "Inspector row title; its value is a count"), files.formatted())) }
        let bytes = package.installedBytes
        if bytes > 0 { facts.append(.field(String(localized: "Installed Size", bundle: .greeceKit, comment: "Inspector row title"), Format.bytes(bytes))) }
        let truncated = package.components.contains { $0.payloadTruncated }
        let installsTitle = String(localized: "Installs", bundle: .greeceKit, comment: "Section title: what a package installs and where")
        var sections: [InspectorSection] = []
        if !rows.isEmpty {
            sections.append(InspectorSection("installs", title: installsTitle,
                                             footer: truncated ? String(localized: "Showing the first part of a very large payload.", bundle: .greeceKit) : nil,
                                             rows: rows, visibleLimit: rows.count > 10 ? 8 : nil))
        }
        if !facts.isEmpty {
            sections.append(InspectorSection("install-details", title: rows.isEmpty ? installsTitle : nil, rows: facts.map { .item($0) }))
        }
        return sections
    }

    private static var installsAsTitle: String {
        String(localized: "Installs As", bundle: .greeceKit, comment: "Inspector row title; its value is “Administrator” or “Current user”")
    }

    private static var administratorText: String {
        String(localized: "Administrator", bundle: .greeceKit, comment: "A package installs with administrator privileges")
    }

    private static var currentUserText: String {
        String(localized: "Current user", bundle: .greeceKit, comment: "A package or profile installs only for the person using the Mac")
    }

    // MARK: Background items and extensions

    struct SystemItem {
        var kind: String
        var symbol: String
        var tint: InspectorTint
        var note: String?
        var tone: InspectorTone
        var background: Bool
    }

    /// Recognises what a payload path adds to macOS, keyed by its parent folder.
    static func systemItem(forPath path: String) -> (SystemItem, name: String, owner: String)? {
        let parts = path.split(separator: "/").map(String.init)
        func match(_ folder: [String], _ item: SystemItem, extensions: [String]? = nil) -> (SystemItem, String, String)? {
            // Also match the same folders under /Library/Apple (system volume group locations).
            for offset in [0, 2] where parts.count == folder.count + offset + 1 {
                if offset == 2 && Array(parts.prefix(2)) != ["Library", "Apple"] { continue }
                guard Array(parts[offset..<(offset + folder.count)]) == folder else { continue }
                let name = parts[offset + folder.count]
                if let extensions, !extensions.contains((name as NSString).pathExtension.lowercased()) { return nil }
                return (item, name, "/" + parts.joined(separator: "/"))
            }
            return nil
        }
        let daemon = SystemItem(kind: String(localized: "Launch Daemon", bundle: .greeceKit, comment: "Something a package installs: a background process that runs as root"),
                                symbol: "gearshape.2", tint: .gray,
                                note: String(localized: "Runs as root, at startup", bundle: .greeceKit), tone: .caution, background: true)
        let agent = SystemItem(kind: String(localized: "Launch Agent", bundle: .greeceKit, comment: "Something a package installs: a background process that runs for each user"),
                               symbol: "person.crop.circle.badge.clock", tint: .blue,
                               note: String(localized: "Runs for every user who logs in", bundle: .greeceKit), tone: .neutral, background: true)
        let helper = SystemItem(kind: String(localized: "Privileged Helper", bundle: .greeceKit, comment: "Something a package installs: a tool an app uses to act as root"),
                                symbol: "lock.shield", tint: .orange,
                                note: String(localized: "Runs as root when the app asks", bundle: .greeceKit), tone: .caution, background: true)
        let startup = SystemItem(kind: String(localized: "Startup Item", bundle: .greeceKit, comment: "Something a package installs"), symbol: "power", tint: .gray,
                                 note: String(localized: "Runs at startup (legacy)", bundle: .greeceKit), tone: .caution, background: true)
        let kext = SystemItem(kind: String(localized: "Kernel Extension", bundle: .greeceKit, comment: "Something a package installs"), symbol: "cpu", tint: .red,
                              note: String(localized: "Loads into the kernel, after you allow it", bundle: .greeceKit), tone: .caution, background: false)
        let authorization = SystemItem(kind: String(localized: "Authorization Plug-in", bundle: .greeceKit, comment: "Something a package installs"), symbol: "key", tint: .red,
                                       note: String(localized: "Takes part in logging in and unlocking", bundle: .greeceKit), tone: .caution, background: false)
        let audio = SystemItem(kind: String(localized: "Audio Driver", bundle: .greeceKit, comment: "Something a package installs"), symbol: "speaker.wave.2", tint: .pink,
                               note: nil, tone: .neutral, background: false)
        let audioUnit = SystemItem(kind: String(localized: "Audio Unit", bundle: .greeceKit, comment: "Something a package installs: an audio effect or instrument plug-in"),
                                   symbol: "waveform", tint: .pink, note: nil, tone: .neutral, background: false)
        let browser = SystemItem(kind: String(localized: "Browser Plug-in", bundle: .greeceKit, comment: "Something a package installs"), symbol: "globe", tint: .blue,
                                 note: nil, tone: .neutral, background: false)
        let quickLook = SystemItem(kind: String(localized: "Quick Look Plug-in", bundle: .greeceKit, comment: "Something a package installs"), symbol: "eye", tint: .gray,
                                   note: nil, tone: .neutral, background: false)
        let spotlight = SystemItem(kind: String(localized: "Spotlight Importer", bundle: .greeceKit, comment: "Something a package installs"), symbol: "magnifyingglass", tint: .gray,
                                   note: nil, tone: .neutral, background: false)
        let pane = SystemItem(kind: String(localized: "Settings Pane", bundle: .greeceKit, comment: "Something a package installs: a pane in System Settings"), symbol: "gearshape",
                              tint: .gray, note: nil, tone: .neutral, background: false)
        let saver = SystemItem(kind: String(localized: "Screen Saver", bundle: .greeceKit, comment: "Something a package installs"), symbol: "sparkles.tv", tint: .indigo,
                               note: nil, tone: .neutral, background: false)
        let input = SystemItem(kind: String(localized: "Input Method", bundle: .greeceKit, comment: "Something a package installs: a way to type another script, such as Chinese"),
                               symbol: "keyboard", tint: .gray, note: nil, tone: .neutral, background: false)
        let filesystem = SystemItem(kind: String(localized: "File System", bundle: .greeceKit, comment: "Something a package installs: support for a kind of disk"),
                                    symbol: "externaldrive", tint: .gray, note: nil, tone: .neutral, background: false)
        let paths = SystemItem(kind: String(localized: "Shell Path", bundle: .greeceKit, comment: "Something a package installs: a folder added to the command line’s search path"),
                               symbol: "terminal", tint: .gray,
                               note: String(localized: "Adds to every shell’s PATH", bundle: .greeceKit), tone: .neutral, background: false)
        let mail = SystemItem(kind: String(localized: "Mail Plug-in", bundle: .greeceKit, comment: "Something a package installs"), symbol: "envelope", tint: .blue,
                              note: nil, tone: .neutral, background: false)

        let rules: [([String], SystemItem, [String]?)] = [
            (["Library", "LaunchDaemons"], daemon, ["plist"]),
            (["System", "Library", "LaunchDaemons"], daemon, ["plist"]),
            (["Library", "LaunchAgents"], agent, ["plist"]),
            (["System", "Library", "LaunchAgents"], agent, ["plist"]),
            (["Library", "PrivilegedHelperTools"], helper, nil),
            (["Library", "StartupItems"], startup, nil),
            (["Library", "Extensions"], kext, ["kext"]),
            (["System", "Library", "Extensions"], kext, ["kext"]),
            (["Library", "Security", "SecurityAgentPlugins"], authorization, nil),
            (["Library", "Audio", "Plug-Ins", "HAL"], audio, nil),
            (["Library", "Audio", "Plug-Ins", "Components"], audioUnit, nil),
            (["Library", "Internet Plug-Ins"], browser, nil),
            (["Library", "QuickLook"], quickLook, nil),
            (["Library", "Spotlight"], spotlight, nil),
            (["Library", "PreferencePanes"], pane, nil),
            (["Library", "Screen Savers"], saver, nil),
            (["Library", "Input Methods"], input, nil),
            (["Library", "Filesystems"], filesystem, nil),
            (["Library", "Mail", "Bundles"], mail, nil),
            (["private", "etc", "paths.d"], paths, nil),
            (["etc", "paths.d"], paths, nil),
        ]
        for (folder, item, extensions) in rules {
            if let found = match(folder, item, extensions: extensions) { return found }
        }
        return nil
    }

    static func systemSections(_ package: InstallerPackage) -> [InspectorSection] {
        var background: [InspectorItem] = []
        var extensions: [InspectorItem] = []
        var seen = Set<String>()
        for component in package.components {
            for entry in component.payload ?? [] {
                let full = component.installedPath(entry.path)
                guard let (item, name, path) = systemItem(forPath: full), seen.insert(path).inserted else { continue }
                // Launch items are plists; bundles count as one item however deep they go.
                if item.background == false && entry.kind != .directory && ["kext", "bundle", "plugin", "driver", "component", "qlgenerator",
                                                                            "mdimporter", "prefpane", "saver", "app", "fs", "mailbundle"].contains((name as NSString).pathExtension.lowercased()) { continue }
                let label = item.background ? (name as NSString).deletingPathExtension : name
                let row = InspectorItem(symbol: item.symbol, tint: item.tint, title: item.kind, subtitle: label,
                                        value: item.note, tone: item.tone, help: path)
                if item.background { background.append(row) } else { extensions.append(row) }
                if background.count + extensions.count >= 200 { break }
            }
        }
        var sections: [InspectorSection] = []
        if !background.isEmpty {
            sections.append(InspectorSection("background", title: String(localized: "Background Items", bundle: .greeceKit, comment: "Section title"),
                                             footer: String(localized: "These run automatically, without you opening an app. You can turn them off in Login Items & Extensions.", bundle: .greeceKit,
                                                            comment: "Section footer. “Login Items & Extensions” is a pane in System Settings"),
                                             rows: background.map { .item($0) }, visibleLimit: background.count > 10 ? 8 : nil))
        }
        if !extensions.isEmpty {
            sections.append(InspectorSection("extensions", title: String(localized: "Extensions & Plug-ins", bundle: .greeceKit, comment: "Section title"),
                                             rows: extensions.map { .item($0) }, visibleLimit: extensions.count > 10 ? 8 : nil))
        }
        return sections
    }

    // MARK: Scripts

    struct ScriptFinding {
        let pattern: String
        let symbol: String
        let tint: InspectorTint
        let title: String
        let detail: String
        let tone: InspectorTone
    }

    /// Commands worth knowing about before you let a script run as root. A heuristic over the text,
    /// so the section says it's based on what the scripts mention.
    static let findings: [ScriptFinding] = [
        ScriptFinding(pattern: #"security\s+(add-trusted-cert|add-certificates|import)\b"#, symbol: "lock.trianglebadge.exclamationmark", tint: .red,
                      title: String(localized: "Adds certificates", bundle: .greeceKit, comment: "What an installer script does"),
                      detail: String(localized: "Can make your Mac trust new certificates", bundle: .greeceKit), tone: .critical),
        ScriptFinding(pattern: #"spctl\s+(--master-disable|--global-disable|--add|--disable)"#, symbol: "shield.slash", tint: .red,
                      title: String(localized: "Changes Gatekeeper", bundle: .greeceKit, comment: "What an installer script does"),
                      detail: String(localized: "Changes which apps macOS allows to open", bundle: .greeceKit), tone: .critical),
        ScriptFinding(pattern: #"\btccutil\b|TCC\.db"#, symbol: "hand.raised", tint: .orange,
                      title: String(localized: "Changes privacy permissions", bundle: .greeceKit, comment: "What an installer script does"),
                      detail: String(localized: "Resets or edits Privacy & Security permissions", bundle: .greeceKit,
                                     comment: "“Privacy & Security” is a pane in System Settings"), tone: .caution),
        ScriptFinding(pattern: #"\b(curl|wget)\b|NSURLSession|urllib|requests\.get"#, symbol: "arrow.down.circle", tint: .blue,
                      title: String(localized: "Downloads files", bundle: .greeceKit, comment: "What an installer script does"),
                      detail: String(localized: "Fetches files from the internet while installing", bundle: .greeceKit), tone: .caution),
        ScriptFinding(pattern: #"(^|[\s"'=:(])/Library/LaunchDaemons|launchctl\s+(load\s+(-w\s+)?["']?/Library/LaunchDaemons|bootstrap\s+system)"#,
                      symbol: "gearshape.2", tint: .gray,
                      title: String(localized: "Sets up a launch daemon", bundle: .greeceKit, comment: "What an installer script does"),
                      detail: String(localized: "Something that runs as root in the background", bundle: .greeceKit), tone: .caution),
        ScriptFinding(pattern: #"(^|[\s"'=:(~}]|HOME)/Library/LaunchAgents|launchctl\s+bootstrap\s+gui"#, symbol: "person.crop.circle.badge.clock", tint: .blue,
                      title: String(localized: "Sets up a launch agent", bundle: .greeceKit, comment: "What an installer script does"),
                      detail: String(localized: "Something that runs in the background when you log in", bundle: .greeceKit), tone: .neutral),
        ScriptFinding(pattern: #"\b(kextload|kmutil\s+load|kextcache)\b"#, symbol: "cpu", tint: .red,
                      title: String(localized: "Loads a kernel extension", bundle: .greeceKit, comment: "What an installer script does"),
                      detail: String(localized: "Code that runs inside the kernel", bundle: .greeceKit), tone: .caution),
        ScriptFinding(pattern: #"systemextensionsctl|SystemExtensions"#, symbol: "puzzlepiece.extension", tint: .purple,
                      title: String(localized: "Manages system extensions", bundle: .greeceKit, comment: "What an installer script does"),
                      detail: String(localized: "Drivers or network and security extensions", bundle: .greeceKit), tone: .neutral),
        ScriptFinding(pattern: #"chmod\s+([ugoa]*\+s|[0-7]?[4-7][0-7]{3})\b"#, symbol: "person.badge.key", tint: .orange,
                      title: String(localized: "Sets special permissions", bundle: .greeceKit, comment: "What an installer script does: file permissions such as setuid"),
                      detail: String(localized: "Makes a program run with its owner’s privileges", bundle: .greeceKit), tone: .caution),
        ScriptFinding(pattern: #"\b(killall|pkill)\b|kill\s+-9"#, symbol: "xmark.app", tint: .gray,
                      title: String(localized: "Quits running apps", bundle: .greeceKit, comment: "What an installer script does"),
                      detail: String(localized: "Stops processes while installing", bundle: .greeceKit), tone: .neutral),
        ScriptFinding(pattern: #"/etc/(sudoers|hosts|paths)|/private/etc/"#, symbol: "doc.badge.gearshape", tint: .orange,
                      title: String(localized: "Edits system files", bundle: .greeceKit, comment: "What an installer script does"),
                      detail: String(localized: "Changes configuration in /etc", bundle: .greeceKit), tone: .caution),
        ScriptFinding(pattern: #"\bprofiles\s+(install|-I)\b"#, symbol: "person.badge.shield.checkmark", tint: .orange,
                      title: String(localized: "Installs a profile", bundle: .greeceKit, comment: "What an installer script does"),
                      detail: String(localized: "Adds a configuration profile", bundle: .greeceKit), tone: .caution),
        ScriptFinding(pattern: #"\bdscl\s+\S+\s+-(create|append|delete|passwd|change|merge)\b|\bsysadminctl\s+-(addUser|deleteUser|resetPasswordFor|secureTokenOn)|\bdseditgroup\s+-o\s+(edit|create|delete)"#,
                      symbol: "person.2", tint: .orange,
                      title: String(localized: "Changes users or groups", bundle: .greeceKit, comment: "What an installer script does"),
                      detail: String(localized: "Creates or edits accounts", bundle: .greeceKit), tone: .caution),
    ]

    private static let compiledFindings: [(ScriptFinding, NSRegularExpression)] = findings.compactMap { finding in
        (try? NSRegularExpression(pattern: finding.pattern, options: [.caseInsensitive])).map { (finding, $0) }
    }

    /// One row per kind of command found; the tooltip quotes the first line that mentions it.
    static func scriptFindings(_ scripts: [InstallerPackage.Script]) -> [InspectorItem] {
        let candidates = scripts.filter { $0.role != .support && $0.text != nil }
        guard !candidates.isEmpty else { return [] }
        return compiledFindings.compactMap { finding, expression in
            for script in candidates {
                guard let text = script.text,
                      let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                      let range = Range(match.range, in: text) else { continue }
                let lineNumber = text[..<range.lowerBound].reduce(into: 1) { if $1 == "\n" { $0 += 1 } }
                let lineStart = text[..<range.lowerBound].lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
                let lineEnd = text[range.lowerBound...].firstIndex(of: "\n") ?? text.endIndex
                let line = Format.clean(String(text[lineStart..<lineEnd]), limit: 160)
                let number = String(lineNumber)
                return InspectorItem(symbol: finding.symbol, tint: finding.tint, title: finding.title, subtitle: finding.detail,
                                     tone: finding.tone,
                                     help: String(localized: "\(script.name), line \(number): \(line)", bundle: .greeceKit,
                                                  comment: "Tooltip quoting a script. The arguments are the script’s name, a line number and that line’s text"))
            }
            return nil
        }
    }

    static func scriptFindingsSection(_ package: InstallerPackage) -> InspectorSection? {
        let items = scriptFindings(package.allScripts)
        guard !items.isEmpty else { return nil }
        return InspectorSection("script-findings", title: String(localized: "What the Scripts Do", bundle: .greeceKit, comment: "Section title on an installer package’s page"),
                                footer: String(localized: "Based on the commands the scripts contain. Greece doesn’t run them.", bundle: .greeceKit),
                                rows: items.map { .item($0) })
    }

    static func scriptsSection(_ package: InstallerPackage) -> InspectorSection? {
        var rows: [InspectorRow] = []
        let componentScripts = package.components.flatMap { component in component.scripts.map { (component, $0) } }
        let multiple = package.components.filter { !$0.scripts.isEmpty }.count > 1
        if !componentScripts.isEmpty || !package.productScripts.isEmpty {
            let root = package.components.contains { $0.installsAsRoot && !$0.scripts.isEmpty }
            rows.append(.note(InspectorNote(symbol: "exclamationmark.triangle",
                                            text: root ? String(localized: "Installer runs these scripts as root, with full access to your Mac.", bundle: .greeceKit)
                                                       : String(localized: "Installer runs these scripts while it installs.", bundle: .greeceKit),
                                            tone: .caution)))
        }
        let usedByScripts = String(localized: "Used by the scripts", bundle: .greeceKit, comment: "Under a file an installer’s scripts read, such as a property list")
        func row(_ script: InstallerPackage.Script, owner: String?) -> InspectorRow {
            let support = script.role == .support
            guard let text = script.text else {
                return .item(InspectorItem(symbol: support ? "doc" : "gearshape", title: script.name,
                                           subtitle: Format.joined([support ? usedByScripts : String(localized: "Compiled program", bundle: .greeceKit, comment: "An installer script that isn’t text"),
                                                                    Format.bytes(script.size), owner]),
                                           tone: support ? .neutral : .caution,
                                           help: support ? nil : String(localized: "Greece can’t show compiled code.", bundle: .greeceKit)))
            }
            let language = support ? fileKindName(script.grammar) : languageName(script.grammar)
            let subtitle = Format.joined([support ? usedByScripts : owner, linesText(script.lineCount), language])
            return .code(InspectorCode(symbol: support ? "doc.text" : "terminal", title: script.name, subtitle: subtitle, text: text,
                                       grammar: script.grammar, tone: support ? .neutral : .caution, truncated: script.truncated))
        }
        for (component, script) in componentScripts {
            rows.append(row(script, owner: multiple ? (component.identifier ?? component.name) : nil))
        }
        for script in package.productScripts {
            rows.append(row(script, owner: script.role == .support ? nil
                                : String(localized: "Run by the installer’s JavaScript", bundle: .greeceKit, comment: "Under a script that the installer’s own JavaScript runs")))
        }
        if let javaScript = package.distribution?.javaScript {
            let checks = package.distribution?.installationCheck != nil || package.distribution?.volumeCheck != nil
            rows.append(.code(InspectorCode(symbol: "curlybraces", title: String(localized: "Installer JavaScript", bundle: .greeceKit, comment: "The JavaScript in an installer package"),
                                            subtitle: Format.joined([checks ? String(localized: "Checks your Mac before installing", bundle: .greeceKit) : nil,
                                                                     linesText(javaScript.reduce(into: 1) { if $1 == "\n" { $0 += 1 } })]),
                                            text: javaScript, grammar: "javascript", tone: .neutral,
                                            truncated: javaScript.count >= InstallerPackage.scriptLimit)))
            if package.distribution?.allowExternalScripts == true {
                rows.append(.note(InspectorNote(symbol: "exclamationmark.triangle",
                                                text: String(localized: "Its JavaScript is allowed to run commands on your Mac.", bundle: .greeceKit), tone: .caution)))
            }
        }
        guard !rows.isEmpty else { return nil }
        return InspectorSection("scripts", title: String(localized: "Installer Scripts", bundle: .greeceKit, comment: "Section title"), rows: rows)
    }

    /// "60 lines": the length of a script.
    private static func linesText(_ count: Int) -> String {
        String(localized: "\(count) lines", bundle: .greeceKit, comment: "Length of a script or document. The argument is a count")
    }

    static func fileKindName(_ grammar: String) -> String {
        switch grammar {
        case "xml": return String(localized: "Property list", bundle: .greeceKit, comment: "A kind of file")
        case "json": return "JSON"
        default: return languageName(grammar)
        }
    }

    static func languageName(_ grammar: String) -> String {
        switch grammar {
        case "bash": return String(localized: "Shell script", bundle: .greeceKit, comment: "A kind of file")
        case "python": return "Python"
        case "perl": return "Perl"
        case "ruby": return "Ruby"
        case "applescript": return "AppleScript"
        case "javascript": return "JavaScript"
        default: return String(localized: "Text", bundle: .greeceKit, comment: "A kind of file: plain text")
        }
    }

    // MARK: Choices and requirements

    static func choicesSection(_ package: InstallerPackage) -> InspectorSection? {
        guard let distribution = package.distribution else { return nil }
        let ordered = distribution.outline.compactMap { id in distribution.choices.first { $0.id == id } }
        let choices = (ordered.isEmpty ? distribution.choices : ordered).filter { $0.visible && !$0.packageRefs.isEmpty }
        guard choices.count >= 2 else { return nil }
        let rows: [InspectorRow] = choices.prefix(100).map { choice in
            let details = choice.packageRefs.map { ref -> InspectorItem in
                let info = distribution.packageRefs[ref]
                return .field(info?.identifier ?? ref, info?.version, mono: false)
            }
            return .item(InspectorItem(symbol: "checklist", title: choice.title ?? choice.id, subtitle: choice.description,
                                       help: choice.id, details: details))
        }
        let footer = distribution.customize == "never"
            ? String(localized: "Installer picks these for you; it doesn’t offer a Customize step.", bundle: .greeceKit,
                     comment: "Section footer. “Customize” is a button in macOS Installer")
            : String(localized: "You can pick what to install in Installer’s Customize step.", bundle: .greeceKit,
                     comment: "Section footer. “Customize” is a button in macOS Installer")
        return InspectorSection("choices", title: String(localized: "Choices", bundle: .greeceKit, comment: "Section title: the parts of a package you can pick to install"),
                                footer: footer, rows: rows, visibleLimit: rows.count > 10 ? 8 : nil)
    }

    static func requirementsSection(_ package: InstallerPackage) -> InspectorSection? {
        guard let distribution = package.distribution else { return nil }
        var items: [InspectorItem] = []
        if let minimum = distribution.minimumOS {
            let text = distribution.maximumOS.map { maximum in
                String(localized: "macOS \(minimum) to before \(maximum)", bundle: .greeceKit,
                       comment: "The macOS versions a package installs on. The arguments are versions, such as “12.0” and “15.0”")
            } ?? String(localized: "macOS \(minimum) or later", bundle: .greeceKit, comment: "The oldest macOS a package or app runs on. The argument is a version, such as “12.0”")
            items.append(.field("macOS", text))
        } else if let maximum = distribution.maximumOS {
            items.append(.field("macOS", String(localized: "Before \(maximum)", bundle: .greeceKit,
                                                comment: "The macOS versions a package installs on: older than this. The argument is a version, such as “15.0”")))
        }
        if let text = hostArchitectureText(distribution.hostArchitectures) {
            items.append(.field(String(localized: "Installer Runs On", bundle: .greeceKit, comment: "Inspector row title; its value says which Macs the installer runs on"),
                                text, tone: distribution.hostArchitectures.contains { $0.hasPrefix("arm64") } ? .neutral : .caution,
                                help: String(localized: "The architectures the package’s hostArchitectures option allows.", bundle: .greeceKit)))
        }
        if distribution.rootVolumeOnly {
            items.append(.field(String(localized: "Destination", bundle: .greeceKit, comment: "Inspector row title: where a package can install"),
                                String(localized: "Startup disk only", bundle: .greeceKit)))
        }
        let checksMac = distribution.installationCheck != nil, checksDisk = distribution.volumeCheck != nil
        if checksMac || checksDisk {
            let text: String
            switch (checksMac, checksDisk) {
            case (true, true): text = String(localized: "Checks your Mac and the destination disk first", bundle: .greeceKit, comment: "What an installer does before installing")
            case (true, false): text = String(localized: "Checks your Mac first", bundle: .greeceKit, comment: "What an installer does before installing")
            default: text = String(localized: "Checks the destination disk first", bundle: .greeceKit, comment: "What an installer does before installing")
            }
            items.append(.field(String(localized: "Checks", bundle: .greeceKit, comment: "Inspector row title: what an installer checks before installing"), text))
        }
        if !distribution.mustClose.isEmpty {
            items.append(InspectorItem(title: String(localized: "Quits First", bundle: .greeceKit, comment: "Inspector row title; its value lists apps an installer asks you to quit"),
                                       value: distribution.mustClose.prefix(10).joined(separator: ", "),
                                       help: String(localized: "Installer asks you to quit these apps before installing.", bundle: .greeceKit), mono: true))
        }
        if distribution.requiresRestart {
            items.append(.field(afterwardsTitle, String(localized: "Restarts your Mac", bundle: .greeceKit, comment: "What happens after a package installs"), tone: .caution))
        }
        guard !items.isEmpty else { return nil }
        return InspectorSection("requirements", title: String(localized: "Requirements", bundle: .greeceKit, comment: "Section title"), rows: items.map { .item($0) })
    }

    private static var afterwardsTitle: String {
        String(localized: "Afterwards", bundle: .greeceKit, comment: "Inspector row title: what happens after a package installs")
    }

    /// A component's postinstall action ("restart", "logout"), as a word.
    private static func actionText(_ action: String) -> String {
        switch action.lowercased() {
        case "restart": return String(localized: "Restart", bundle: .greeceKit, comment: "What happens after a package installs: the Mac restarts")
        case "logout": return String(localized: "Logout", bundle: .greeceKit, comment: "What happens after a package installs: you’re logged out")
        case "shutdown": return String(localized: "Shutdown", bundle: .greeceKit, comment: "What happens after a package installs: the Mac shuts down")
        default: return action.capitalized
        }
    }

    // MARK: Packages and bundles

    static func packagesSection(_ package: InstallerPackage) -> InspectorSection? {
        guard package.components.count > 1 else { return nil }
        let rows: [InspectorRow] = package.components.prefix(64).map { component in
            let files = component.payload.map { filesText($0.filter { $0.kind != .directory }.count) }
                ?? component.declaredFiles.map(filesText)
            let bytes: String? = {
                if let payload = component.payload, !payload.isEmpty {
                    return Format.bytes(payload.reduce(UInt64(0)) { $1.kind == .file ? $0.saturatingAdd($1.size) : $0 })
                }
                return component.installKBytes.map { Format.bytes(UInt64(max(0, $0)) * 1024) }
            }()
            var details: [InspectorItem] = [.field(String(localized: "Location [install]", defaultValue: "Location", bundle: .greeceKit, comment: "Inspector row title: where a package installs"),
                                                   component.installLocation, mono: true),
                                            .field(installsAsTitle, component.installsAsRoot ? administratorText : currentUserText)]
            if !component.scripts.isEmpty {
                details.append(.field(String(localized: "Scripts", bundle: .greeceKit, comment: "Inspector row title; its value lists script names"),
                                      component.scripts.map(\.name).joined(separator: ", ")))
            }
            if let action = component.postinstallAction { details.append(.field(afterwardsTitle, actionText(action))) }
            return .item(InspectorItem(symbol: "shippingbox", title: component.identifier ?? component.name,
                                       subtitle: Format.joined([files, bytes]), value: component.version, help: component.name, details: details))
        }
        return InspectorSection("packages", title: packagesTitle, rows: rows, visibleLimit: rows.count > 10 ? 8 : nil)
    }

    private static var packagesTitle: String {
        String(localized: "Packages", bundle: .greeceKit, comment: "Section or row title: the component packages inside a product archive")
    }

    static func bundlesSection(_ package: InstallerPackage) -> InspectorSection? {
        var rows: [InspectorRow] = []
        var seen = Set<String>()
        for component in package.components {
            for bundle in component.bundles where seen.insert(bundle.identifier + "|" + bundle.path).inserted {
                let full = "/" + component.installedPath(bundle.path)
                rows.append(.item(InspectorItem(symbol: symbol(forPath: bundle.path, isDirectory: true),
                                                title: (bundle.path as NSString).lastPathComponent, subtitle: bundle.identifier,
                                                value: bundle.version, help: full)))
            }
        }
        guard !rows.isEmpty else { return nil }
        return InspectorSection("bundles", title: String(localized: "Bundles", bundle: .greeceKit, comment: "Section title: the apps and plug-ins a package installs"),
                                rows: rows, visibleLimit: rows.count > 10 ? 8 : nil)
    }

    // MARK: Info

    static func infoSection(_ package: InstallerPackage) -> InspectorSection {
        var items: [InspectorItem] = []
        let kindTitle = String(localized: "Kind", bundle: .greeceKit, comment: "Inspector row title: the kind of file")
        switch package.kind {
        case .product:
            items.append(.field(kindTitle, String(localized: "Product archive", bundle: .greeceKit, comment: "A kind of installer package"),
                                help: String(localized: "A distribution package with its own installer screens, choices and checks.", bundle: .greeceKit)))
        case .component:
            items.append(.field(kindTitle, String(localized: "Component package", bundle: .greeceKit, comment: "A kind of installer package"),
                                help: String(localized: "A single package built with pkgbuild.", bundle: .greeceKit)))
        case .bundle:
            items.append(.field(kindTitle, String(localized: "Bundle package (legacy)", bundle: .greeceKit, comment: "A kind of installer package"),
                                help: String(localized: "An old-style package folder from before macOS 10.5.", bundle: .greeceKit)))
        }
        if package.components.count == 1, let identifier = package.components[0].identifier, identifier != package.distribution?.productID {
            items.append(.field(String(localized: "Package ID", bundle: .greeceKit, comment: "Inspector row title: a package’s identifier"), identifier, mono: true))
        }
        if package.components.count > 1 { items.append(.field(packagesTitle, package.components.count.formatted())) }
        if let created = package.created { items.append(.field(String(localized: "Created", bundle: .greeceKit, comment: "Inspector row title; its value is a date"), Format.dateTime(created))) }
        if package.fileSize > 0 { items.append(.field(String(localized: "Size", bundle: .greeceKit, comment: "Inspector row title"), Format.bytes(package.fileSize))) }
        if let checksum = package.tocChecksum, let style = package.tocChecksumStyle {
            items.append(.field(String(localized: "TOC Checksum", bundle: .greeceKit, comment: "Inspector row title: the checksum of a package’s table of contents"),
                                style.uppercased().replacingOccurrences(of: "SHA", with: "SHA-") + " " + checksum.hexString,
                                mono: true, help: String(localized: "Hash of the package’s table of contents; notarization tickets refer to it.", bundle: .greeceKit)))
        }
        if let generator = package.components.compactMap(\.generator).first {
            items.append(.field(String(localized: "Built With", bundle: .greeceKit, comment: "Inspector row title; its value is the tool that made the file"), generator,
                                help: String(localized: "The packaging tool’s version and the macOS build it ran on.", bundle: .greeceKit)))
        }
        if let resources = package.distribution?.resources {
            let names = [("welcome", String(localized: "Welcome", bundle: .greeceKit, comment: "A screen in macOS Installer")),
                         ("readme", String(localized: "Read Me", bundle: .greeceKit, comment: "A screen in macOS Installer")),
                         ("license", String(localized: "License", bundle: .greeceKit, comment: "A screen in macOS Installer")),
                         ("conclusion", String(localized: "Conclusion", bundle: .greeceKit, comment: "A screen in macOS Installer"))]
                .filter { resources[$0.0] != nil }.map(\.1)
            if !names.isEmpty {
                items.append(.field(String(localized: "Installer Screens", bundle: .greeceKit, comment: "Inspector row title; its value lists screens such as “Welcome, Read Me”"),
                                    names.joined(separator: ", ")))
            }
        }
        return InspectorSection("info", title: String(localized: "Info", bundle: .greeceKit, comment: "Section title"), rows: items.map { .item($0) })
    }

    // MARK: Contents and summary

    static func contents(for package: InstallerPackage, showHidden: Bool) -> InspectorContents? {
        var entries: [ArchiveEntry] = []
        for component in package.components {
            for entry in component.payload ?? [] {
                entries.append(ArchiveEntry(path: component.installedPath(entry.path), isDirectory: entry.kind == .directory,
                                            isSymlink: entry.kind == .symlink, size: entry.kind == .file ? entry.size : 0,
                                            compressedSize: nil, modified: entry.modified))
            }
        }
        guard !entries.isEmpty else { return nil }
        let listing = ArchiveListing(format: .tar, container: .tar, entries: entries, archiveSize: package.fileSize,
                                     truncated: package.components.contains { $0.payloadTruncated })
        return .tree(FileNode.tree(from: listing, showHidden: showHidden),
                     title: String(localized: "Payload", bundle: .greeceKit, comment: "Tab title: the files an installer package installs"), count: listing.fileCount)
    }

    static func summary(for package: InstallerPackage, now: Date) -> FileSummary {
        var details: [String] = []
        let files = package.installedFiles
        if files > 0 { details.append(filesText(files)) }
        let bytes = package.installedBytes
        if bytes > 0 {
            let size = Format.bytes(bytes)
            details.append(String(localized: "\(size) installed", bundle: .greeceKit, comment: "Info bar detail. The argument is a size, such as “182 MB”"))
        }
        if package.components.count > 1 {
            details.append(String(localized: "\(package.components.count) packages", bundle: .greeceKit, comment: "Info bar detail: component packages inside an installer. The argument is a count"))
        }
        let modified = (try? package.url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return FileSummary(symbol: "shippingbox", title: String(localized: "Installer Package", bundle: .greeceKit, comment: "Info bar title for a .pkg file"), details: details,
                           trailing: modified.map(PreviewFactory.modifiedText))
    }
}
