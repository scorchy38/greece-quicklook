import AppKit

/// The inspector page for Android apps (.apk) and App Bundles (.aab).
enum AndroidPage {

    /// A ZIP whose extension says Android. The manifest check happens in `prepare`.
    static func sniff(probe: [UInt8], ext: String) -> Bool {
        guard ext == "apk" || ext == "aab" else { return false }
        return probe.count >= 4 && probe[0] == 0x50 && probe[1] == 0x4B && (probe[2] == 0x03 || probe[2] == 0x05) && (probe[3] == 0x04 || probe[3] == 0x06)
    }

    static func page(for url: URL, settings: PreviewSettings) throws -> InspectorPage {
        let package = try AndroidPackageReader.read(url)
        return page(for: package, url: url, settings: settings)
    }

    /// The launcher icon alone, for Finder thumbnails.
    static func icon(for url: URL) -> NSImage? {
        guard let zip = try? ZIPArchive(url: url) else { return nil }
        let deadline = Date().addingTimeInterval(1)
        let isBundle = zip.member("base/manifest/AndroidManifest.xml") != nil && zip.member("AndroidManifest.xml") == nil
        let manifestPath = isBundle ? "base/manifest/AndroidManifest.xml" : "AndroidManifest.xml"
        guard let data = zip.contents(of: manifestPath, limit: 8 << 20),
              let manifest = isBundle ? try? AndroidProtoXML.parse(data, deadline: deadline) : try? AndroidBinaryXML.parse(data, deadline: deadline)
        else { return nil }
        var resources: AndroidResourceTable?
        if let table = zip.contents(of: isBundle ? "base/resources.pb" : "resources.arsc", limit: 48 << 20) {
            resources = isBundle ? try? AndroidProtoResources(data: table, deadline: deadline)
                                 : try? AndroidBinaryResources(data: table, deadline: deadline)
        }
        return AndroidIcon.image(manifest: manifest, resources: resources, zip: zip, prefix: isBundle ? "base/" : "", deadline: deadline)
    }

    static func page(for package: AndroidPackage, url: URL, settings: PreviewSettings, now: Date = Date()) -> InspectorPage {
        let header = InspectorHeader(
            icon: package.icon.map { .image($0, shape: .asIs) } ?? .symbol("shippingbox.fill", .green),
            title: package.label ?? package.package ?? url.deletingPathExtension().lastPathComponent,
            subtitle: Format.version(package.versionName, build: package.versionCode),
            identifier: package.package)

        var page = InspectorPage(header: header, summary: summary(package, url: url))
        page.badges = badges(package)
        page.sections = [
            permissionsSection(package),
            integrationsSection(package),
            linksSection(package),
            signatureSection(package, now: now),
            componentsSection(package),
            architecturesSection(package),
            builtWithSection(package),
            sizeSection(package),
            infoSection(package),
        ].compactMap { $0 }
        if let listing = package.listing {
            page.contents = .tree(FileNode.tree(from: listing, showHidden: settings.showHiddenFiles),
                                  title: String(localized: "Files", bundle: .greeceKit, comment: "Tab title: the files inside the app, package or disk image being previewed"), count: listing.fileCount,
                                  members: ZIPMembers(url: url))
        }
        return page
    }

    // MARK: Summary and badges

    static func summary(_ package: AndroidPackage, url: URL) -> FileSummary {
        var details: [String] = []
        if let version = package.versionName { details.append(version) }
        if let minSdk = package.minSdk { details.append(AndroidVersions.short(minSdk)) }
        details.append(Format.bytes(package.fileSize))
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate.map(PreviewFactory.modifiedText)
        let title = package.kind == .apk ? String(localized: "Android App", bundle: .greeceKit, comment: "Info bar title for an .apk file")
                                         : String(localized: "Android App Bundle", bundle: .greeceKit, comment: "Info bar title for an .aab file")
        return FileSummary(symbol: "shippingbox", title: title, details: details, trailing: modified)
    }

