import AppKit
import UniformTypeIdentifiers

/// Turns `BundleFacts` into an inspector page: who signed it, what it may do, what it carries.
enum BundlePage {

    static func page(for facts: BundleFacts, icon: InspectorIcon, subject: SigningSection.Subject, modified: String?) -> InspectorPage {
        let version = Format.version(facts.shortVersion, build: facts.buildVersion)
        var page = InspectorPage(header: InspectorHeader(icon: icon, title: facts.name, subtitle: version, identifier: facts.identifier),
                                 summary: FileSummary(symbol: facts.symbol, title: facts.kindTitle, details: [], trailing: modified))

        // Architecture first: it decides whether it runs at all.
        if let slices = facts.macho?.slices, !slices.isEmpty, !facts.isIOS || facts.isWrappedIOSApp {
            page.badges.append(ArchitectureSupport(slices).badge)
        }
        if facts.isWrappedIOSApp {
            page.badges.append(InspectorBadge("platform", symbol: "ipad.and.iphone", title: String(localized: "iPhone and iPad App", bundle: .greeceKit), tone: .accent,
                                              help: String(localized: "An iOS app that runs on Macs with Apple silicon.", bundle: .greeceKit)))
        }

        let ticket = facts.source.url.flatMap { NotarizationTicket.stapled(inBundle: $0) }
        // iOS apps don't use the hardened runtime: an "Off" there would only mislead.
        let signing = SigningSection.build(signature: facts.macho == nil ? nil : facts.signature, url: facts.source.url, subject: subject,
                                           ticket: ticket, fileCount: facts.filesComplete ? facts.files.count : nil,
                                           totalSize: facts.filesComplete ? facts.totalSize : nil, showsRuntime: !facts.isIOS)
        if facts.macho != nil || facts.executablePath != nil {
            page.badges += signing.badges
            page.sections.append(signing.section)
            page.checks += signing.checks
        }
        if facts.isSandboxed && !facts.isIOS {
            page.badges.append(InspectorBadge("sandbox", symbol: "shield.lefthalf.filled", title: String(localized: "Sandboxed", bundle: .greeceKit, comment: "Badge on an app’s inspector page"), tone: .positive,
                                              help: String(localized: "Runs in the App Sandbox: it can reach only what its entitlements allow.", bundle: .greeceKit)))
        }
        if facts.entitlements["com.apple.security.hardened-process"] as? Bool == true {
            page.badges.append(InspectorBadge("enhanced", symbol: "lock.shield.fill", title: String(localized: "Enhanced Security", bundle: .greeceKit, comment: "Badge: the macOS security feature an app opts into"), tone: .positive,
                                              help: String(localized: "Opts into macOS’s Enhanced Security protections, such as a hardened memory allocator.", bundle: .greeceKit)))
        }
        if let slice = facts.macho?.preferredSlice, slice.isEncrypted {
            page.badges.append(InspectorBadge("encrypted", symbol: "lock.fill", title: String(localized: "Encrypted", bundle: .greeceKit, comment: "Badge: an app’s executable is encrypted"), tone: .neutral,
                                              help: String(localized: "The App Store encrypted the executable (FairPlay). Some details can’t be read.", bundle: .greeceKit)))
        }

        if let section = capabilities(facts) { page.sections.append(section) }
        if let section = privacy(facts) { page.sections.append(section) }
        if let section = privacyManifest(facts) { page.sections.append(section) }
        page.sections += components(facts)
        if let section = documentTypes(facts) { page.sections.append(section) }
        if let section = urlSchemes(facts) { page.sections.append(section) }
        if let section = frameworks(facts) { page.sections.append(section) }
        if let section = libraries(facts) { page.sections.append(section) }
        if let profile = facts.profile { page.sections.append(ProfilePage.embeddedSection(profile)) }
        if facts.filesComplete {
            if let section = size(facts) { page.sections.append(section) }
        } else {
            // Too many files to measure before first paint: measure in the background.
            page.sections.append(InspectorSection("size", title: sizeTitle, rows: [.pending(id: "size", title: String(localized: "Measuring…", bundle: .greeceKit, comment: "Inspector row while an app’s size is measured"))]))
            page.checks.append(InspectorCheck(id: "size") {
                let measured = facts.measured()
                var rows = size(measured)?.rows ?? []
                if !measured.filesComplete {
                    rows.append(.note(InspectorNote(text: countedNote(measured.files.count), tone: .neutral)))
                }
                return InspectorCheckResult(rows: rows)
            })
        }
        page.sections.append(info(facts))

        var details: [String] = []
        if let version = facts.shortVersion { details.append(version) }
        if let slices = facts.macho?.slices, !slices.isEmpty { details.append(facts.macho!.architectures.joined(separator: ", ")) }
        if facts.totalSize > 0, facts.filesComplete { details.append(Format.bytes(facts.totalSize)) }
        page.summary.details = details

        if let url = facts.source.url {
            let node = FileNode.folder(at: url, showHidden: false)
            page.contents = .tree(node, title: contentsTitle, count: nil, members: node.url != nil ? LocalMembers() : nil)
        }
        return page
    }

    /// The tab listing a bundle's or archive's files.
    static var contentsTitle: String { String(localized: "Contents", bundle: .greeceKit, comment: "Tab title: the files inside an app or bundle") }

