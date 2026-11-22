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
            page.contents = .tree(FileNode.tree(from: listing, showHidden: settings.showHiddenFiles), title: "Files", count: listing.fileCount,
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
        return FileSummary(symbol: "shippingbox", title: package.kind == .apk ? "Android App" : "Android App Bundle",
                           details: details, trailing: modified)
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
            badges.append(InspectorBadge("framework", symbol: "square.stack.3d.up", title: toolkit, help: "Built with \(toolkit)."))
        }

        let abis = package.abis.map(\.name)
        if abis.isEmpty {
            badges.append(InspectorBadge("architectures", symbol: "cpu", title: "Any Architecture",
                                         help: "No native code: it runs on every Android processor."))
        } else {
            let hasARM = abis.contains { $0.hasPrefix("arm") }
            let hasX86 = abis.contains { $0.hasPrefix("x86") }
            let title: String
            if abis.count >= 4 || (hasARM && hasX86 && abis.count >= 3) {
                title = "Universal"
            } else {
                title = abis.map(shortABI).joined(separator: ", ") + (abis.count == 1 ? " only" : "")
            }
            let tone: InspectorTone = hasARM ? .neutral : .caution
            let help = hasARM ? "Native code for " + abis.joined(separator: ", ") + "."
                              : "Native code only for x86. Most Android phones use ARM processors and can’t run it."
            badges.append(InspectorBadge("architectures", symbol: "cpu", title: title, tone: tone, help: help))
        }

        let signature = package.signature
        if !signature.isSigned {
            badges.append(InspectorBadge("signer", symbol: "xmark.seal", title: "Unsigned", tone: .critical,
                                         help: "Not signed. Android refuses to install unsigned packages."))
        } else if signature.isDebugCertificate {
            badges.append(InspectorBadge("signer", symbol: "hammer", title: "Debug Certificate", tone: .caution,
                                         help: "Signed with Android Studio’s debug key. Google Play doesn’t accept it."))
        } else {
            badges.append(InspectorBadge("signer", symbol: "checkmark.seal", title: "Signed", tone: .positive,
                                         help: "Signed with " + schemeList(signature.schemes) + "."))
        }
        if signature.hasPlayMetadata {
            badges.append(InspectorBadge("store", symbol: "bag", title: "Google Play", tone: .positive,
                                         help: "Includes the metadata Google Play adds to the apps it delivers."))
        }
        if package.debuggable {
            badges.append(InspectorBadge("debuggable", symbol: "ant", title: "Debuggable", tone: .caution,
                                         help: "Any debugger can attach to it and read its data."))
        }
        if package.testOnly {
            badges.append(InspectorBadge("testOnly", symbol: "testtube.2", title: "Test Only", tone: .caution,
                                         help: "Marked for testing: it installs only through developer tools."))
        }
        return badges
    }

    private static func schemeList(_ schemes: [String]) -> String {
        let names = schemes.map { scheme -> String in
            scheme.hasPrefix("v1") ? "JAR signing (v1)" : "APK Signature Scheme \(scheme)"
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
            case .runtime: value = "Asks first"
            case .special: value = "Special access"
            case .system: value = "System only"
            }
            return .item(InspectorItem(symbol: permission.symbol, tint: permission.tint, title: permission.title, value: value,
                                       tone: permission.sensitive ? .caution : .neutral, help: permission.name))
        }
        if !custom.isEmpty {
            rows.append(.item(InspectorItem(symbol: "key", tint: .gray, title: "Custom permissions", value: custom.count.formatted(),
                                            help: "Permissions defined by apps rather than by Android.",
                                            details: custom.prefix(200).map { InspectorItem.field($0, nil, mono: true) })))
        }
        guard !rows.isEmpty else { return nil }
        let asks = known.contains { $0.level == .runtime }
        let special = known.contains { $0.level == .special }
        var footer: String?
        if asks && special {
            footer = "Android asks before granting permissions marked “Asks first”. Special access is turned on in Settings."
        } else if asks {
            footer = "Android asks before granting permissions marked “Asks first”."
        } else if special {
            footer = "Special access is turned on in Settings."
        }
        return InspectorSection("permissions", title: "Permissions", footer: footer, rows: rows, visibleLimit: 10)
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
        return InspectorSection("integrations", title: "System Integrations", rows: rows)
    }

    static func linksSection(_ package: AndroidPackage) -> InspectorSection? {
        guard !package.links.isEmpty else { return nil }
        let sorted = package.links.sorted { ($0.host == nil ? 0 : 1, $0.display) < ($1.host == nil ? 0 : 1, $1.display) }
        let rows: [InspectorRow] = sorted.map { link in
            let web = link.scheme == "http" || link.scheme == "https"
            return .item(InspectorItem(symbol: web ? "globe" : "link", tint: web ? .blue : .indigo, title: link.display,
                                       value: link.verified ? "Verified" : nil, tone: link.verified ? .positive : .neutral,
                                       help: web ? "Opens web links to this address in the app." : "Opens \(link.scheme): links in the app."))
        }
        let footer = package.links.contains(where: \.verified)
            ? "Verified links open in the app without asking, once the website confirms the app." : nil
        return InspectorSection("links", title: "Links", footer: footer, rows: rows, visibleLimit: 8)
    }

    static func signatureSection(_ package: AndroidPackage, now: Date) -> InspectorSection {
        let signature = package.signature
        var rows: [InspectorRow] = []
        guard signature.isSigned else {
            rows.append(.note(InspectorNote(symbol: "xmark.seal", text: "This package isn’t signed. Android won’t install it until it is.", tone: .critical)))
            return InspectorSection("signature", title: "Signature", rows: rows)
        }
        if signature.isDebugCertificate {
            rows.append(.note(InspectorNote(symbol: "hammer", text: "Signed with Android Studio’s debug certificate. It’s meant for testing, and Google Play won’t accept it.", tone: .caution)))
        }
        rows.append(.item(InspectorItem(symbol: "signature", title: "Schemes", value: signature.schemes.joined(separator: ", "),
                                        help: schemeList(signature.schemes))))
        if package.kind == .bundle {
            rows.append(.item(InspectorItem(symbol: "arrow.triangle.2.circlepath", title: "Upload key",
                                            subtitle: "Google Play re-signs the APKs it builds from this bundle with the app signing key.")))
        }
        if signature.keyRotated {
            rows.append(.item(InspectorItem(symbol: "key.horizontal", title: "Signing key rotated",
                                            subtitle: "The app moved to a new key; older installs still accept updates.", tone: .accent)))
        }
        if signature.signerCount > 1 {
            rows.append(.item(.field("Signers", signature.signerCount.formatted())))
        }
        let summaries = signature.certificates.compactMap { CertificateSummary(der: $0) }
        var chain = CertificateRows.chain(summaries, now: now)
        // Android doesn't check certificate dates: an expired signing certificate still installs.
        for index in chain.indices where chain[index].tone == .critical { chain[index].tone = .neutral }
        rows += chain.map { .item($0) }
        if signature.hasSourceStamp {
            rows.append(.item(InspectorItem(symbol: "seal", title: "Source stamp", subtitle: "Names the store or tool that built this APK.")))
        }
        return InspectorSection("signature", title: "Signature", rows: rows)
    }

    static func componentsSection(_ package: AndroidPackage) -> InspectorSection? {
        let groups: [(String, String, [AndroidPackage.Component])] = [
            ("Activities", "macwindow", package.activities),
            ("Services", "gearshape.2", package.services),
            ("Broadcast receivers", "dot.radiowaves.up.forward", package.receivers),
            ("Content providers", "tray.full", package.providers),
        ]
        var rows: [InspectorRow] = []
        if let launcher = package.launcherActivity {
            rows.append(.item(InspectorItem(symbol: "play.circle", title: "Opens with", value: simpleName(launcher), help: launcher, mono: true)))
        }
        for (title, symbol, components) in groups where !components.isEmpty {
            let exported = components.filter(\.exported).count
            let details = components.prefix(200).map { component in
                InspectorItem(title: simpleName(component.name), value: component.exported ? "Exported" : nil, help: component.name, mono: true)
            }
            rows.append(.item(InspectorItem(symbol: symbol, title: title,
                                            subtitle: exported > 0 ? "\(exported.formatted()) open to other apps" : nil,
                                            value: components.count.formatted(), details: details)))
        }
        guard !rows.isEmpty else { return nil }
        return InspectorSection("components", title: "Components", rows: rows)
    }

    private static func simpleName(_ name: String) -> String {
        guard let last = name.split(separator: ".").last, !last.isEmpty else { return name }
        return String(last)
    }

    static func architecturesSection(_ package: AndroidPackage) -> InspectorSection? {
        guard !package.abis.isEmpty else { return nil }
        let names = ["arm64-v8a": "64-bit ARM", "armeabi-v7a": "32-bit ARM", "armeabi": "ARMv5", "x86_64": "64-bit x86",
                     "x86": "32-bit x86", "riscv64": "64-bit RISC-V", "mips": "MIPS", "mips64": "64-bit MIPS"]
        let rows: [InspectorRow] = package.abis.map { abi in
            .item(InspectorItem(symbol: "cpu", title: names[abi.name] ?? abi.name, subtitle: abi.name, value: Format.bytes(abi.bytes), help: abi.name))
        }
        let footer = package.nativeLibraries.isEmpty ? nil : Format.count(package.nativeLibraries.count, "native library", "native libraries")
        return InspectorSection("architectures", title: "Architectures", footer: footer, rows: rows)
    }

    static func builtWithSection(_ package: AndroidPackage) -> InspectorSection? {
        var rows: [InspectorRow] = package.frameworks.map {
            .item(InspectorItem(symbol: "square.stack.3d.up", tint: .indigo, title: $0))
        }
        rows += package.sdks.map { .item(InspectorItem(symbol: "puzzlepiece.extension", tint: .gray, title: $0)) }
        guard !rows.isEmpty else { return nil }
        return InspectorSection("builtWith", title: "Built With", rows: rows)
    }

    static func sizeSection(_ package: AndroidPackage) -> InspectorSection? {
        guard package.sizes.total > 0, !package.sizes.segments.isEmpty else { return nil }
        let footer = package.kind == .bundle
            ? "Uncompressed sizes. Google Play delivers each device only the parts it needs."
            : "Uncompressed sizes inside the package."
        return InspectorSection("size", title: "Size", footer: footer, rows: [.sizes(package.sizes)])
    }

    static func infoSection(_ package: AndroidPackage) -> InspectorSection {
        var items: [InspectorItem] = []
        if let name = package.package { items.append(.field("Package", name, mono: true)) }
        if let version = package.versionName { items.append(.field("Version", version)) }
        if let code = package.versionCode { items.append(.field("Version code", code, mono: true)) }
        if let minSdk = package.minSdk { items.append(.field("Requires", AndroidVersions.describe(minSdk))) }
        if let target = package.targetSdk { items.append(.field("Targets", AndroidVersions.describe(target))) }
        if let compile = package.compileSdk { items.append(.field("Compiled with", AndroidVersions.describe(compile))) }
        // Translations plus the default language, as aapt counts them.
        if package.locales > 0 { items.append(.field("Languages", (package.locales + 1).formatted())) }
        if !package.features.isEmpty {
            let required = package.features.filter(\.required)
            items.append(InspectorItem(title: "Hardware features", value: required.isEmpty ? "None required" : Format.count(required.count, "required"),
                                       details: package.features.prefix(200).map {
                                           InspectorItem.field($0.name, $0.required ? "Required" : "Optional", mono: false)
                                       }))
        }
        if let app = package.applicationClass, app != "android.app.Application" {
            items.append(InspectorItem(title: "Application class", value: simpleName(app), help: app, mono: true))
        }
        let cleartext: (String, InspectorTone)
        if package.hasNetworkSecurityConfig {
            cleartext = ("Set by network security config", .neutral)
        } else if package.usesCleartextTraffic ?? ((package.targetSdk ?? 1) < 28) {
            cleartext = ("Allowed", .caution)
        } else {
            cleartext = ("Blocked", .neutral)
        }
        items.append(.field("Unencrypted HTTP", cleartext.0, tone: cleartext.1,
                            help: "Whether the app may use plain HTTP connections."))
        items.append(.field("Backups", package.allowBackup ?? true ? "Allowed" : "Off",
                            help: "Whether Android backs up the app’s data."))
        if package.requestLegacyExternalStorage { items.append(.field("Storage", "Legacy shared storage")) }
        if package.largeHeap { items.append(.field("Memory", "Large heap")) }
        if package.dexCount > 0 { items.append(.field("DEX files", package.dexCount.formatted())) }
        if package.kind == .bundle {
            items.append(.field("Modules", (["base"] + package.modules).joined(separator: ", ")))
            if let version = package.bundletoolVersion, !version.isEmpty { items.append(.field("Bundletool", version, mono: true)) }
        }
        items.append(.field("Files", package.memberCount.formatted()))
        return InspectorSection("info", title: "Info", rows: .items(items))
    }
}