    static func shortABI(_ abi: String) -> String {
        switch abi {
        case "arm64-v8a": return "arm64"
        case "armeabi-v7a": return "armv7"
        case "armeabi": return "armv5"
        case "riscv64": return "RISC-V"
        default: return abi
        }
    }

    static func badges(_ package: AndroidPackage) -> [InspectorBadge] {
        var badges: [InspectorBadge] = []
        let toolkits = ["Flutter", "React Native", "Unity", "Xamarin", ".NET MAUI", "Godot", "Unreal Engine", "Qt", "Capacitor", "Cordova"]
        if let toolkit = package.frameworks.first(where: { name in toolkits.contains { name.hasPrefix($0) } }) {
            badges.append(InspectorBadge("framework", symbol: "square.stack.3d.up", title: toolkit,
                                         help: String(localized: "Built with \(toolkit).", bundle: .greeceKit,
                                                      comment: "Badge tooltip. The argument is a toolkit such as Flutter or Unity")))
        }

        let abis = package.abis.map(\.name)
        if abis.isEmpty {
            badges.append(InspectorBadge("architectures", symbol: "cpu",
                                         title: String(localized: "Any Architecture", bundle: .greeceKit, comment: "Badge: an Android app without native code"),
                                         help: String(localized: "No native code: it runs on every Android processor.", bundle: .greeceKit)))
        } else {
            let hasARM = abis.contains { $0.hasPrefix("arm") }
            let hasX86 = abis.contains { $0.hasPrefix("x86") }
            let title: String
            if abis.count >= 4 || (hasARM && hasX86 && abis.count >= 3) {
                title = String(localized: "Universal", bundle: .greeceKit, comment: "Badge: runs on every processor architecture")
            } else if abis.count == 1 {
                title = String(localized: "\(shortABI(abis[0])) only", bundle: .greeceKit,
                               comment: "Badge: an Android app’s only processor architecture. The argument is a name such as “arm64”")
            } else {
                title = abis.map(shortABI).joined(separator: ", ")
            }
            let tone: InspectorTone = hasARM ? .neutral : .caution
            let list = abis.joined(separator: ", ")
            let help = hasARM
                ? String(localized: "Native code for \(list).", bundle: .greeceKit,
                         comment: "Badge tooltip. The argument lists Android architectures, such as “arm64-v8a, armeabi-v7a”")
                : String(localized: "Native code only for x86. Most Android phones use ARM processors and can’t run it.", bundle: .greeceKit)
            badges.append(InspectorBadge("architectures", symbol: "cpu", title: title, tone: tone, help: help))
        }

        let signature = package.signature
        if !signature.isSigned {
            badges.append(InspectorBadge("signer", symbol: "xmark.seal", title: String(localized: "Unsigned", bundle: .greeceKit, comment: "Badge"), tone: .critical,
                                         help: String(localized: "Not signed. Android refuses to install unsigned packages.", bundle: .greeceKit)))
        } else if signature.isDebugCertificate {
            badges.append(InspectorBadge("signer", symbol: "hammer", title: String(localized: "Debug Certificate", bundle: .greeceKit, comment: "Badge"), tone: .caution,
                                         help: String(localized: "Signed with Android Studio’s debug key. Google Play doesn’t accept it.", bundle: .greeceKit)))
        } else {
            badges.append(InspectorBadge("signer", symbol: "checkmark.seal", title: String(localized: "Signed", bundle: .greeceKit, comment: "Badge"), tone: .positive,
                                         help: String(localized: "Signed with \(schemeList(signature.schemes)).", bundle: .greeceKit,
                                                      comment: "Badge tooltip. The argument lists signature schemes, such as “JAR signing (v1) and APK Signature Scheme v2”")))
        }
        if signature.hasPlayMetadata {
            badges.append(InspectorBadge("store", symbol: "bag", title: "Google Play", tone: .positive,
                                         help: String(localized: "Includes the metadata Google Play adds to the apps it delivers.", bundle: .greeceKit)))
        }
        if package.debuggable {
            badges.append(InspectorBadge("debuggable", symbol: "ant", title: String(localized: "Debuggable", bundle: .greeceKit, comment: "Badge"), tone: .caution,
                                         help: String(localized: "Any debugger can attach to it and read its data.", bundle: .greeceKit)))
        }
        if package.testOnly {
            badges.append(InspectorBadge("testOnly", symbol: "testtube.2", title: String(localized: "Test Only", bundle: .greeceKit, comment: "Badge"), tone: .caution,
                                         help: String(localized: "Marked for testing: it installs only through developer tools.", bundle: .greeceKit)))
        }
        return badges
    }