    static var sizeTitle: String { String(localized: "Size", bundle: .greeceKit, comment: "Section title: how much space an app takes, by kind of content") }

    /// "Counted the first 150,000 files.", when a bundle had too many files to measure.
    static func countedNote(_ count: Int) -> String {
        String(localized: "Counted the first \(count) files.", bundle: .greeceKit, comment: "Note under an app’s size breakdown. The argument is how many files were counted")
    }

    // MARK: - Capabilities

    static func capabilities(_ facts: BundleFacts) -> InspectorSection? {
        let entitlements = facts.entitlements
        guard !entitlements.isEmpty else { return nil }
        var rows: [InspectorItem] = []
        var unknown: [InspectorItem] = []
        var privateKeys: [String] = []
        for key in entitlements.keys.sorted() where !EntitlementCatalog.hidden.contains(key) {
            let value = entitlements[key]!
            if let flag = value as? Bool, flag == false { continue }
            if EntitlementCatalog.isPrivate(key) { privateKeys.append(key); continue }
            let detail = describe(value)
            if let entry = EntitlementCatalog.describe(key, value: value) {
                // Sandbox gets its own badge; listing it again adds nothing.
                if key == "com.apple.security.app-sandbox" { continue }
                rows.append(InspectorItem(symbol: entry.symbol, tint: entry.tint, title: entry.title, subtitle: detail ?? entry.detail,
                                          tone: entry.tone, help: key))
            } else {
                unknown.append(InspectorItem(symbol: "key", tint: .gray, title: key, subtitle: detail, help: key))
            }
        }
        rows.sort { rank($0.tone) > rank($1.tone) }
        if let group = privateGroup(privateKeys) { unknown.append(group) }
        let all = (rows + unknown).map(InspectorRow.item)
        guard !all.isEmpty else { return nil }
        let footer = facts.isSandboxed ? String(localized: "What the App Sandbox lets it reach. Hover over an item for its entitlement.", bundle: .greeceKit) :
            entitlementsFooter
        return InspectorSection("capabilities", title: capabilitiesTitle, footer: footer, rows: all, visibleLimit: 14)
    }

    static var capabilitiesTitle: String {
        String(localized: "Capabilities", bundle: .greeceKit, comment: "Section title: what an app’s entitlements let it do")
    }

    static var entitlementsFooter: String {
        String(localized: "Entitlements granted by its signature. Hover over an item for its key.", bundle: .greeceKit)
    }

    /// Apple's private entitlements matter only to Apple's own software: one row, expanding to the keys.
    static func privateGroup(_ keys: [String]) -> InspectorItem? {
        guard !keys.isEmpty else { return nil }
        return InspectorItem(symbol: "lock.shield", tint: .gray, title: String(localized: "Private Apple entitlements", bundle: .greeceKit),
                             subtitle: String(localized: "Only Apple’s own software can be granted these.", bundle: .greeceKit), value: keys.count.formatted(),
                             details: keys.map { InspectorItem(title: $0, mono: true) })
    }

    static func rank(_ tone: InspectorTone) -> Int {
        switch tone {
        case .critical: return 3
        case .caution: return 2
        default: return 0
        }
    }

    /// A short description of an entitlement's value: lists, strings, nested settings.
    static func describe(_ value: Any) -> String? {
        if let list = value as? [Any] {
            let strings = list.compactMap { $0 as? String }.map { Format.clean($0, limit: 120) }
            guard !strings.isEmpty else {
                return list.isEmpty ? nil : String(localized: "\(list.count) items", bundle: .greeceKit, comment: "Inspector row subtitle: how many values an entitlement lists")
            }
            let shown = strings.prefix(6).joined(separator: ", ")
            return strings.count > 6 ? andMore(shown, strings.count - 6) : shown
        }
        if let string = value as? String { return Format.clean(string, limit: 160) }
        if let dictionary = value as? [String: Any] {
            let keys = dictionary.keys.sorted().map { Format.clean($0, limit: 80) }
            guard !keys.isEmpty else { return nil }
            let shown = keys.prefix(4).joined(separator: ", ")
            return keys.count > 4 ? andMore(shown, keys.count - 4) : shown
        }
        if let number = value as? NSNumber, !(value is Bool) { return number.stringValue }
        return nil
    }

    /// "a, b, c and 4 more".
    static func andMore(_ shown: String, _ rest: Int) -> String {
        String(localized: "\(shown) and \(rest) more", bundle: .greeceKit, comment: "The first argument is a list of names or file extensions, the second how many more there are")
    }

    // MARK: - Privacy

