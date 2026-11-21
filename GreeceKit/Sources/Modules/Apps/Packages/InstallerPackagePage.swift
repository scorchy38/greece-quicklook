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
            page.sections.append(InspectorSection("license", title: "License Agreement", rows: [
                .code(InspectorCode(symbol: "doc.text", title: "License Agreement", subtitle: "Shown before installing",
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
                badges.append(InspectorBadge("signer", symbol: "exclamationmark.triangle", title: "Untrusted Certificate", tone: .caution,
                                             help: "Signed with a certificate that doesn’t lead to Apple. Installer treats it like an unsigned package."))
            }
            if signature.verdict == .invalid || signature.checksumMatches == false {
                badges.append(InspectorBadge("integrity", symbol: "exclamationmark.octagon", title: "Signature Invalid", tone: .critical,
                                             help: "The package changed after it was signed, or its signature is damaged."))
            }
        } else {
            badges.append(InspectorBadge("signer", symbol: "xmark.seal", title: "Unsigned", tone: .critical,
                                         help: "Not signed. Installer will say it comes from an unidentified developer."))
        }
        if let ticket = package.ticket {
            if package.ticketMatches {
                badges.append(InspectorBadge("notarization", symbol: "checkmark.shield", title: "Notarized", tone: .positive,
                                             help: "Apple’s notarization ticket for this package is stapled to it" + (ticket.notarizedAt.map { " (\(Format.date($0)))." } ?? ".")))
            } else {
                badges.append(InspectorBadge("notarization", symbol: "exclamationmark.shield", title: "Ticket Mismatch", tone: .caution,
                                             help: "A notarization ticket is stapled, but it doesn’t list this package."))
            }
        }
        if let badge = architectureBadge(package.distribution?.hostArchitectures ?? []) { badges.append(badge) }
        let scripts = package.allScripts
        if !scripts.isEmpty {
            let root = package.components.contains { $0.installsAsRoot && !$0.scripts.isEmpty } || !package.productScripts.isEmpty
            badges.append(InspectorBadge("scripts", symbol: "terminal", title: "Runs Scripts", tone: .caution,
                                         help: root ? "Installer runs this package’s scripts with administrator privileges."
                                                    : "Installer runs this package’s scripts during installation."))
        }
        let actions = package.components.compactMap { $0.postinstallAction?.lowercased() }
        if package.distribution?.requiresRestart == true || actions.contains(where: { $0.contains("restart") || $0.contains("shutdown") }) {
            badges.append(InspectorBadge("restart", symbol: "arrow.clockwise", title: "Requires Restart", tone: .caution,
                                         help: "Your Mac restarts after installing."))
        } else if actions.contains(where: { $0.contains("logout") }) {
            badges.append(InspectorBadge("restart", symbol: "rectangle.portrait.and.arrow.right", title: "Requires Logout", tone: .caution,
                                         help: "You’re logged out after installing."))
        }
        return badges
    }

    static func architectureBadge(_ architectures: [String]) -> InspectorBadge? {
        let lower = Set(architectures.map { $0.lowercased() })
        let arm = lower.contains("arm64") || lower.contains("arm64e")
        let intel = lower.contains("x86_64") || lower.contains("i386")
        switch (arm, intel) {
        case (true, true):
            return InspectorBadge("architecture", symbol: "cpu", title: "Universal", tone: .neutral,
                                  help: "Installer runs natively on Apple silicon and Intel.")
        case (true, false):
            return InspectorBadge("architecture", symbol: "cpu", title: "Apple silicon", tone: .neutral,
                                  help: "Installer opens it only on a Mac with Apple silicon.")
        case (false, true):
            return InspectorBadge("architecture", symbol: "exclamationmark.triangle", title: "Intel only", tone: .caution,
                                  help: "On a Mac with Apple silicon, Installer needs Rosetta to open it.")
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
        case (true, true): return "Apple silicon and Intel"
        case (true, false): return "Apple silicon"
        case (false, true): return "Intel (Rosetta on Apple silicon)"
        default: return architectures.joined(separator: ", ")
        }
    }

    // MARK: Signature

    static func signatureSection(_ package: InstallerPackage, now: Date) -> InspectorSection {
        var rows: [InspectorRow] = []
        if let signature = package.signature, let leaf = signature.certificates.first {
            let kind = signerKind(signature)
            let signer = leaf.organization ?? leaf.commonName.replacingOccurrences(of: #"^[^:]+:\s*"#, with: "", options: .regularExpression)
            rows.append(.item(InspectorItem(symbol: "signature", title: "Signed By", value: signer, help: leaf.commonName)))
            if let team = leaf.organizationalUnit, team.count == 10, team.allSatisfy({ $0.isUppercase || $0.isNumber }) {
                rows.append(.item(.field("Team ID", team, mono: true)))
            }
            rows.append(.item(.field("Certificate", certificateKindText(kind, leaf: leaf, chainsToApple: signature.chainsToApple),
                                     tone: signature.chainsToApple ? .neutral : .caution,
                                     help: signature.chainsToApple ? leaf.commonName : "The certificate chain doesn’t lead to one of Apple’s roots.")))

            switch (signature.verdict, signature.checksumMatches) {
            case (_, false?):
                rows.append(.item(.field("Signature", "Contents changed after signing", tone: .critical,
                                         help: "The table of contents no longer matches its checksum.")))
            case (.valid, _):
                rows.append(.item(.field("Signature", "Valid", tone: .positive,
                                         help: "The signature over the package’s table of contents matches the signing certificate.")))
            case (.invalid, _):
                rows.append(.item(.field("Signature", "Doesn’t match the certificate", tone: .critical,
                                         help: "The RSA signature doesn’t verify with the signing certificate’s key.")))
            case (.unknown, _):
                rows.append(.item(.field("Signature", signature.hasCMS ? "Present (CMS)" : "Not checked")))
            }
            if let date = signature.signedAt {
                rows.append(.item(.field("Signed", Format.dateTime(date),
                                         help: signature.trustedTimestamp ? "From Apple’s trusted timestamp service." : "The signing time the signer recorded.")))
            }
            rows.append(.item(notarizationItem(package)))
            var chain = CertificateRows.chain(signature.certificates, now: now)
            // A trusted timestamp keeps a signature valid after its certificate expires.
            if signature.trustedTimestamp {
                for index in chain.indices where chain[index].tone == .critical { chain[index].tone = .neutral }
            }
            rows += chain.map { .item($0) }
            return InspectorSection("signature", title: "Signature", rows: rows)
        }
        rows.append(.note(InspectorNote(symbol: "exclamationmark.triangle",
                                        text: "This package isn’t signed, so there’s no way to tell who made it or whether it changed since. Installer will warn that it’s from an unidentified developer.",
                                        tone: .caution)))
        rows.append(.item(notarizationItem(package)))
        return InspectorSection("signature", title: "Signature", rows: rows)
    }

    static func certificateKindText(_ kind: SignerKind, leaf: CertificateSummary, chainsToApple: Bool) -> String {
        if !chainsToApple { return leaf.isSelfSigned ? "Self-signed" : "Not issued by Apple" }
        if let prefix = leaf.commonName.split(separator: ":").first, leaf.commonName.contains(":") { return String(prefix) }
        switch kind {
        case .apple: return "Apple Software"
        case .other(let name): return name
        default: return kind.title
        }
    }

    static func notarizationItem(_ package: InstallerPackage) -> InspectorItem {
        guard let ticket = package.ticket else {
            return .field("Notarization", "No stapled ticket",
                          help: "Gatekeeper can still find a ticket online when the package opens. Greece only reads what’s in the file.")
        }
        let date = ticket.notarizedAt.map { " · " + Format.date($0) } ?? ""
        if package.ticketMatches {
            return .field("Notarization", "Ticket stapled" + date, tone: .positive,
                          help: "Apple’s notarization ticket is stapled and lists this package’s checksum.")
        }
        return .field("Notarization", "Ticket doesn’t list this package", tone: .caution,
                      help: "A ticket is stapled, but none of its entries matches this package’s checksum.")
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

    /// Where things go (a list that can be long), then how Installer goes about it.
    static func installsSections(_ package: InstallerPackage) -> [InspectorSection] {
        let destinations = destinations(package)
        var rows: [InspectorRow] = destinations.prefix(200).map { destination in
            let subtitle = destination.isDirectory
                ? Format.joined([Format.count(destination.files, "file"), destination.bytes > 0 ? Format.bytes(destination.bytes) : nil])
                : (destination.bytes > 0 ? Format.bytes(destination.bytes) : "Empty file")
            return .item(InspectorItem(symbol: symbol(forPath: destination.path, isDirectory: destination.isDirectory),
                                       title: destination.path, subtitle: subtitle, help: destination.path))
        }
        // Components without a readable payload still say where they go.
        for component in package.components where (component.payload ?? []).isEmpty {
            let size = component.installKBytes.map { Format.bytes(UInt64(max(0, $0)) * 1024) }
            let files = component.declaredFiles.map { Format.count($0, "file") }
            rows.append(.item(InspectorItem(symbol: "folder", title: component.installLocation,
                                            subtitle: Format.joined([files, size]).nilIfEmpty ?? "Contents unknown",
                                            help: component.identifier)))
        }
        guard !rows.isEmpty || !package.components.isEmpty else { return [] }

        var facts: [InspectorItem] = []
        let root = package.components.contains { $0.installsAsRoot }
        if !package.components.isEmpty {
            facts.append(.field("Installs As", root ? "Administrator" : "Current user",
                                help: root ? "Installer asks for an administrator password and writes files as root." : "Installs without administrator privileges."))
        }
        if let domains = package.distribution?.domains, !domains.isEmpty {
            var options: [String] = []
            if domains.contains("localSystem") { options.append("all users") }
            if domains.contains("currentUserHome") { options.append("just you") }
            if domains.contains("anywhere") { options.append("any disk") }
            let text = options.joined(separator: " or ")
            facts.append(.field("Install For", text.prefix(1).uppercased() + text.dropFirst()))
        }
        let relocatable = package.components.contains { $0.relocatable }
        if relocatable {
            facts.append(.field("Updates", "Existing copies where they are",
                                help: "The package is relocatable: if you moved a previous version, Installer updates it there."))
        }
        let files = package.installedFiles
        if files > 0 { facts.append(.field("Files", files.formatted())) }
        let bytes = package.installedBytes
        if bytes > 0 { facts.append(.field("Installed Size", Format.bytes(bytes))) }
        let truncated = package.components.contains { $0.payloadTruncated }
        var sections: [InspectorSection] = []
        if !rows.isEmpty {
            sections.append(InspectorSection("installs", title: "Installs", footer: truncated ? "Showing the first part of a very large payload." : nil,
                                             rows: rows, visibleLimit: rows.count > 10 ? 8 : nil))
        }
        if !facts.isEmpty {
            sections.append(InspectorSection("install-details", title: rows.isEmpty ? "Installs" : nil, rows: facts.map { .item($0) }))
        }
        return sections
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
        let daemon = SystemItem(kind: "Launch Daemon", symbol: "gearshape.2", tint: .gray, note: "Runs as root, at startup", tone: .caution, background: true)
        let agent = SystemItem(kind: "Launch Agent", symbol: "person.crop.circle.badge.clock", tint: .blue, note: "Runs for every user who logs in", tone: .neutral, background: true)
        let helper = SystemItem(kind: "Privileged Helper", symbol: "lock.shield", tint: .orange, note: "Runs as root when the app asks", tone: .caution, background: true)
        let startup = SystemItem(kind: "Startup Item", symbol: "power", tint: .gray, note: "Runs at startup (legacy)", tone: .caution, background: true)
        let kext = SystemItem(kind: "Kernel Extension", symbol: "cpu", tint: .red, note: "Loads into the kernel, after you allow it", tone: .caution, background: false)
        let authorization = SystemItem(kind: "Authorization Plug-in", symbol: "key", tint: .red, note: "Takes part in logging in and unlocking", tone: .caution, background: false)
        let audio = SystemItem(kind: "Audio Driver", symbol: "speaker.wave.2", tint: .pink, note: nil, tone: .neutral, background: false)
        let audioUnit = SystemItem(kind: "Audio Unit", symbol: "waveform", tint: .pink, note: nil, tone: .neutral, background: false)
        let browser = SystemItem(kind: "Browser Plug-in", symbol: "globe", tint: .blue, note: nil, tone: .neutral, background: false)
        let quickLook = SystemItem(kind: "Quick Look Plug-in", symbol: "eye", tint: .gray, note: nil, tone: .neutral, background: false)
        let spotlight = SystemItem(kind: "Spotlight Importer", symbol: "magnifyingglass", tint: .gray, note: nil, tone: .neutral, background: false)
        let pane = SystemItem(kind: "Settings Pane", symbol: "gearshape", tint: .gray, note: nil, tone: .neutral, background: false)
        let saver = SystemItem(kind: "Screen Saver", symbol: "sparkles.tv", tint: .indigo, note: nil, tone: .neutral, background: false)
        let input = SystemItem(kind: "Input Method", symbol: "keyboard", tint: .gray, note: nil, tone: .neutral, background: false)
        let filesystem = SystemItem(kind: "File System", symbol: "externaldrive", tint: .gray, note: nil, tone: .neutral, background: false)
        let paths = SystemItem(kind: "Shell Path", symbol: "terminal", tint: .gray, note: "Adds to every shell’s PATH", tone: .neutral, background: false)
        let mail = SystemItem(kind: "Mail Plug-in", symbol: "envelope", tint: .blue, note: nil, tone: .neutral, background: false)

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
            sections.append(InspectorSection("background", title: "Background Items",
                                             footer: "These run automatically, without you opening an app. You can turn them off in Login Items & Extensions.",
                                             rows: background.map { .item($0) }, visibleLimit: background.count > 10 ? 8 : nil))
        }
        if !extensions.isEmpty {
            sections.append(InspectorSection("extensions", title: "Extensions & Plug-ins", rows: extensions.map { .item($0) },
                                             visibleLimit: extensions.count > 10 ? 8 : nil))
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
                      title: "Adds certificates", detail: "Can make your Mac trust new certificates", tone: .critical),
        ScriptFinding(pattern: #"spctl\s+(--master-disable|--global-disable|--add|--disable)"#, symbol: "shield.slash", tint: .red,
                      title: "Changes Gatekeeper", detail: "Changes which apps macOS allows to open", tone: .critical),
        ScriptFinding(pattern: #"\btccutil\b|TCC\.db"#, symbol: "hand.raised", tint: .orange,
                      title: "Changes privacy permissions", detail: "Resets or edits Privacy & Security permissions", tone: .caution),
        ScriptFinding(pattern: #"\b(curl|wget)\b|NSURLSession|urllib|requests\.get"#, symbol: "arrow.down.circle", tint: .blue,
                      title: "Downloads files", detail: "Fetches files from the internet while installing", tone: .caution),
        ScriptFinding(pattern: #"(^|[\s"'=:(])/Library/LaunchDaemons|launchctl\s+(load\s+(-w\s+)?["']?/Library/LaunchDaemons|bootstrap\s+system)"#,
                      symbol: "gearshape.2", tint: .gray,
                      title: "Sets up a launch daemon", detail: "Something that runs as root in the background", tone: .caution),
        ScriptFinding(pattern: #"(^|[\s"'=:(~}]|HOME)/Library/LaunchAgents|launchctl\s+bootstrap\s+gui"#, symbol: "person.crop.circle.badge.clock", tint: .blue,
                      title: "Sets up a launch agent", detail: "Something that runs in the background when you log in", tone: .neutral),
        ScriptFinding(pattern: #"\b(kextload|kmutil\s+load|kextcache)\b"#, symbol: "cpu", tint: .red,
                      title: "Loads a kernel extension", detail: "Code that runs inside the kernel", tone: .caution),
        ScriptFinding(pattern: #"systemextensionsctl|SystemExtensions"#, symbol: "puzzlepiece.extension", tint: .purple,
                      title: "Manages system extensions", detail: "Drivers or network and security extensions", tone: .neutral),
        ScriptFinding(pattern: #"chmod\s+([ugoa]*\+s|[0-7]?[4-7][0-7]{3})\b"#, symbol: "person.badge.key", tint: .orange,
                      title: "Sets special permissions", detail: "Makes a program run with its owner’s privileges", tone: .caution),
        ScriptFinding(pattern: #"\b(killall|pkill)\b|kill\s+-9"#, symbol: "xmark.app", tint: .gray,
                      title: "Quits running apps", detail: "Stops processes while installing", tone: .neutral),
        ScriptFinding(pattern: #"/etc/(sudoers|hosts|paths)|/private/etc/"#, symbol: "doc.badge.gearshape", tint: .orange,
                      title: "Edits system files", detail: "Changes configuration in /etc", tone: .caution),
        ScriptFinding(pattern: #"\bprofiles\s+(install|-I)\b"#, symbol: "person.badge.shield.checkmark", tint: .orange,
                      title: "Installs a profile", detail: "Adds a configuration profile", tone: .caution),
        ScriptFinding(pattern: #"\bdscl\s+\S+\s+-(create|append|delete|passwd|change|merge)\b|\bsysadminctl\s+-(addUser|deleteUser|resetPasswordFor|secureTokenOn)|\bdseditgroup\s+-o\s+(edit|create|delete)"#,
                      symbol: "person.2", tint: .orange,
                      title: "Changes users or groups", detail: "Creates or edits accounts", tone: .caution),
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
                return InspectorItem(symbol: finding.symbol, tint: finding.tint, title: finding.title, subtitle: finding.detail,
                                     tone: finding.tone, help: "\(script.name), line \(lineNumber): \(line)")
            }
            return nil
        }
    }

    static func scriptFindingsSection(_ package: InstallerPackage) -> InspectorSection? {
        let items = scriptFindings(package.allScripts)
        guard !items.isEmpty else { return nil }
        return InspectorSection("script-findings", title: "What the Scripts Do",
                                footer: "Based on the commands the scripts contain. Greece doesn’t run them.",
                                rows: items.map { .item($0) })
    }

    static func scriptsSection(_ package: InstallerPackage) -> InspectorSection? {
        var rows: [InspectorRow] = []
        let componentScripts = package.components.flatMap { component in component.scripts.map { (component, $0) } }
        let multiple = package.components.filter { !$0.scripts.isEmpty }.count > 1
        if !componentScripts.isEmpty || !package.productScripts.isEmpty {
            let root = package.components.contains { $0.installsAsRoot && !$0.scripts.isEmpty }
            rows.append(.note(InspectorNote(symbol: "exclamationmark.triangle",
                                            text: root ? "Installer runs these scripts as root, with full access to your Mac."
                                                       : "Installer runs these scripts while it installs.",
                                            tone: .caution)))
        }
        func row(_ script: InstallerPackage.Script, owner: String?) -> InspectorRow {
            let support = script.role == .support
            guard let text = script.text else {
                return .item(InspectorItem(symbol: support ? "doc" : "gearshape", title: script.name,
                                           subtitle: Format.joined([support ? "Used by the scripts" : "Compiled program", Format.bytes(script.size), owner]),
                                           tone: support ? .neutral : .caution, help: support ? nil : "Greece can’t show compiled code."))
            }
            let language = support ? fileKindName(script.grammar) : languageName(script.grammar)
            let subtitle = Format.joined([support ? "Used by the scripts" : owner, Format.count(script.lineCount, "line"), language])
            return .code(InspectorCode(symbol: support ? "doc.text" : "terminal", title: script.name, subtitle: subtitle, text: text,
                                       grammar: script.grammar, tone: support ? .neutral : .caution, truncated: script.truncated))
        }
        for (component, script) in componentScripts {
            rows.append(row(script, owner: multiple ? (component.identifier ?? component.name) : nil))
        }
        for script in package.productScripts {
            rows.append(row(script, owner: script.role == .support ? nil : "Run by the installer’s JavaScript"))
        }
        if let javaScript = package.distribution?.javaScript {
            let checks = package.distribution?.installationCheck != nil || package.distribution?.volumeCheck != nil
            rows.append(.code(InspectorCode(symbol: "curlybraces", title: "Installer JavaScript",
                                            subtitle: Format.joined([checks ? "Checks your Mac before installing" : nil,
                                                                     Format.count(javaScript.reduce(into: 1) { if $1 == "\n" { $0 += 1 } }, "line")]),
                                            text: javaScript, grammar: "javascript", tone: .neutral,
                                            truncated: javaScript.count >= InstallerPackage.scriptLimit)))
            if package.distribution?.allowExternalScripts == true {
                rows.append(.note(InspectorNote(symbol: "exclamationmark.triangle",
                                                text: "Its JavaScript is allowed to run commands on your Mac.", tone: .caution)))
            }
        }
        guard !rows.isEmpty else { return nil }
        return InspectorSection("scripts", title: "Installer Scripts", rows: rows)
    }

    static func fileKindName(_ grammar: String) -> String {
        switch grammar {
        case "xml": return "Property list"
        case "json": return "JSON"
        default: return languageName(grammar)
        }
    }

    static func languageName(_ grammar: String) -> String {
        switch grammar {
        case "bash": return "Shell script"
        case "python": return "Python"
        case "perl": return "Perl"
        case "ruby": return "Ruby"
        case "applescript": return "AppleScript"
        case "javascript": return "JavaScript"
        default: return "Text"
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
        let footer = distribution.customize == "never" ? "Installer picks these for you; it doesn’t offer a Customize step."
            : "You can pick what to install in Installer’s Customize step."
        return InspectorSection("choices", title: "Choices", footer: footer, rows: rows, visibleLimit: rows.count > 10 ? 8 : nil)
    }

    static func requirementsSection(_ package: InstallerPackage) -> InspectorSection? {
        guard let distribution = package.distribution else { return nil }
        var items: [InspectorItem] = []
        if let minimum = distribution.minimumOS {
            var text = "macOS \(minimum) or later"
            if let maximum = distribution.maximumOS { text = "macOS \(minimum) to before \(maximum)" }
            items.append(.field("macOS", text))
        } else if let maximum = distribution.maximumOS {
            items.append(.field("macOS", "Before \(maximum)"))
        }
        if let text = hostArchitectureText(distribution.hostArchitectures) {
            items.append(.field("Installer Runs On", text, tone: distribution.hostArchitectures.contains { $0.hasPrefix("arm64") } ? .neutral : .caution,
                                help: "The architectures the package’s hostArchitectures option allows."))
        }
        if distribution.rootVolumeOnly { items.append(.field("Destination", "Startup disk only")) }
        if distribution.installationCheck != nil || distribution.volumeCheck != nil {
            let checks = [distribution.installationCheck != nil ? "your Mac" : nil, distribution.volumeCheck != nil ? "the destination disk" : nil].compactMap { $0 }
            items.append(.field("Checks", "Checks " + checks.joined(separator: " and ") + " first"))
        }
        if !distribution.mustClose.isEmpty {
            items.append(InspectorItem(title: "Quits First", value: distribution.mustClose.prefix(10).joined(separator: ", "),
                                       help: "Installer asks you to quit these apps before installing.", mono: true))
        }
        if distribution.requiresRestart { items.append(.field("Afterwards", "Restarts your Mac", tone: .caution)) }
        guard !items.isEmpty else { return nil }
        return InspectorSection("requirements", title: "Requirements", rows: items.map { .item($0) })
    }

    // MARK: Packages and bundles

    static func packagesSection(_ package: InstallerPackage) -> InspectorSection? {
        guard package.components.count > 1 else { return nil }
        let rows: [InspectorRow] = package.components.prefix(64).map { component in
            let files = component.payload.map { Format.count($0.filter { $0.kind != .directory }.count, "file") }
                ?? component.declaredFiles.map { Format.count($0, "file") }
            let bytes: String? = {
                if let payload = component.payload, !payload.isEmpty {
                    return Format.bytes(payload.reduce(UInt64(0)) { $1.kind == .file ? $0.saturatingAdd($1.size) : $0 })
                }
                return component.installKBytes.map { Format.bytes(UInt64(max(0, $0)) * 1024) }
            }()
            var details: [InspectorItem] = [.field("Location", component.installLocation, mono: true),
                                            .field("Installs As", component.installsAsRoot ? "Administrator" : "Current user")]
            if !component.scripts.isEmpty { details.append(.field("Scripts", component.scripts.map(\.name).joined(separator: ", "))) }
            if let action = component.postinstallAction { details.append(.field("Afterwards", action.capitalized)) }
            return .item(InspectorItem(symbol: "shippingbox", title: component.identifier ?? component.name,
                                       subtitle: Format.joined([files, bytes]), value: component.version, help: component.name, details: details))
        }
        return InspectorSection("packages", title: "Packages", rows: rows, visibleLimit: rows.count > 10 ? 8 : nil)
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
        return InspectorSection("bundles", title: "Bundles", rows: rows, visibleLimit: rows.count > 10 ? 8 : nil)
    }

    // MARK: Info

    static func infoSection(_ package: InstallerPackage) -> InspectorSection {
        var items: [InspectorItem] = []
        switch package.kind {
        case .product: items.append(.field("Kind", "Product archive", help: "A distribution package with its own installer screens, choices and checks."))
        case .component: items.append(.field("Kind", "Component package", help: "A single package built with pkgbuild."))
        case .bundle: items.append(.field("Kind", "Bundle package (legacy)", help: "An old-style package folder from before macOS 10.5."))
        }
        if package.components.count == 1, let identifier = package.components[0].identifier, identifier != package.distribution?.productID {
            items.append(.field("Package ID", identifier, mono: true))
        }
        if package.components.count > 1 { items.append(.field("Packages", package.components.count.formatted())) }
        if let created = package.created { items.append(.field("Created", Format.dateTime(created))) }
        if package.fileSize > 0 { items.append(.field("Size", Format.bytes(package.fileSize))) }
        if let checksum = package.tocChecksum, let style = package.tocChecksumStyle {
            items.append(.field("TOC Checksum", style.uppercased().replacingOccurrences(of: "SHA", with: "SHA-") + " " + checksum.hexString,
                                mono: true, help: "Hash of the package’s table of contents; notarization tickets refer to it."))
        }
        if let generator = package.components.compactMap(\.generator).first {
            items.append(.field("Built With", generator, help: "The packaging tool’s version and the macOS build it ran on."))
        }
        if let resources = package.distribution?.resources {
            let names = [("welcome", "Welcome"), ("readme", "Read Me"), ("license", "License"), ("conclusion", "Conclusion")]
                .filter { resources[$0.0] != nil }.map(\.1)
            if !names.isEmpty { items.append(.field("Installer Screens", names.joined(separator: ", "))) }
        }
        return InspectorSection("info", title: "Info", rows: items.map { .item($0) })
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
        return .tree(FileNode.tree(from: listing, showHidden: showHidden), title: "Payload", count: listing.fileCount)
    }

    static func summary(for package: InstallerPackage, now: Date) -> FileSummary {
        var details: [String] = []
        let files = package.installedFiles
        if files > 0 { details.append(Format.count(files, "file")) }
        let bytes = package.installedBytes
        if bytes > 0 { details.append(Format.bytes(bytes) + " installed") }
        if package.components.count > 1 { details.append(Format.count(package.components.count, "package")) }
        let modified = (try? package.url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return FileSummary(symbol: "shippingbox", title: "Installer Package", details: details,
                           trailing: modified.map(PreviewFactory.modifiedText))
    }
}
