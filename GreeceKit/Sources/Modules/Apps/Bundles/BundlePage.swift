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
            page.badges.append(InspectorBadge("platform", symbol: "ipad.and.iphone", title: "iPhone and iPad App", tone: .accent,
                                              help: "An iOS app that runs on Macs with Apple silicon."))
        }

        let ticket = facts.source.url.flatMap { NotarizationTicket.stapled(inBundle: $0) }
        let signing = SigningSection.build(signature: facts.macho == nil ? nil : facts.signature, url: facts.source.url, subject: subject,
                                           ticket: ticket, fileCount: facts.files.count, totalSize: facts.totalSize)
        if facts.macho != nil || facts.executablePath != nil {
            page.badges += signing.badges
            page.sections.append(signing.section)
            page.checks += signing.checks
        }
        if facts.isSandboxed && !facts.isIOS {
            page.badges.append(InspectorBadge("sandbox", symbol: "shield.lefthalf.filled", title: "Sandboxed", tone: .positive,
                                              help: "Runs in the App Sandbox: it can reach only what its entitlements allow."))
        }
        if facts.entitlements["com.apple.security.hardened-process"] as? Bool == true {
            page.badges.append(InspectorBadge("enhanced", symbol: "lock.shield.fill", title: "Enhanced Security", tone: .positive,
                                              help: "Opts into macOS’s Enhanced Security protections, such as a hardened memory allocator."))
        }
        if let slice = facts.macho?.preferredSlice, slice.isEncrypted {
            page.badges.append(InspectorBadge("encrypted", symbol: "lock.fill", title: "Encrypted", tone: .neutral,
                                              help: "The App Store encrypted the executable (FairPlay). Some details can’t be read."))
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
        if let section = size(facts) { page.sections.append(section) }
        page.sections.append(info(facts))

        var details: [String] = []
        if let version = facts.shortVersion { details.append(version) }
        if let slices = facts.macho?.slices, !slices.isEmpty { details.append(facts.macho!.architectures.joined(separator: ", ")) }
        if facts.totalSize > 0 { details.append(Format.bytes(facts.totalSize)) }
        page.summary.details = details

        if let url = facts.source.url {
            let node = FileNode.folder(at: url, showHidden: false)
            page.contents = .tree(node, title: "Contents", count: nil)
        }
        return page
    }

    // MARK: - Capabilities

    static func capabilities(_ facts: BundleFacts) -> InspectorSection? {
        let entitlements = facts.entitlements
        guard !entitlements.isEmpty else { return nil }
        var rows: [InspectorItem] = []
        var unknown: [InspectorItem] = []
        for key in entitlements.keys.sorted() where !EntitlementCatalog.hidden.contains(key) {
            let value = entitlements[key]!
            if let flag = value as? Bool, flag == false { continue }
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
        let all = (rows + unknown).map(InspectorRow.item)
        guard !all.isEmpty else { return nil }
        let footer = facts.isSandboxed ? "What the App Sandbox lets it reach. Hover over an item for its entitlement." :
            "Entitlements granted by its signature. Hover over an item for its key."
        return InspectorSection("capabilities", title: "Capabilities", footer: footer, rows: all, visibleLimit: 14)
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
            guard !strings.isEmpty else { return list.isEmpty ? nil : Format.count(list.count, "item") }
            let shown = strings.prefix(6).joined(separator: ", ")
            return strings.count > 6 ? shown + " and \(strings.count - 6) more" : shown
        }
        if let string = value as? String { return Format.clean(string, limit: 160) }
        if let dictionary = value as? [String: Any] {
            let keys = dictionary.keys.sorted().map { Format.clean($0, limit: 80) }
            guard !keys.isEmpty else { return nil }
            let shown = keys.prefix(4).joined(separator: ", ")
            return keys.count > 4 ? shown + " and \(keys.count - 4) more" : shown
        }
        if let number = value as? NSNumber, !(value is Bool) { return number.stringValue }
        return nil
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
        return InspectorSection("privacy", title: "Privacy", footer: "What it may ask to use, in the developer’s words. macOS asks you first.",
                                rows: rows.map(InspectorRow.item), visibleLimit: 12)
    }

    static func privacyManifest(_ facts: BundleFacts) -> InspectorSection? {
        guard let manifest = facts.privacyManifest else { return nil }
        var rows: [InspectorRow] = []
        let tracking = manifest["NSPrivacyTracking"] as? Bool ?? false
        rows.append(.item(InspectorItem(symbol: tracking ? "eye.fill" : "eye.slash", tint: tracking ? .orange : .green,
                                        title: tracking ? "Tracks you" : "Doesn’t track you", tone: tracking ? .caution : .neutral,
                                        help: "NSPrivacyTracking")))
        if let domains = manifest["NSPrivacyTrackingDomains"] as? [String], !domains.isEmpty {
            rows.append(.item(InspectorItem(symbol: "network", tint: .orange, title: "Tracking domains",
                                            subtitle: domains.prefix(8).map { Format.clean($0, limit: 80) }.joined(separator: ", "), help: "NSPrivacyTrackingDomains")))
        }
        for entry in ((manifest["NSPrivacyCollectedDataTypes"] as? [[String: Any]]) ?? []).prefix(40) {
            guard let type = entry["NSPrivacyCollectedDataType"] as? String else { continue }
            let linked = entry["NSPrivacyCollectedDataTypeLinked"] as? Bool ?? false
            let tracks = entry["NSPrivacyCollectedDataTypeTracking"] as? Bool ?? false
            let purposes = ((entry["NSPrivacyCollectedDataTypePurposes"] as? [String]) ?? []).map { humanize($0, prefix: "NSPrivacyCollectedDataTypePurpose") }
            var notes: [String] = []
            if linked { notes.append("Linked to you") }
            if tracks { notes.append("Used to track you") }
            if !purposes.isEmpty { notes.append(purposes.joined(separator: ", ")) }
            rows.append(.item(InspectorItem(symbol: "tray.full.fill", tint: tracks ? .orange : .blue, title: humanize(type, prefix: "NSPrivacyCollectedDataType"),
                                            subtitle: notes.joined(separator: " · ").nilIfEmpty, tone: tracks ? .caution : .neutral, help: type)))
        }
        for entry in ((manifest["NSPrivacyAccessedAPITypes"] as? [[String: Any]]) ?? []).prefix(20) {
            guard let type = entry["NSPrivacyAccessedAPIType"] as? String else { continue }
            let reasons = ((entry["NSPrivacyAccessedAPITypeReasons"] as? [String]) ?? []).joined(separator: ", ")
            rows.append(.item(InspectorItem(symbol: "chevron.left.forwardslash.chevron.right", tint: .gray,
                                            title: "Uses " + humanize(type, prefix: "NSPrivacyAccessedAPICategory").lowercased() + " APIs",
                                            subtitle: reasons.isEmpty ? nil : "Reasons: " + reasons, help: type)))
        }
        return InspectorSection("privacyManifest", title: "Privacy Manifest", footer: "What the developer declared in PrivacyInfo.xcprivacy.",
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
                entry = nested.extensionPoint.map(ExtensionPointCatalog.describe) ?? CatalogEntry(title: nested.role.rawValue, symbol: "puzzlepiece.extension.fill", tint: .gray)
            case .loginItem: entry = CatalogEntry(title: "Opens at login", symbol: "power", tint: .orange, tone: .neutral)
            case .privilegedHelper: entry = CatalogEntry(title: "Runs as root", symbol: "lock.open.fill", tint: .red, tone: .caution)
            case .launchDaemon: entry = CatalogEntry(title: "Runs as root in the background", symbol: "gearshape.2.fill", tint: .red, tone: .caution)
            case .launchAgent: entry = CatalogEntry(title: "Runs in the background", symbol: "gearshape.fill", tint: .orange)
            case .xpcService: entry = CatalogEntry(title: "XPC service", symbol: "gearshape.2", tint: .gray)
            case .helper: entry = CatalogEntry(title: "Helper", symbol: "app.badge", tint: .gray)
            case .watchApp: entry = CatalogEntry(title: "Apple Watch app", symbol: "applewatch", tint: .gray)
            case .appClip: entry = CatalogEntry(title: "App Clip", symbol: "appclip", tint: .blue)
            case .plugin: entry = CatalogEntry(title: "Plug-in", symbol: "puzzlepiece.fill", tint: .gray)
            case .framework: entry = CatalogEntry(title: "Framework", symbol: "shippingbox.fill", tint: .brown)
            }
            var subtitle = [entry.title]
            var tone = entry.tone
            if let team = nested.teamID, let main = mainTeam, !main.isEmpty {
                if team.isEmpty { subtitle.append("ad hoc signed"); tone = .caution }
                else if team != main { subtitle.append("signed by another team (\(team))"); tone = .caution }
            }
            if nested.role == .launchAgent || nested.role == .launchDaemon, let program = nested.identifier { subtitle.append(program) }
            if title.isEmpty { title = (nested.path as NSString).lastPathComponent }
            return InspectorItem(symbol: entry.symbol, tint: entry.tint, title: title, subtitle: subtitle.joined(separator: " · "),
                                 value: nested.version, tone: tone, help: nested.identifier ?? nested.path)
        }
        var sections: [InspectorSection] = []
        let extensions = facts.nested.filter { [.appExtension, .systemExtension, .watchApp, .appClip, .plugin].contains($0.role) }
        if !extensions.isEmpty {
            sections.append(InspectorSection("extensions", title: "Extensions", rows: extensions.map { .item(item($0)) }, visibleLimit: 10))
        }
        let background = facts.nested.filter { [.loginItem, .privilegedHelper, .launchAgent, .launchDaemon, .helper, .xpcService].contains($0.role) }
        if !background.isEmpty {
            let footer = background.contains { $0.role == .privilegedHelper || $0.role == .launchDaemon }
                ? "Some of these run with administrator privileges once you approve them." : nil
            sections.append(InspectorSection("background", title: "Helpers and Background Items", footer: footer,
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
            if extensions.count > 8 { subtitle += " and \(extensions.count - 8) more" }
            var value = role == "Editor" ? "Opens and edits" : role == "Shell" ? "Shell" : role == "None" ? "Declares" : "Opens"
            if rank == "Owner" { value += " · Owner" }
            if rank == "Alternate" { value += " · Alternate" }
            rows.append(InspectorItem(symbol: role == "Editor" ? "pencil.and.list.clipboard" : "doc", title: name ?? "Document",
                                      subtitle: subtitle.nilIfEmpty, value: value, help: utis.joined(separator: "\n").nilIfEmpty))
        }
        let exported = (facts.info["UTExportedTypeDeclarations"] as? [[String: Any]]) ?? []
        for type in exported.prefix(60) {
            guard let identifier = type["UTTypeIdentifier"] as? String else { continue }
            let tags = (type["UTTypeTagSpecification"] as? [String: Any])?["public.filename-extension"]
            let extensions = ((tags as? [String]) ?? (tags as? String).map { [$0] } ?? []).map { "." + $0 }
            rows.append(InspectorItem(symbol: "doc.badge.gearshape", title: (type["UTTypeDescription"] as? String).map { Format.clean($0, limit: 80) } ?? identifier,
                                      subtitle: extensions.prefix(8).joined(separator: " ").nilIfEmpty, value: "Defines", help: identifier))
        }
        guard !rows.isEmpty else { return nil }
        return InspectorSection("documents", title: "Document Types", rows: rows.map(InspectorRow.item), visibleLimit: 8)
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
                rows.append(InspectorItem(symbol: web ? "safari" : "link", title: scheme + "://", subtitle: web ? "Can be your default web browser" : nil,
                                          value: label, help: name))
            }
        }
        guard !rows.isEmpty else { return nil }
        return InspectorSection("urls", title: "URL Schemes", footer: "Links that open in this app.", rows: rows.map(InspectorRow.item), visibleLimit: 8)
    }

    // MARK: - Code

    static func frameworks(_ facts: BundleFacts) -> InspectorSection? {
        let embedded = facts.nested.filter { $0.role == .framework }
        guard !embedded.isEmpty else { return nil }
        let mainTeam = facts.signature?.teamID
        let rows = embedded.sorted { $0.size > $1.size }.map { framework -> InspectorRow in
            var subtitle: String?
            var tone = InspectorTone.neutral
            if let team = framework.teamID, let main = mainTeam, !main.isEmpty, !team.isEmpty, team != main {
                subtitle = "Signed by another team (\(team))"
                tone = .caution
            }
            let value = Format.joined([framework.version, framework.size > 0 ? Format.bytes(framework.size) : nil])
            return .item(InspectorItem(symbol: "shippingbox", title: framework.name, subtitle: subtitle, value: value.nilIfEmpty,
                                       tone: tone, help: framework.identifier ?? framework.path))
        }
        return InspectorSection("frameworks", title: "Embedded Frameworks", rows: rows, visibleLimit: 8)
    }

    static func libraries(_ facts: BundleFacts) -> InspectorSection? {
        guard let slice = facts.macho?.preferredSlice, !slice.libraries.isEmpty else { return nil }
        return LibrarySection.build(slice.libraries, id: "libraries", title: "Linked Libraries")
    }

    // MARK: - Size

    static func size(_ facts: BundleFacts) -> InspectorSection? {
        guard facts.files.count > 1 else { return nil }
        let c = facts.contents
        var buckets: [(String, InspectorTint, (String) -> Bool)] = []
        if facts.layout == .macOS {
            buckets = [
                ("Executable", .blue, { $0.hasPrefix(c + "MacOS/") }),
                ("Frameworks", .purple, { $0.hasPrefix(c + "Frameworks/") }),
                ("Extensions", .teal, { $0.hasPrefix(c + "PlugIns/") || $0.hasPrefix(c + "Extensions/") || $0.hasPrefix(c + "Library/") || $0.hasPrefix(c + "XPCServices/") || $0.hasPrefix(c + "Helpers/") }),
                ("Localizations", .orange, { $0.hasPrefix(c + "Resources/") && $0.contains(".lproj/") }),
                ("Resources", .pink, { $0.hasPrefix(c + "Resources/") }),
            ]
        } else {
            let executable = facts.executablePath
            buckets = [
                ("Executable", .blue, { $0 == executable }),
                ("Frameworks", .purple, { $0.hasPrefix("Frameworks/") }),
                ("Extensions", .teal, { $0.hasPrefix("PlugIns/") || $0.hasPrefix("Extensions/") || $0.hasPrefix("Watch/") || $0.hasPrefix("AppClips/") }),
                ("Localizations", .orange, { $0.contains(".lproj/") }),
                ("Resources", .pink, { _ in true }),
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
        if totals[buckets.count] > 0 { segments.append(.init(title: "Other", bytes: totals[buckets.count], tint: .gray)) }
        segments.sort { $0.bytes > $1.bytes }
        var rows: [InspectorRow] = [.sizes(InspectorSizes(total: facts.totalSize, segments: segments))]

        // The largest single items: frameworks and big files explain most of an app's size.
        var items: [(String, UInt64, String)] = facts.nested.filter { $0.size > 0 }.map { ($0.name, $0.size, $0.role.rawValue) }
        let nestedPrefixes = facts.nested.map { $0.path + "/" }
        for file in facts.files.sorted(by: { $0.size > $1.size }).prefix(40) where !nestedPrefixes.contains(where: { file.path.hasPrefix($0) }) {
            items.append(((file.path as NSString).lastPathComponent, file.size, (file.path as NSString).deletingLastPathComponent))
        }
        for item in items.sorted(by: { $0.1 > $1.1 }).prefix(5) where facts.totalSize > 0 && Double(item.1) / Double(facts.totalSize) > 0.02 {
            rows.append(.item(InspectorItem(title: item.0, subtitle: item.2.nilIfEmpty, value: Format.bytes(item.1), help: item.2)))
        }
        let footer = facts.filesComplete ? nil : "Counted the first \(Format.count(facts.files.count, "file"))."
        return InspectorSection("size", title: "Size", footer: footer, rows: rows)
    }

    // MARK: - Info

    static func info(_ facts: BundleFacts) -> InspectorSection {
        var rows: [InspectorItem] = []
        let info = facts.info
        rows.append(.field("Kind", facts.kindTitle))
        if let category = info["LSApplicationCategoryType"] as? String {
            rows.append(.field("Category", humanize(category.replacingOccurrences(of: "public.app-category.", with: "").replacingOccurrences(of: "-", with: " "), prefix: "")))
        }
        if let minimum = facts.minimumSystem {
            let platform = facts.isIOS ? (facts.isWrappedIOSApp ? "iOS" : platformName(facts)) : "macOS"
            rows.append(.field("Requires", "\(platform) \(Format.clean(minimum, limit: 20)) or later"))
        }
        if let families = info["UIDeviceFamily"] as? [Int], facts.isIOS {
            let names = families.compactMap { [1: "iPhone", 2: "iPad", 3: "Apple TV", 4: "Apple Watch", 6: "Mac", 7: "Apple Vision Pro"][$0] }
            if !names.isEmpty { rows.append(.field("Devices", ListFormatter.localizedString(byJoining: names))) }
        }
        if let slices = facts.macho?.slices, !slices.isEmpty {
            rows.append(.field("Architectures", facts.macho!.architectures.joined(separator: ", ")))
        }
        if let sdk = info["DTSDKName"] as? String ?? facts.macho?.preferredSlice?.builds.first?.sdk.map({ "SDK " + $0 }) {
            rows.append(.field("Built With", sdkName(sdk, xcode: info["DTXcode"] as? String, build: info["DTXcodeBuild"] as? String)))
        }
        if !facts.technologies.isEmpty { rows.append(.field("Technologies", facts.technologies.joined(separator: ", "))) }
        if !facts.localizations.isEmpty {
            rows.append(InspectorItem(title: "Languages", value: Format.count(facts.localizations.count, "language"),
                                      help: facts.localizations.map { Locale.current.localizedString(forIdentifier: $0) ?? $0 }.joined(separator: ", ")))
        }
        if info["LSUIElement"] as? Bool == true || (info["LSUIElement"] as? String) == "1" {
            rows.append(.field("Appearance", "Menu bar app (no Dock icon)"))
        }
        if info["LSBackgroundOnly"] as? Bool == true { rows.append(.field("Appearance", "Background only")) }
        if let ats = info["NSAppTransportSecurity"] as? [String: Any], ats["NSAllowsArbitraryLoads"] as? Bool == true {
            rows.append(InspectorItem(title: "Network Security", value: "Allows insecure connections", tone: .caution,
                                      help: "NSAllowsArbitraryLoads turns off App Transport Security, allowing unencrypted HTTP."))
        }
        if let feed = info["SUFeedURL"] as? String {
            rows.append(InspectorItem(title: "Updates", value: Format.clean(feed, limit: 200), help: "Sparkle checks this feed for updates.", mono: true))
        }
        if let copyright = info["NSHumanReadableCopyright"] as? String, !copyright.isEmpty {
            rows.append(.field("Copyright", Format.clean(copyright, limit: 200)))
        }
        if let executable = facts.executablePath, let slice = facts.macho?.preferredSlice, let uuid = slice.uuid {
            rows.append(InspectorItem(title: "Executable", value: (executable as NSString).lastPathComponent, help: "UUID " + uuid.uuidString))
        }
        return InspectorSection("info", title: "Info", rows: rows.map(InspectorRow.item))
    }

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
    static func build(_ libraries: [MachOFile.Library], id: String, title: String) -> InspectorSection {
        let sorted = libraries.sorted { lhs, rhs in
            let l = group(lhs), r = group(rhs)
            return l != r ? l < r : lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        let rows = sorted.map { library -> InspectorRow in
            var notes: [String] = []
            switch library.kind {
            case .weak: notes.append("Optional")
            case .reexport: notes.append("Re-exported")
            case .lazy: notes.append("Lazy")
            case .upward: notes.append("Upward")
            case .normal: break
            }
            var tone = InspectorTone.neutral
            var symbol = "apple.logo"
            if library.isEmbedded {
                symbol = "shippingbox"
                notes.insert("Bundled", at: 0)
            } else if !library.isSystem {
                symbol = "exclamationmark.triangle"
                tone = .caution
                notes.insert(library.path.hasPrefix("/opt/homebrew") || library.path.hasPrefix("/usr/local") ? "Needs Homebrew or a manual install" : "Outside the system", at: 0)
            }
            // System libraries report build numbers ("2685.50.120"); only third-party versions mean much.
            let version = library.currentVersion == "0.0" || library.isSystem ? nil : library.currentVersion
            return .item(InspectorItem(symbol: symbol, title: library.name, subtitle: notes.joined(separator: " · ").nilIfEmpty,
                                       value: version, tone: tone, help: library.path + (library.isSystem ? "\nVersion " + library.currentVersion : "")))
        }
        let system = libraries.filter(\.isSystem).count
        let footer = "\(Format.count(libraries.count, "library", "libraries")), \(system) from macOS. Hover for the full path."
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