    static func privacy(_ facts: BundleFacts) -> InspectorSection? {
        var rows: [InspectorItem] = []
        for key in facts.info.keys.sorted() {
            guard key.hasSuffix("UsageDescription") || key == "NSLocationTemporaryUsageDescriptionDictionary",
                  let entry = PrivacyCatalog.describe(key) else { continue }
            var message: String?
            if let text = facts.info[key] as? String { message = "“" + Format.clean(text, limit: 400) + "”" }
            if let dictionary = facts.info[key] as? [String: Any], let first = dictionary.values.compactMap({ $0 as? String }).first {
                message = "“" + Format.clean(first, limit: 400) + "”"
            }
            rows.append(InspectorItem(symbol: entry.symbol, tint: entry.tint, title: entry.title, subtitle: message, tone: entry.tone, help: key))
        }
        // Tracking transparency and Bluetooth peripherals often duplicate; keep the first of each title.
        var seen = Set<String>()
        rows = rows.filter { seen.insert($0.title).inserted }
        guard !rows.isEmpty else { return nil }
        return InspectorSection("privacy", title: String(localized: "Privacy", bundle: .greeceKit, comment: "Section title: what an app may ask permission to use"),
                                footer: String(localized: "What it may ask to use, in the developer’s words. You’re asked before it can.", bundle: .greeceKit),
                                rows: rows.map(InspectorRow.item), visibleLimit: 12)
    }

    static func privacyManifest(_ facts: BundleFacts) -> InspectorSection? {
        guard let manifest = facts.privacyManifest else { return nil }
        var rows: [InspectorRow] = []
        let tracking = manifest["NSPrivacyTracking"] as? Bool ?? false
        rows.append(.item(InspectorItem(symbol: tracking ? "eye.fill" : "eye.slash", tint: tracking ? .orange : .green,
                                        title: tracking ? String(localized: "Tracks you", bundle: .greeceKit) : String(localized: "Doesn’t track you", bundle: .greeceKit),
                                        tone: tracking ? .caution : .neutral, help: "NSPrivacyTracking")))
        if let domains = manifest["NSPrivacyTrackingDomains"] as? [String], !domains.isEmpty {
            rows.append(.item(InspectorItem(symbol: "network", tint: .orange, title: String(localized: "Tracking domains", bundle: .greeceKit),
                                            subtitle: domains.prefix(8).map { Format.clean($0, limit: 80) }.joined(separator: ", "), help: "NSPrivacyTrackingDomains")))
        }
        for entry in ((manifest["NSPrivacyCollectedDataTypes"] as? [[String: Any]]) ?? []).prefix(40) {
            guard let type = entry["NSPrivacyCollectedDataType"] as? String else { continue }
            let linked = entry["NSPrivacyCollectedDataTypeLinked"] as? Bool ?? false
            let tracks = entry["NSPrivacyCollectedDataTypeTracking"] as? Bool ?? false
            let purposes = ((entry["NSPrivacyCollectedDataTypePurposes"] as? [String]) ?? []).map { humanize($0, prefix: "NSPrivacyCollectedDataTypePurpose") }
            var notes: [String] = []
            if linked { notes.append(String(localized: "Linked to you", bundle: .greeceKit, comment: "Privacy manifest: data an app collects is linked to your identity")) }
            if tracks { notes.append(String(localized: "Used to track you", bundle: .greeceKit, comment: "Privacy manifest: data an app collects is used to track you")) }
            if !purposes.isEmpty { notes.append(purposes.joined(separator: ", ")) }
            rows.append(.item(InspectorItem(symbol: "tray.full.fill", tint: tracks ? .orange : .blue, title: humanize(type, prefix: "NSPrivacyCollectedDataType"),
                                            subtitle: notes.joined(separator: " · ").nilIfEmpty, tone: tracks ? .caution : .neutral, help: type)))
        }
        for entry in ((manifest["NSPrivacyAccessedAPITypes"] as? [[String: Any]]) ?? []).prefix(20) {
            guard let type = entry["NSPrivacyAccessedAPIType"] as? String else { continue }
            let reasons = ((entry["NSPrivacyAccessedAPITypeReasons"] as? [String]) ?? []).joined(separator: ", ")
            // The category comes from a raw key ("NSPrivacyAccessedAPICategoryFileTimestamp" → "file timestamp").
            let category = humanize(type, prefix: "NSPrivacyAccessedAPICategory").lowercased()
            rows.append(.item(InspectorItem(symbol: "chevron.left.forwardslash.chevron.right", tint: .gray,
                                            title: String(localized: "Uses \(category) APIs", bundle: .greeceKit,
                                                          comment: "Privacy manifest row. The argument is an API category derived from Apple’s key, such as “file timestamp” or “user defaults”"),
                                            subtitle: reasons.isEmpty ? nil : String(localized: "Reasons: \(reasons)", bundle: .greeceKit,
                                                                                     comment: "Privacy manifest row. The argument is a list of Apple’s reason codes, such as “C617.1, 3B52.1”"),
                                            help: type)))
        }
        return InspectorSection("privacyManifest", title: String(localized: "Privacy Manifest", bundle: .greeceKit),
                                footer: String(localized: "What the developer declared in PrivacyInfo.xcprivacy.", bundle: .greeceKit),
                                rows: rows, visibleLimit: 10)
    }

    /// "NSPrivacyCollectedDataTypeEmailAddress" → "Email address".
    static func humanize(_ value: String, prefix: String) -> String {
        var name = value.hasPrefix(prefix) ? String(value.dropFirst(prefix.count)) : value
        name = name.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
        name = name.replacingOccurrences(of: "([A-Z])([A-Z][a-z])", with: "$1 $2", options: .regularExpression)
        guard let first = name.first else { return value }
        let rest = name.dropFirst().split(separator: " ").map { word -> String in
            word.count > 1 && word.allSatisfy(\.isUppercase) ? String(word) : word.lowercased()
        }.joined(separator: " ")
        return String(first).uppercased() + (name.dropFirst().first == " " ? " " : "") + rest
    }