    private static func schemeList(_ schemes: [String]) -> String {
        let names = schemes.map { scheme -> String in
            scheme.hasPrefix("v1") ? String(localized: "JAR signing (v1)", bundle: .greeceKit, comment: "An Android signature scheme") : "APK Signature Scheme \(scheme)"
        }
        return ListFormatter.localizedString(byJoining: names)
    }

    // MARK: Sections

    static func permissionsSection(_ package: AndroidPackage) -> InspectorSection? {
        guard !package.permissions.isEmpty else { return nil }
        let own = Set(package.definedPermissions)
        var known: [AndroidPermission] = []
        var custom: [String] = []
        for name in package.permissions {
            // A permission the app defines and holds itself grants nothing (AndroidX adds one to every app).
            if own.contains(name) { continue }
            let isFramework = name.hasPrefix("android.permission.") || name.hasPrefix("com.google.") || name.hasPrefix("com.android.")
            let permission = AndroidPermission.describe(name)
            if !isFramework && (own.contains(name) || permission.symbol == "key") {
                custom.append(name)
            } else {
                known.append(permission)
            }
        }
        known.sort { lhs, rhs in
            let left = (lhs.sensitive ? 1 : 0, lhs.level), right = (rhs.sensitive ? 1 : 0, rhs.level)
            if left.1 != right.1 { return left.1 > right.1 }
            if left.0 != right.0 { return left.0 > right.0 }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
        var rows: [InspectorRow] = known.map { permission in
            let value: String?
            switch permission.level {
            case .normal: value = nil
            case .runtime: value = String(localized: "Asks first", bundle: .greeceKit, comment: "Android permission that the person is asked to grant")
            case .special: value = String(localized: "Special access", bundle: .greeceKit, comment: "Android permission that the person turns on in Settings")
            case .system: value = String(localized: "System only", bundle: .greeceKit, comment: "Android permission that only system apps get")
            }
            return .item(InspectorItem(symbol: permission.symbol, tint: permission.tint, title: permission.title, value: value,
                                       tone: permission.sensitive ? .caution : .neutral, help: permission.name))
        }
        if !custom.isEmpty {
            rows.append(.item(InspectorItem(symbol: "key", tint: .gray, title: String(localized: "Custom permissions", bundle: .greeceKit),
                                            value: custom.count.formatted(),
                                            help: String(localized: "Permissions defined by apps rather than by Android.", bundle: .greeceKit),
                                            details: custom.prefix(200).map { InspectorItem.field($0, nil, mono: true) })))
        }
        guard !rows.isEmpty else { return nil }
        let asks = known.contains { $0.level == .runtime }
        let special = known.contains { $0.level == .special }
        var footer: String?
        if asks && special {
            footer = String(localized: "Android asks before granting permissions marked “Asks first”. Special access is turned on in Settings.", bundle: .greeceKit,
                            comment: "Section footer. “Asks first” and “Special access” are labels on the rows above: use the same words")
        } else if asks {
            footer = String(localized: "Android asks before granting permissions marked “Asks first”.", bundle: .greeceKit,
                            comment: "Section footer. “Asks first” is a label on the rows above: use the same words")
        } else if special {
            footer = String(localized: "Special access is turned on in Settings.", bundle: .greeceKit)
        }
        return InspectorSection("permissions", title: String(localized: "Permissions", bundle: .greeceKit, comment: "Section title"),
                                footer: footer, rows: rows, visibleLimit: 10)
    }

    static func integrations(_ package: AndroidPackage) -> [AndroidIntegration] {
        var found: [AndroidIntegration] = []
        func add(_ integration: AndroidIntegration?) {
            guard let integration, !found.contains(where: { $0.title == integration.title }) else { return }
            found.append(integration)
        }
        for component in package.services + package.receivers + package.activities {
            if let permission = component.permission { add(AndroidIntegration.forBindPermission(permission)) }
            for action in component.actions.prefix(64) { add(AndroidIntegration.forAction(action)) }
            if found.count >= 40 { break }
        }
        return found.sorted { ($0.sensitive ? 0 : 1, $0.title) < ($1.sensitive ? 0 : 1, $1.title) }
    }

    static func integrationsSection(_ package: AndroidPackage) -> InspectorSection? {
        let found = integrations(package)
        guard !found.isEmpty else { return nil }
        let rows: [InspectorRow] = found.map {
            .item(InspectorItem(symbol: $0.symbol, tint: $0.tint, title: $0.title, subtitle: $0.subtitle,
                                tone: $0.sensitive ? .caution : .neutral))
        }
        return InspectorSection("integrations", title: String(localized: "System Integrations", bundle: .greeceKit, comment: "Section title on an Android app’s page"),
                                rows: rows)
    }

    static func linksSection(_ package: AndroidPackage) -> InspectorSection? {
        guard !package.links.isEmpty else { return nil }
        let sorted = package.links.sorted { ($0.host == nil ? 0 : 1, $0.display) < ($1.host == nil ? 0 : 1, $1.display) }
        let rows: [InspectorRow] = sorted.map { link in
            let web = link.scheme == "http" || link.scheme == "https"
            let help = web
                ? String(localized: "Opens web links to this address in the app.", bundle: .greeceKit)
                : String(localized: "Opens \(link.scheme): links in the app.", bundle: .greeceKit,
                         comment: "Tooltip on a link an Android app handles. The argument is a URL scheme, such as “myapp”")
            return .item(InspectorItem(symbol: web ? "globe" : "link", tint: web ? .blue : .indigo, title: link.display,
                                       value: link.verified ? String(localized: "Verified", bundle: .greeceKit, comment: "A web link the website confirms belongs to the app") : nil,
                                       tone: link.verified ? .positive : .neutral, help: help))
        }
        let footer = package.links.contains(where: \.verified)
            ? String(localized: "Verified links open in the app without asking, once the website confirms the app.", bundle: .greeceKit) : nil
        return InspectorSection("links", title: String(localized: "Links", bundle: .greeceKit, comment: "Section title: web addresses and URL schemes an app opens"),
                                footer: footer, rows: rows, visibleLimit: 8)
    }

    static func signatureSection(_ package: AndroidPackage, now: Date) -> InspectorSection {
        let signature = package.signature
        let title = String(localized: "Signature", bundle: .greeceKit, comment: "Section title")
        var rows: [InspectorRow] = []
        guard signature.isSigned else {
            rows.append(.note(InspectorNote(symbol: "xmark.seal", text: String(localized: "This package isn’t signed. Android won’t install it until it is.", bundle: .greeceKit),
                                            tone: .critical)))
            return InspectorSection("signature", title: title, rows: rows)
        }
        if signature.isDebugCertificate {
            rows.append(.note(InspectorNote(symbol: "hammer",
                                            text: String(localized: "Signed with Android Studio’s debug certificate. It’s meant for testing, and Google Play won’t accept it.", bundle: .greeceKit),
                                            tone: .caution)))
        }
        rows.append(.item(InspectorItem(symbol: "signature", title: String(localized: "Schemes", bundle: .greeceKit, comment: "Inspector row title: the signature schemes an Android package uses"),
                                        value: signature.schemes.joined(separator: ", "), help: schemeList(signature.schemes))))
        if package.kind == .bundle {
            rows.append(.item(InspectorItem(symbol: "arrow.triangle.2.circlepath", title: String(localized: "Upload key", bundle: .greeceKit),
                                            subtitle: String(localized: "Google Play re-signs the APKs it builds from this bundle with the app signing key.", bundle: .greeceKit))))
        }
        if signature.keyRotated {
            rows.append(.item(InspectorItem(symbol: "key.horizontal", title: String(localized: "Signing key rotated", bundle: .greeceKit),
                                            subtitle: String(localized: "The app moved to a new key; older installs still accept updates.", bundle: .greeceKit), tone: .accent)))
        }
        if signature.signerCount > 1 {
            rows.append(.item(.field(String(localized: "Signers", bundle: .greeceKit, comment: "Inspector row title; its value is a count"), signature.signerCount.formatted())))
        }
        let summaries = signature.certificates.compactMap { CertificateSummary(der: $0) }
        var chain = CertificateRows.chain(summaries, now: now)
        // Android doesn't check certificate dates: an expired signing certificate still installs.
        for index in chain.indices where chain[index].tone == .critical { chain[index].tone = .neutral }
        rows += chain.map { .item($0) }
        if signature.hasSourceStamp {
            rows.append(.item(InspectorItem(symbol: "seal", title: String(localized: "Source stamp", bundle: .greeceKit, comment: "Part of an Android package’s signature"),
                                            subtitle: String(localized: "Names the store or tool that built this APK.", bundle: .greeceKit))))
        }
        return InspectorSection("signature", title: title, rows: rows)
    }

    static func componentsSection(_ package: AndroidPackage) -> InspectorSection? {
        let groups: [(String, String, [AndroidPackage.Component])] = [
            (String(localized: "Activities", bundle: .greeceKit, comment: "Android app components: its screens"), "macwindow", package.activities),
            (String(localized: "Services", bundle: .greeceKit, comment: "Android app components that run in the background"), "gearshape.2", package.services),
            (String(localized: "Broadcast receivers", bundle: .greeceKit, comment: "Android app components"), "dot.radiowaves.up.forward", package.receivers),
            (String(localized: "Content providers", bundle: .greeceKit, comment: "Android app components"), "tray.full", package.providers),
        ]
        var rows: [InspectorRow] = []
        if let launcher = package.launcherActivity {
            rows.append(.item(InspectorItem(symbol: "play.circle", title: String(localized: "Opens with", bundle: .greeceKit, comment: "Inspector row title; its value is the screen an Android app starts on"),
                                            value: simpleName(launcher), help: launcher, mono: true)))
        }
        for (title, symbol, components) in groups where !components.isEmpty {
            let exported = components.filter(\.exported).count
            let details = components.prefix(200).map { component in
                InspectorItem(title: simpleName(component.name),
                              value: component.exported ? String(localized: "Exported", bundle: .greeceKit, comment: "An Android component other apps can use") : nil,
                              help: component.name, mono: true)
            }
            rows.append(.item(InspectorItem(symbol: symbol, title: title,
                                            subtitle: exported > 0 ? String(localized: "\(exported) open to other apps", bundle: .greeceKit,
                                                                            comment: "Under a kind of Android component. The argument is how many other apps can use") : nil,
                                            value: components.count.formatted(), details: details)))
        }
        guard !rows.isEmpty else { return nil }
        return InspectorSection("components", title: String(localized: "Components", bundle: .greeceKit, comment: "Section title: an Android app’s activities, services and so on"),
                                rows: rows)
    }

    private static func simpleName(_ name: String) -> String {
        guard let last = name.split(separator: ".").last, !last.isEmpty else { return name }
        return String(last)
    }

    static func architecturesSection(_ package: AndroidPackage) -> InspectorSection? {
        guard !package.abis.isEmpty else { return nil }
        let names = ["arm64-v8a": String(localized: "64-bit ARM", bundle: .greeceKit), "armeabi-v7a": String(localized: "32-bit ARM", bundle: .greeceKit),
                     "armeabi": "ARMv5", "x86_64": String(localized: "64-bit x86", bundle: .greeceKit), "x86": String(localized: "32-bit x86", bundle: .greeceKit),
                     "riscv64": String(localized: "64-bit RISC-V", bundle: .greeceKit), "mips": "MIPS", "mips64": String(localized: "64-bit MIPS", bundle: .greeceKit)]
        let rows: [InspectorRow] = package.abis.map { abi in
            .item(InspectorItem(symbol: "cpu", title: names[abi.name] ?? abi.name, subtitle: abi.name, value: Format.bytes(abi.bytes), help: abi.name))
        }
        let footer = package.nativeLibraries.isEmpty ? nil
            : String(localized: "\(package.nativeLibraries.count) native libraries", bundle: .greeceKit, comment: "Section footer. The argument is a count")
        return InspectorSection("architectures", title: String(localized: "Architectures", bundle: .greeceKit, comment: "Section title: processor architectures"),
                                footer: footer, rows: rows)
    }

    static func builtWithSection(_ package: AndroidPackage) -> InspectorSection? {
        var rows: [InspectorRow] = package.frameworks.map {
            .item(InspectorItem(symbol: "square.stack.3d.up", tint: .indigo, title: $0))
        }
        rows += package.sdks.map { .item(InspectorItem(symbol: "puzzlepiece.extension", tint: .gray, title: $0)) }
        guard !rows.isEmpty else { return nil }
        return InspectorSection("builtWith", title: String(localized: "Built With", bundle: .greeceKit, comment: "Section title: the toolkits and SDKs an app uses"), rows: rows)
    }

    static func sizeSection(_ package: AndroidPackage) -> InspectorSection? {
        guard package.sizes.total > 0, !package.sizes.segments.isEmpty else { return nil }
        let footer = package.kind == .bundle
            ? String(localized: "Uncompressed sizes. Google Play delivers each device only the parts it needs.", bundle: .greeceKit)
            : String(localized: "Uncompressed sizes inside the package.", bundle: .greeceKit)
        return InspectorSection("size", title: String(localized: "Size", bundle: .greeceKit, comment: "Section title"), footer: footer, rows: [.sizes(package.sizes)])
    }

    static func infoSection(_ package: AndroidPackage) -> InspectorSection {
        var items: [InspectorItem] = []
        if let name = package.package { items.append(.field(String(localized: "Package", bundle: .greeceKit, comment: "Inspector row title: an Android package name"), name, mono: true)) }
        if let version = package.versionName { items.append(.field(String(localized: "Version", bundle: .greeceKit, comment: "Inspector row title"), version)) }
        if let code = package.versionCode { items.append(.field(String(localized: "Version code", bundle: .greeceKit, comment: "Inspector row title: an Android app’s internal version number"), code, mono: true)) }
        if let minSdk = package.minSdk {
            items.append(.field(String(localized: "Requires", bundle: .greeceKit, comment: "Inspector row title; its value is the oldest system version the app runs on"),
                                AndroidVersions.describe(minSdk)))
        }
        if let target = package.targetSdk {
            items.append(.field(String(localized: "Targets", bundle: .greeceKit, comment: "Inspector row title; its value is the Android version the app is designed for"),
                                AndroidVersions.describe(target)))
        }
        if let compile = package.compileSdk {
            items.append(.field(String(localized: "Compiled with", bundle: .greeceKit, comment: "Inspector row title; its value is an Android SDK version"),
                                AndroidVersions.describe(compile)))
        }
        // Translations plus the default language, as aapt counts them.
        if package.locales > 0 {
            items.append(.field(String(localized: "Languages", bundle: .greeceKit, comment: "Inspector row title; its value is a count"), (package.locales + 1).formatted()))
        }
        if !package.features.isEmpty {
            let required = package.features.filter(\.required)
            let value = required.isEmpty
                ? String(localized: "None required", bundle: .greeceKit, comment: "Hardware features an Android app needs")
                : String(localized: "\(required.count) required", bundle: .greeceKit, comment: "Hardware features an Android app needs. The argument is a count")
            items.append(InspectorItem(title: String(localized: "Hardware features", bundle: .greeceKit), value: value,
                                       details: package.features.prefix(200).map {
                                           InspectorItem.field($0.name, $0.required ? String(localized: "Required", bundle: .greeceKit, comment: "A hardware feature or setting that is needed")
                                                                                    : String(localized: "Optional", bundle: .greeceKit, comment: "A hardware feature an Android app can use but doesn’t need"),
                                                               mono: false)
                                       }))
        }
        if let app = package.applicationClass, app != "android.app.Application" {
            items.append(InspectorItem(title: String(localized: "Application class", bundle: .greeceKit, comment: "Inspector row title: an Android app’s custom Application subclass"),
                                       value: simpleName(app), help: app, mono: true))
        }
        let allowed = String(localized: "Allowed", bundle: .greeceKit, comment: "Inspector row value: a setting that permits something")
        let cleartext: (String, InspectorTone)
        if package.hasNetworkSecurityConfig {
            cleartext = (String(localized: "Set by network security config", bundle: .greeceKit), .neutral)
        } else if package.usesCleartextTraffic ?? ((package.targetSdk ?? 1) < 28) {
            cleartext = (allowed, .caution)
        } else {
            cleartext = (String(localized: "Blocked", bundle: .greeceKit, comment: "Inspector row value: plain HTTP connections aren’t allowed"), .neutral)
        }
        items.append(.field(String(localized: "Unencrypted HTTP", bundle: .greeceKit, comment: "Inspector row title"), cleartext.0, tone: cleartext.1,
                            help: String(localized: "Whether the app may use plain HTTP connections.", bundle: .greeceKit)))
        items.append(.field(String(localized: "Backups", bundle: .greeceKit, comment: "Inspector row title"),
                            package.allowBackup ?? true ? allowed : String(localized: "Off", bundle: .greeceKit, comment: "The state of a setting or feature"),
                            help: String(localized: "Whether Android backs up the app’s data.", bundle: .greeceKit)))
        if package.requestLegacyExternalStorage {
            items.append(.field(String(localized: "Storage", bundle: .greeceKit, comment: "Inspector row title"), String(localized: "Legacy shared storage", bundle: .greeceKit)))
        }
        if package.largeHeap {
            items.append(.field(String(localized: "Memory", bundle: .greeceKit, comment: "Inspector row title"), String(localized: "Large heap", bundle: .greeceKit, comment: "An Android app that asks for more memory")))
        }
        if package.dexCount > 0 {
            items.append(.field(String(localized: "DEX files", bundle: .greeceKit, comment: "Inspector row title; its value is a count of Android code files"), package.dexCount.formatted()))
        }
        if package.kind == .bundle {
            items.append(.field(String(localized: "Modules", bundle: .greeceKit, comment: "Inspector row title: an Android App Bundle’s feature modules"),
                                (["base"] + package.modules).joined(separator: ", ")))
            if let version = package.bundletoolVersion, !version.isEmpty { items.append(.field("Bundletool", version, mono: true)) }
        }
        items.append(.field(String(localized: "Files", bundle: .greeceKit, comment: "Inspector row title; its value is a count"), package.memberCount.formatted()))
        return InspectorSection("info", title: String(localized: "Info", bundle: .greeceKit, comment: "Section title"), rows: .items(items))
    }
}