    // MARK: - Components

    static func components(_ facts: BundleFacts) -> [InspectorSection] {
        let mainTeam = facts.signature?.teamID
        func item(_ nested: BundleFacts.Nested) -> InspectorItem {
            var title = nested.name
            var entry: CatalogEntry
            switch nested.role {
            case .appExtension, .systemExtension:
                entry = nested.extensionPoint.map(ExtensionPointCatalog.describe) ?? CatalogEntry(title: nested.role.title, symbol: "puzzlepiece.extension.fill", tint: .gray)
            case .loginItem: entry = CatalogEntry(title: String(localized: "Opens at login", bundle: .greeceKit), symbol: "power", tint: .orange, tone: .neutral)
            case .privilegedHelper: entry = CatalogEntry(title: String(localized: "Runs as root", bundle: .greeceKit), symbol: "lock.open.fill", tint: .red, tone: .caution)
            case .launchDaemon: entry = CatalogEntry(title: String(localized: "Runs as root in the background", bundle: .greeceKit), symbol: "gearshape.2.fill", tint: .red, tone: .caution)
            case .launchAgent: entry = CatalogEntry(title: String(localized: "Runs in the background", bundle: .greeceKit), symbol: "gearshape.fill", tint: .orange)
            case .xpcService: entry = CatalogEntry(title: String(localized: "XPC service", bundle: .greeceKit), symbol: "gearshape.2", tint: .gray)
            case .helper: entry = CatalogEntry(title: String(localized: "Helper", bundle: .greeceKit, comment: "Inspector row subtitle: a helper app inside an app"), symbol: "app.badge", tint: .gray)
            case .watchApp: entry = CatalogEntry(title: String(localized: "Apple Watch app", bundle: .greeceKit), symbol: "applewatch", tint: .gray)
            case .appClip: entry = CatalogEntry(title: "App Clip", symbol: "appclip", tint: .blue)
            case .plugin: entry = CatalogEntry(title: String(localized: "Plug-in", bundle: .greeceKit, comment: "A kind of bundle"), symbol: "puzzlepiece.fill", tint: .gray)
            case .framework: entry = CatalogEntry(title: String(localized: "Framework", bundle: .greeceKit, comment: "A kind of bundle: a code library"), symbol: "shippingbox.fill", tint: .brown)
            }
            var subtitle = [entry.title]
            var tone = entry.tone
            if let team = nested.teamID, let main = mainTeam, !main.isEmpty {
                if team.isEmpty {
                    subtitle.append(String(localized: "ad hoc signed", bundle: .greeceKit, comment: "Inspector row subtitle part, after a “·”: a helper or extension signed without a certificate"))
                    tone = .caution
                } else if team != main {
                    subtitle.append(String(localized: "signed by another team (\(team))", bundle: .greeceKit,
                                           comment: "Inspector row subtitle part, after a “·”. The argument is a team ID, such as “SY64MV22J9”"))
                    tone = .caution
                }
            }
            if nested.role == .launchAgent || nested.role == .launchDaemon, let program = nested.identifier { subtitle.append(program) }
            if title.isEmpty { title = (nested.path as NSString).lastPathComponent }
            // A flagged row shows a warning marker, so its version moves into the subtitle.
            let flagged = tone == .caution || tone == .critical
            if flagged, let version = nested.version {
                subtitle.append(String(localized: "version \(version)", bundle: .greeceKit, comment: "Inspector row subtitle part, after a “·”. The argument is a version, such as “2.1”"))
            }
            return InspectorItem(symbol: entry.symbol, tint: entry.tint, title: title, subtitle: subtitle.joined(separator: " · "),
                                 value: flagged ? nil : nested.version, tone: tone, help: nested.identifier ?? nested.path)
        }
        var sections: [InspectorSection] = []
        let extensions = facts.nested.filter { [.appExtension, .systemExtension, .watchApp, .appClip, .plugin].contains($0.role) }
        if !extensions.isEmpty {
            sections.append(InspectorSection("extensions", title: String(localized: "Extensions", bundle: .greeceKit, comment: "Section title: the app extensions inside an app"), rows: extensions.map { .item(item($0)) }, visibleLimit: 10))
        }
        let background = facts.nested.filter { [.loginItem, .privilegedHelper, .launchAgent, .launchDaemon, .helper, .xpcService].contains($0.role) }
        if !background.isEmpty {
            let footer = background.contains { $0.role == .privilegedHelper || $0.role == .launchDaemon }
                ? String(localized: "Some of these run with administrator privileges once you approve them.", bundle: .greeceKit) : nil
            sections.append(InspectorSection("background", title: String(localized: "Helpers and Background Items", bundle: .greeceKit), footer: footer,
                                             rows: background.map { .item(item($0)) }, visibleLimit: 10))
        }
        return sections
    }

    // MARK: - Documents and URLs

    static func documentTypes(_ facts: BundleFacts) -> InspectorSection? {
        let types = (facts.info["CFBundleDocumentTypes"] as? [[String: Any]]) ?? []
        var rows: [InspectorItem] = []
        for type in types.prefix(200) {
            let extensions = ((type["CFBundleTypeExtensions"] as? [String]) ?? []).filter { $0 != "*" }.map { "." + $0.lowercased() }
            let utis = (type["LSItemContentTypes"] as? [String]) ?? []
            var name = (type["CFBundleTypeName"] as? String).map { Format.clean($0, limit: 80) }
            if name == nil, let first = utis.first { name = UTTypeName.describe(first) }
            let role = (type["CFBundleTypeRole"] as? String) ?? "Viewer"
            let rank = type["LSHandlerRank"] as? String
            var subtitle = extensions.isEmpty ? utis.prefix(4).joined(separator: ", ") : extensions.prefix(8).joined(separator: " ")
            if extensions.count > 8 { subtitle = andMore(subtitle, extensions.count - 8) }
            let handling: String
            switch role {
            case "Editor": handling = String(localized: "Opens and edits", bundle: .greeceKit, comment: "Inspector row value: what an app does with a document type")
            case "Shell": handling = String(localized: "Shell", bundle: .greeceKit, comment: "Inspector row value: an app’s role for a document type (Apple’s “Shell” role, providing runtime services)")
            case "None": handling = String(localized: "Declares", bundle: .greeceKit, comment: "Inspector row value: an app declares a document type without opening it")
            default: handling = String(localized: "Opens", bundle: .greeceKit, comment: "Inspector row value: an app opens a document type (verb)")
            }
            var value = handling
            if rank == "Owner" { value += " · " + String(localized: "Owner", bundle: .greeceKit, comment: "Inspector row value, after a “·”: the app is the document type’s owner") }
            if rank == "Alternate" { value += " · " + String(localized: "Alternate", bundle: .greeceKit, comment: "Inspector row value, after a “·”: the app is an alternate handler for the document type") }
            rows.append(InspectorItem(symbol: role == "Editor" ? "pencil.and.list.clipboard" : "doc",
                                      title: name ?? String(localized: "Document", bundle: .greeceKit, comment: "Inspector row title: a document type without a name"),
                                      subtitle: subtitle.nilIfEmpty, value: value, help: utis.joined(separator: "\n").nilIfEmpty))
        }
        let exported = (facts.info["UTExportedTypeDeclarations"] as? [[String: Any]]) ?? []
        for type in exported.prefix(60) {
            guard let identifier = type["UTTypeIdentifier"] as? String else { continue }
            let tags = (type["UTTypeTagSpecification"] as? [String: Any])?["public.filename-extension"]
            let extensions = ((tags as? [String]) ?? (tags as? String).map { [$0] } ?? []).map { "." + $0 }
            rows.append(InspectorItem(symbol: "doc.badge.gearshape", title: (type["UTTypeDescription"] as? String).map { Format.clean($0, limit: 80) } ?? identifier,
                                      subtitle: extensions.prefix(8).joined(separator: " ").nilIfEmpty,
                                      value: String(localized: "Defines", bundle: .greeceKit, comment: "Inspector row value: an app defines (exports) a file type"), help: identifier))
        }
        guard !rows.isEmpty else { return nil }
        return InspectorSection("documents", title: String(localized: "Document Types", bundle: .greeceKit), rows: rows.map(InspectorRow.item), visibleLimit: 8)
    }

    static func urlSchemes(_ facts: BundleFacts) -> InspectorSection? {
        let types = (facts.info["CFBundleURLTypes"] as? [[String: Any]]) ?? []
        var rows: [InspectorItem] = []
        for type in types.prefix(50) {
            let schemes = ((type["CFBundleURLSchemes"] as? [String]) ?? []).map { Format.clean($0, limit: 60) }
            guard !schemes.isEmpty else { continue }
            let name = (type["CFBundleURLName"] as? String).map { Format.clean($0, limit: 120) }
            for scheme in schemes.prefix(10) {
                let web = ["http", "https"].contains(scheme.lowercased())
                let label = name == facts.identifier ? nil : name
                rows.append(InspectorItem(symbol: web ? "safari" : "link", title: scheme + "://",
                                          subtitle: web ? String(localized: "Can be your default web browser", bundle: .greeceKit) : nil,
                                          value: label, help: name))
            }
        }
        guard !rows.isEmpty else { return nil }
        return InspectorSection("urls", title: String(localized: "URL Schemes", bundle: .greeceKit),
                                footer: String(localized: "Links that open in this app.", bundle: .greeceKit), rows: rows.map(InspectorRow.item), visibleLimit: 8)
    }

    // MARK: - Code

    static func frameworks(_ facts: BundleFacts) -> InspectorSection? {
        let embedded = facts.nested.filter { $0.role == .framework }
        guard !embedded.isEmpty else { return nil }
        let mainTeam = facts.signature?.teamID
        // Sizes only mean something once every file was counted.
        let sized = facts.filesComplete
        let ordered = sized ? embedded.sorted { $0.size > $1.size } : embedded.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let rows = ordered.map { framework -> InspectorRow in
            var subtitle: String?
            var tone = InspectorTone.neutral
            if let team = framework.teamID, let main = mainTeam, !main.isEmpty, !team.isEmpty, team != main {
                subtitle = String(localized: "Signed by another team (\(team))", bundle: .greeceKit,
                                  comment: "Inspector row subtitle for an embedded framework. The argument is a team ID, such as “SY64MV22J9”")
                tone = .caution
            }
            let value = Format.joined([framework.version, sized && framework.size > 0 ? Format.bytes(framework.size) : nil])
            return .item(InspectorItem(symbol: "shippingbox", title: framework.name, subtitle: subtitle, value: value.nilIfEmpty,
                                       tone: tone, help: framework.identifier ?? framework.path))
        }
        return InspectorSection("frameworks", title: String(localized: "Embedded Frameworks", bundle: .greeceKit), rows: rows, visibleLimit: 8)
    }

    static func libraries(_ facts: BundleFacts) -> InspectorSection? {
        guard let slice = facts.macho?.preferredSlice, !slice.libraries.isEmpty else { return nil }
        return LibrarySection.build(slice.libraries, id: "libraries", title: LibrarySection.linkedLibrariesTitle)
    }

    // MARK: - Size

    static func size(_ facts: BundleFacts) -> InspectorSection? {
        guard facts.files.count > 1 else { return nil }
        let c = facts.contents
        let executableTitle = String(localized: "Executable", bundle: .greeceKit, comment: "Storage bar segment or inspector row: an app’s main program file")
        let frameworksTitle = String(localized: "Frameworks", bundle: .greeceKit, comment: "Storage bar segment: the code libraries inside an app")
        let extensionsTitle = String(localized: "Extensions", bundle: .greeceKit, comment: "Storage bar segment: the app extensions inside an app")
        let localizationsTitle = String(localized: "Localizations", bundle: .greeceKit, comment: "Storage bar segment: an app’s translations")
        let resourcesTitle = String(localized: "Resources", bundle: .greeceKit, comment: "Storage bar segment: an app’s images, sounds and other files")
        var buckets: [(String, InspectorTint, (String) -> Bool)] = []
        if facts.layout == .macOS {
            buckets = [
                (executableTitle, .blue, { $0.hasPrefix(c + "MacOS/") }),
                (frameworksTitle, .purple, { $0.hasPrefix(c + "Frameworks/") }),
                (extensionsTitle, .teal, { $0.hasPrefix(c + "PlugIns/") || $0.hasPrefix(c + "Extensions/") || $0.hasPrefix(c + "Library/") || $0.hasPrefix(c + "XPCServices/") || $0.hasPrefix(c + "Helpers/") }),
                (localizationsTitle, .orange, { $0.hasPrefix(c + "Resources/") && $0.contains(".lproj/") }),
                (resourcesTitle, .pink, { $0.hasPrefix(c + "Resources/") }),
            ]
        } else {
            let executable = facts.executablePath
            buckets = [
                (executableTitle, .blue, { $0 == executable }),
                (frameworksTitle, .purple, { $0.hasPrefix("Frameworks/") }),
                (extensionsTitle, .teal, { $0.hasPrefix("PlugIns/") || $0.hasPrefix("Extensions/") || $0.hasPrefix("Watch/") || $0.hasPrefix("AppClips/") }),
                (localizationsTitle, .orange, { $0.contains(".lproj/") }),
                (resourcesTitle, .pink, { _ in true }),
            ]
        }
        var totals = [UInt64](repeating: 0, count: buckets.count + 1)
        for file in facts.files {
            let index = buckets.firstIndex { $0.2(file.path) } ?? buckets.count
            totals[index] = totals[index].saturatingAdd(file.size)
        }
        var segments: [InspectorSizes.Segment] = []
        for (index, bucket) in buckets.enumerated() where totals[index] > 0 {
            segments.append(.init(title: bucket.0, bytes: totals[index], tint: bucket.1))
        }
        if totals[buckets.count] > 0 {
            segments.append(.init(title: String(localized: "Other", bundle: .greeceKit, comment: "Storage bar segment: files in no other category"), bytes: totals[buckets.count], tint: .gray))
        }
        segments.sort { $0.bytes > $1.bytes }
        var rows: [InspectorRow] = [.sizes(InspectorSizes(total: facts.totalSize, segments: segments))]

        // The largest single items: frameworks and big files explain most of an app's size.
        var items: [(String, UInt64, String)] = facts.nested.filter { $0.size > 0 }.map { ($0.name, $0.size, $0.role.title) }
        let nestedPrefixes = facts.nested.map { $0.path + "/" }
        for file in facts.files.sorted(by: { $0.size > $1.size }).prefix(40) where !nestedPrefixes.contains(where: { file.path.hasPrefix($0) }) {
            items.append(((file.path as NSString).lastPathComponent, file.size, (file.path as NSString).deletingLastPathComponent))
        }
        for item in items.sorted(by: { $0.1 > $1.1 }).prefix(5) where facts.totalSize > 0 && Double(item.1) / Double(facts.totalSize) > 0.02 {
            rows.append(.item(InspectorItem(title: item.0, subtitle: item.2.nilIfEmpty, value: Format.bytes(item.1), help: item.2)))
        }
        let footer = facts.filesComplete ? nil : countedNote(facts.files.count)
        return InspectorSection("size", title: sizeTitle, footer: footer, rows: rows)
    }

    // MARK: - Info

    static func info(_ facts: BundleFacts) -> InspectorSection {
        var rows: [InspectorItem] = []
        let info = facts.info
        rows.append(.field(kindLabel, facts.kindTitle))
        if let category = info["LSApplicationCategoryType"] as? String {
            rows.append(.field(categoryLabel, humanize(category.replacingOccurrences(of: "public.app-category.", with: "").replacingOccurrences(of: "-", with: " "), prefix: "")))
        }
        if let minimum = facts.minimumSystem {
            let platform = facts.isIOS ? (facts.isWrappedIOSApp ? "iOS" : platformName(facts)) : "macOS"
            let system = "\(platform) \(Format.clean(minimum, limit: 20))"
            rows.append(.field(String(localized: "Requires", bundle: .greeceKit, comment: "Inspector row title: the oldest system an app runs on"),
                               String(localized: "\(system) or later", bundle: .greeceKit, comment: "Inspector row value. The argument is a system and version, such as “macOS 14.0”")))
        }
        if let families = info["UIDeviceFamily"] as? [Int], facts.isIOS {
            let names = families.compactMap { [1: "iPhone", 2: "iPad", 3: "Apple TV", 4: "Apple Watch", 6: "Mac", 7: "Apple Vision Pro"][$0] }
            if !names.isEmpty {
                rows.append(.field(String(localized: "Devices", bundle: .greeceKit, comment: "Inspector row title: the kinds of devices an iOS app runs on"), ListFormatter.localizedString(byJoining: names)))
            }
        }
        if let slices = facts.macho?.slices, !slices.isEmpty {
            rows.append(.field(architecturesLabel, facts.macho!.architectures.joined(separator: ", ")))
        }
        if let sdk = info["DTSDKName"] as? String ?? facts.macho?.preferredSlice?.builds.first?.sdk.map({ "SDK " + $0 }) {
            rows.append(.field(String(localized: "Built With", bundle: .greeceKit, comment: "Inspector row title: the SDK and Xcode version an app was built with"),
                               sdkName(sdk, xcode: info["DTXcode"] as? String, build: info["DTXcodeBuild"] as? String)))
        }
        if !facts.technologies.isEmpty {
            rows.append(.field(String(localized: "Technologies", bundle: .greeceKit, comment: "Inspector row title: frameworks and languages an app is made with"), facts.technologies.joined(separator: ", ")))
        }
        if !facts.localizations.isEmpty {
            rows.append(InspectorItem(title: String(localized: "Languages", bundle: .greeceKit, comment: "Inspector row title: how many languages an app is translated into"),
                                      value: String(localized: "\(facts.localizations.count) languages", bundle: .greeceKit, comment: "Inspector row value: how many languages an app is translated into"),
                                      help: facts.localizations.map { Locale.current.localizedString(forIdentifier: $0) ?? $0 }.joined(separator: ", ")))
        }
        let appearance = String(localized: "Appearance", bundle: .greeceKit, comment: "Inspector row title: whether an app shows in the Dock or menu bar")
        if info["LSUIElement"] as? Bool == true || (info["LSUIElement"] as? String) == "1" {
            rows.append(.field(appearance, String(localized: "Menu bar app (no Dock icon)", bundle: .greeceKit)))
        }
        if info["LSBackgroundOnly"] as? Bool == true { rows.append(.field(appearance, String(localized: "Background only", bundle: .greeceKit, comment: "Inspector row value: an app runs only in the background"))) }
        if let ats = info["NSAppTransportSecurity"] as? [String: Any], ats["NSAllowsArbitraryLoads"] as? Bool == true {
            rows.append(InspectorItem(title: String(localized: "Network Security", bundle: .greeceKit), value: String(localized: "Allows insecure connections", bundle: .greeceKit), tone: .caution,
                                      help: String(localized: "NSAllowsArbitraryLoads turns off App Transport Security, allowing unencrypted HTTP.", bundle: .greeceKit)))
        }
        if let feed = info["SUFeedURL"] as? String {
            rows.append(InspectorItem(title: String(localized: "Updates", bundle: .greeceKit, comment: "Inspector row title: the feed an app checks for updates"), value: Format.clean(feed, limit: 200),
                                      help: String(localized: "Sparkle checks this feed for updates.", bundle: .greeceKit), mono: true))
        }
        if let copyright = info["NSHumanReadableCopyright"] as? String, !copyright.isEmpty {
            rows.append(.field(copyrightLabel, Format.clean(copyright, limit: 200)))
        }
        if let executable = facts.executablePath, let slice = facts.macho?.preferredSlice, let uuid = slice.uuid {
            rows.append(InspectorItem(title: String(localized: "Executable", bundle: .greeceKit, comment: "Storage bar segment or inspector row: an app’s main program file"),
                                      value: (executable as NSString).lastPathComponent, help: "UUID " + uuid.uuidString))
        }
        return InspectorSection("info", title: infoTitle, rows: rows.map(InspectorRow.item))
    }

    // Labels shared by several inspector pages.
    static var infoTitle: String { String(localized: "Info", bundle: .greeceKit, comment: "Section or tab title: general information about a file") }
    static var kindLabel: String { String(localized: "Kind", bundle: .greeceKit, comment: "Inspector row title: what kind of file or bundle it is") }
    static var categoryLabel: String { String(localized: "Category", bundle: .greeceKit, comment: "Inspector row title: an app’s App Store category") }
    static var architecturesLabel: String { String(localized: "Architectures", bundle: .greeceKit, comment: "Inspector row or section title: the processor types a program is built for") }
    static var copyrightLabel: String { String(localized: "Copyright", bundle: .greeceKit, comment: "Inspector row title") }
    static var sizeLabel: String { String(localized: "Size", bundle: .greeceKit, comment: "Inspector row title: a file’s size") }

    static func platformName(_ facts: BundleFacts) -> String {
        if let platforms = facts.info["CFBundleSupportedPlatforms"] as? [String] {
            if platforms.contains("XROS") { return "visionOS" }
            if platforms.contains("WatchOS") { return "watchOS" }
            if platforms.contains("AppleTVOS") { return "tvOS" }
        }
        return "iOS"
    }

    /// "macosx15.2" + "1620" → "macOS 15.2 SDK, Xcode 16.2".
    static func sdkName(_ sdk: String, xcode: String?, build: String?) -> String {
        var name = sdk
        let prefixes = [("macosx", "macOS"), ("iphoneos", "iOS"), ("iphonesimulator", "iOS Simulator"), ("appletvos", "tvOS"),
                        ("watchos", "watchOS"), ("xros", "visionOS"), ("driverkit", "DriverKit")]
        for (prefix, display) in prefixes where sdk.lowercased().hasPrefix(prefix) {
            name = display + " " + sdk.dropFirst(prefix.count) + " SDK"
            break
        }
        if let xcode, let number = Int(xcode), number > 0 {
            let major = number / 100, minor = (number / 10) % 10, patch = number % 10
            var version = "\(major).\(minor)"
            if patch > 0 { version += ".\(patch)" }
            name += ", Xcode " + version
            if let build { name += " (\(build))" }
        }
        return name
    }
}

/// Linked libraries grouped the way people think of them: Apple's, bundled, and third-party paths.
enum LibrarySection {
    static var linkedLibrariesTitle: String {
        String(localized: "Linked Libraries", bundle: .greeceKit, comment: "Section title: the libraries a program loads")
    }

    static func build(_ libraries: [MachOFile.Library], id: String, title: String) -> InspectorSection {
        let sorted = libraries.sorted { lhs, rhs in
            let l = group(lhs), r = group(rhs)
            return l != r ? l < r : lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        let rows = sorted.map { library -> InspectorRow in
            var notes: [String] = []
            switch library.kind {
            case .weak: notes.append(String(localized: "Optional", bundle: .greeceKit, comment: "Inspector row subtitle: a weakly linked library, loaded only if present"))
            case .reexport: notes.append(String(localized: "Re-exported", bundle: .greeceKit, comment: "Inspector row subtitle: a library re-exported by the one that links it"))
            case .lazy: notes.append(String(localized: "Lazy", bundle: .greeceKit, comment: "Inspector row subtitle: a lazily loaded library"))
            case .upward: notes.append(String(localized: "Upward", bundle: .greeceKit, comment: "Inspector row subtitle: an upward-linked library (a Mach-O linking term)"))
            case .normal: break
            }
            var tone = InspectorTone.neutral
            var symbol = "apple.logo"
            if library.isEmbedded {
                symbol = "shippingbox"
                notes.insert(String(localized: "Bundled", bundle: .greeceKit, comment: "Inspector row subtitle: a library that ships inside the app"), at: 0)
            } else if !library.isSystem {
                symbol = "exclamationmark.triangle"
                tone = .caution
                notes.insert(library.path.hasPrefix("/opt/homebrew") || library.path.hasPrefix("/usr/local")
                             ? String(localized: "Needs Homebrew or a manual install", bundle: .greeceKit)
                             : String(localized: "Outside the system", bundle: .greeceKit, comment: "Inspector row subtitle: a library outside macOS’s own folders"), at: 0)
            }
            // System libraries report build numbers ("2685.50.120"); only third-party versions mean much.
            let version = library.currentVersion == "0.0" || library.isSystem ? nil : library.currentVersion
            let versionLine = String(localized: "Version \(library.currentVersion)", bundle: .greeceKit, comment: "Tooltip line under a library’s path. The argument is its version")
            return .item(InspectorItem(symbol: symbol, title: library.name, subtitle: notes.joined(separator: " · ").nilIfEmpty,
                                       value: version, tone: tone, help: library.path + (library.isSystem ? "\n" + versionLine : "")))
        }
        let system = libraries.filter(\.isSystem).count
        let footer = String(localized: "\(libraries.count) libraries, \(system) from macOS. Hover for the full path.", bundle: .greeceKit,
                            comment: "Section footer. The arguments are how many libraries a program links, and how many of them come with macOS")
        return InspectorSection(id, title: title, footer: footer, rows: rows, visibleLimit: 10)
    }

    private static func group(_ library: MachOFile.Library) -> Int {
        if !library.isSystem && !library.isEmbedded { return 0 }
        if library.isEmbedded { return 1 }
        return 2
    }
}

enum UTTypeName {
    static func describe(_ identifier: String) -> String {
        UTType(identifier)?.localizedDescription.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? identifier
    }
}
