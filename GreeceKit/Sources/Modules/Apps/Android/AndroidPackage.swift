import AppKit

/// Everything Greece reads from an .apk or .aab, without installing or running it.
struct AndroidPackage {
    enum Kind { case apk, bundle }

    struct Component {
        var name: String
        var exported: Bool
        var permission: String?
        var actions: [String]
    }

    struct Link: Equatable {
        var scheme: String
        var host: String?
        var path: String?
        var verified: Bool
        var display: String {
            guard let host, !host.isEmpty else { return scheme + ":" }
            return scheme + "://" + host + (path ?? "")
        }
    }

    struct Feature: Equatable {
        var name: String
        var required: Bool
    }

    var kind: Kind
    var package: String?
    var versionName: String?
    var versionCode: String?
    var minSdk: Int?
    var targetSdk: Int?
    var compileSdk: Int?
    var label: String?
    var permissions: [String] = []
    /// Permissions the app defines for others (often its own internal ones).
    var definedPermissions: [String] = []
    var features: [Feature] = []
    var activities: [Component] = []
    var services: [Component] = []
    var receivers: [Component] = []
    var providers: [Component] = []
    var launcherActivity: String?
    var links: [Link] = []
    var applicationClass: String?
    var debuggable = false
    var testOnly = false
    var allowBackup: Bool?
    var usesCleartextTraffic: Bool?
    var hasNetworkSecurityConfig = false
    var requestLegacyExternalStorage = false
    var largeHeap = false
    var metaDataNames: [String] = []

    /// ABI -> uncompressed bytes of its native libraries.
    var abis: [(name: String, bytes: UInt64)] = []
    var nativeLibraries: Set<String> = []
    var dexCount = 0
    var frameworks: [String] = []
    var sdks: [String] = []
    var locales: Int = 0
    var sizes = InspectorSizes(total: 0, segments: [])
    var signature = AndroidSignature()
    /// Bundle feature modules other than base, and bundletool's version.
    var modules: [String] = []
    var bundletoolVersion: String?
    var fileSize: UInt64 = 0
    var memberCount = 0

    var icon: NSImage?
    var listing: ArchiveListing?
}

enum AndroidPackageError: LocalizedError {
    case noManifest
    var errorDescription: String? { "This Android package has no readable manifest." }
}

enum AndroidPackageReader {
    static let readBudget: TimeInterval = 1.5

    static func read(_ url: URL, includeIcon: Bool = true, includeListing: Bool = true) throws -> AndroidPackage {
        let deadline = Date().addingTimeInterval(readBudget)
        let zip = try ZIPArchive(url: url)
        let isBundle = zip.member("base/manifest/AndroidManifest.xml") != nil && zip.member("AndroidManifest.xml") == nil
        let prefix = isBundle ? "base/" : ""
        var package = AndroidPackage(kind: isBundle ? .bundle : .apk)
        package.fileSize = zip.size
        package.memberCount = zip.members.lazy.filter { !$0.isDirectory }.count

        // Manifest
        let manifestPath = isBundle ? "base/manifest/AndroidManifest.xml" : "AndroidManifest.xml"
        guard let manifestMember = zip.member(manifestPath),
              let manifestData = try? zip.contents(of: manifestMember, limit: 8 << 20) else { throw AndroidPackageError.noManifest }
        let manifest = isBundle ? try AndroidProtoXML.parse(manifestData, deadline: deadline)
                                : try AndroidBinaryXML.parse(manifestData, deadline: deadline)
        guard manifest.name == "manifest" else { throw AndroidPackageError.noManifest }

        // Resources (for the label and icon)
        var resources: AndroidResourceTable?
        let resourcePath = isBundle ? "base/resources.pb" : "resources.arsc"
        if let data = zip.contents(of: resourcePath, limit: 48 << 20) {
            resources = isBundle ? try? AndroidProtoResources(data: data, deadline: deadline)
                                 : try? AndroidBinaryResources(data: data, deadline: deadline)
        }
        package.locales = resources?.locales.count ?? 0

        apply(manifest, to: &package, resources: resources)
        if includeIcon {
            package.icon = AndroidIcon.image(manifest: manifest, resources: resources, zip: zip, prefix: prefix, deadline: deadline)
        }

        if isBundle {
            package.modules = Set(zip.members.compactMap { member -> String? in
                guard member.path.hasSuffix("/manifest/AndroidManifest.xml") else { return nil }
                let module = String(member.path.dropLast("/manifest/AndroidManifest.xml".count))
                return module == "base" || module.contains("/") ? nil : module
            }).sorted()
            if let config = zip.contents(of: "BundleConfig.pb", limit: 1 << 20), let message = ProtoMessage(config) {
                package.bundletoolVersion = message.message(1)?.string(2)
            }
        }

        inspectMembers(zip, into: &package, prefix: prefix)
        package.signature = AndroidSigning.signature(of: zip)

        if includeListing {
            let entries = zip.members.prefix(ArchiveReader.entryLimit).map { member in
                ArchiveEntry(path: member.path, isDirectory: member.isDirectory, size: member.size, compressedSize: member.compressedSize)
            }
            package.listing = ArchiveListing(format: .zip, container: .zip, entries: Array(entries), archiveSize: package.fileSize,
                                             truncated: zip.truncated)
        }
        return package
    }

    // MARK: Manifest

    static func apply(_ manifest: AndroidXMLElement, to package: inout AndroidPackage, resources: AndroidResourceTable?) {
        func plain(_ value: AndroidValue?) -> String? {
            guard let value else { return nil }
            if case .reference(let id) = value { return resources?.string(for: id) }
            return value.string.map { Format.clean($0, limit: 200) }
        }
        // `package` is a plain (namespace-less) attribute.
        package.package = manifest.attributes.first { $0.name == "package" }?.value.string.map { Format.clean($0, limit: 200) }
        package.versionName = plain(manifest.attribute("versionName"))
        if let code = manifest.attribute("versionCode") { package.versionCode = code.int.map(String.init) ?? plain(code) }
        package.compileSdk = manifest.attribute("compileSdkVersion")?.int
            ?? manifest.attributes.first { $0.name == "platformBuildVersionCode" }?.value.int

        if let sdk = manifest.children(named: "uses-sdk").first {
            package.minSdk = sdk.attribute("minSdkVersion")?.int
            package.targetSdk = sdk.attribute("targetSdkVersion")?.int
        }
        let target = package.targetSdk ?? package.minSdk ?? 1

        var permissions: [String] = []
        for element in manifest.children where element.name.hasPrefix("uses-permission") {
            if let name = element.string("name").map({ Format.clean($0, limit: 200) }), !name.isEmpty, !permissions.contains(name) {
                permissions.append(name)
            }
            if permissions.count >= 1_000 { break }
        }
        package.permissions = permissions
        package.definedPermissions = manifest.children(named: "permission").prefix(500).compactMap { $0.string("name") }
            .map { Format.clean($0, limit: 200) }
        package.features = manifest.children(named: "uses-feature").prefix(500).compactMap { element in
            guard let name = element.string("name").map({ Format.clean($0, limit: 200) }), !name.isEmpty else {
                // OpenGL ES requirements have no name, only a version.
                return element.attribute("glEsVersion")?.int.map {
                    AndroidPackage.Feature(name: "OpenGL ES \($0 >> 16).\($0 & 0xFFFF)", required: element.attribute("required")?.bool ?? true)
                }
            }
            return AndroidPackage.Feature(name: name, required: element.attribute("required")?.bool ?? true)
        }

        guard let application = manifest.children(named: "application").first else { return }
        package.label = plain(application.attribute("label"))
        package.applicationClass = application.string("name").map { name in
            name.hasPrefix(".") ? (package.package ?? "") + name : name
        }
        package.debuggable = application.attribute("debuggable")?.bool ?? false
        package.testOnly = application.attribute("testOnly")?.bool ?? false
        package.allowBackup = application.attribute("allowBackup")?.bool
        package.usesCleartextTraffic = application.attribute("usesCleartextTraffic")?.bool
        package.hasNetworkSecurityConfig = application.attribute("networkSecurityConfig") != nil
        package.requestLegacyExternalStorage = application.attribute("requestLegacyExternalStorage")?.bool ?? false
        package.largeHeap = application.attribute("largeHeap")?.bool ?? false
        package.metaDataNames = application.children(named: "meta-data").prefix(500).compactMap { $0.string("name") }

        var links: [AndroidPackage.Link] = []
        /// ".Main" and "Main" are relative to the package.
        let packageName = package.package ?? ""
        func qualified(_ name: String?) -> String? {
            guard let name = name.map({ Format.clean($0, limit: 300) }), !name.isEmpty else { return nil }
            if name.hasPrefix(".") { return packageName + name }
            if !name.contains("."), !packageName.isEmpty { return packageName + "." + name }
            return name
        }
        func component(_ element: AndroidXMLElement, defaultExported: Bool) -> AndroidPackage.Component {
            let filters = element.children(named: "intent-filter")
            var actions: [String] = []
            for filter in filters.prefix(64) {
                let filterActions = filter.children(named: "action").compactMap { $0.string("name") }
                actions += filterActions
                let categories = filter.children(named: "category").compactMap { $0.string("name") }
                if filterActions.contains("android.intent.action.VIEW"), categories.contains("android.intent.category.BROWSABLE") {
                    let verified = filter.attribute("autoVerify")?.bool ?? false
                    let data = filter.children(named: "data")
                    let schemes = data.compactMap { $0.string("scheme") }.map { Format.clean($0, limit: 60) }.filter { !$0.isEmpty }
                    let hosts = data.compactMap { $0.string("host") }.map { Format.clean($0, limit: 200) }.filter { !$0.isEmpty }
                    let paths = data.compactMap { $0.string("path") ?? $0.string("pathPrefix") ?? $0.string("pathPattern") }
                        .map { Format.clean($0, limit: 200) }
                    for scheme in Set(schemes).sorted() where links.count < 200 {
                        if hosts.isEmpty {
                            links.append(.init(scheme: scheme, host: nil, path: nil, verified: false))
                        } else {
                            for host in Set(hosts).sorted() where links.count < 200 {
                                links.append(.init(scheme: scheme, host: host, path: paths.first, verified: verified && scheme.hasPrefix("http")))
                            }
                        }
                    }
                }
                if filterActions.contains("android.intent.action.MAIN"), categories.contains("android.intent.category.LAUNCHER"),
                   package.launcherActivity == nil {
                    package.launcherActivity = qualified(element.string("name"))
                }
            }
            let exported = element.attribute("exported")?.bool ?? (defaultExported && (!filters.isEmpty || element.name == "provider"))
            return AndroidPackage.Component(name: qualified(element.string("name")) ?? "", exported: exported,
                                            permission: element.string("permission"), actions: actions)
        }
        // Before Android 12, components with intent filters were exported unless they said otherwise.
        let implicitExport = target < 31
        for element in application.children.prefix(20_000) {
            switch element.name {
            case "activity", "activity-alias": package.activities.append(component(element, defaultExported: implicitExport))
            case "service": package.services.append(component(element, defaultExported: implicitExport))
            case "receiver": package.receivers.append(component(element, defaultExported: implicitExport))
            case "provider": package.providers.append(component(element, defaultExported: target < 17))
            default: break
            }
        }
        // De-duplicate links, keeping verified ones.
        var seen: [String: Int] = [:]
        for link in links {
            if let index = seen[link.display] {
                if link.verified { package.links[index].verified = true }
            } else {
                seen[link.display] = package.links.count
                package.links.append(link)
            }
        }
    }

    // MARK: Members

    static func inspectMembers(_ zip: ZIPArchive, into package: inout AndroidPackage, prefix: String) {
        var code: UInt64 = 0, native: UInt64 = 0, resources: UInt64 = 0, assets: UInt64 = 0, other: UInt64 = 0
        var abiSizes: [String: UInt64] = [:]
        var names = Set<String>()
        var metaInfVersions = Set<String>()
        var properties = Set<String>()
        var hasFlutterAssets = false, hasReactBundle = false, hasUnityData = false, hasKotlin = false, hasXamarinAssemblies = false
        var hasCordova = false, hasCapacitor = false

        for member in zip.members where !member.isDirectory {
            var path = member.path
            if !prefix.isEmpty {
                // Bundles: every module's files count; strip the module directory for classification.
                if let slash = path.firstIndex(of: "/"), !path.hasPrefix("META-INF/"), !path.hasPrefix("BUNDLE-METADATA/") {
                    path = String(path[path.index(after: slash)...])
                }
                if path.hasPrefix("dex/") { path = String(path.dropFirst(4)) }
                if path.hasPrefix("root/") { path = String(path.dropFirst(5)) }
            }
            let size = member.size
            let lower = path.lowercased()
            if lower.hasSuffix(".dex") && !lower.contains("/") || lower.hasPrefix("classes") && lower.hasSuffix(".dex") {
                package.dexCount += 1
                code = code.saturatingAdd(size)
            } else if lower.hasPrefix("lib/") {
                native = native.saturatingAdd(size)
                let parts = path.split(separator: "/")
                if parts.count >= 3 {
                    abiSizes[String(parts[1]), default: 0] = (abiSizes[String(parts[1])] ?? 0).saturatingAdd(size)
                    if names.count < 2_000 { names.insert(String(parts.last!)) }
                }
            } else if lower.hasPrefix("res/") || lower == "resources.arsc" || lower == "resources.pb" {
                resources = resources.saturatingAdd(size)
            } else if lower.hasPrefix("assets/") {
                assets = assets.saturatingAdd(size)
                if lower.hasPrefix("assets/flutter_assets/") { hasFlutterAssets = true }
                if lower == "assets/index.android.bundle" { hasReactBundle = true }
                if lower.hasPrefix("assets/bin/data/") { hasUnityData = true }
                if lower == "assets/www/cordova.js" { hasCordova = true }
                if lower == "assets/capacitor.config.json" { hasCapacitor = true }
            } else {
                other = other.saturatingAdd(size)
                if lower.hasPrefix("kotlin/") || lower.hasSuffix(".kotlin_module") || lower.hasSuffix("debugprobeskt.bin") { hasKotlin = true }
                if lower.hasPrefix("assemblies/") || lower.hasSuffix(".dll") { hasXamarinAssemblies = true }
                if lower.hasPrefix("meta-inf/"), lower.hasSuffix(".version"), metaInfVersions.count < 2_000 {
                    metaInfVersions.insert(String(lower.dropFirst("meta-inf/".count).dropLast(".version".count)))
                }
                if !lower.contains("/"), lower.hasSuffix(".properties"), properties.count < 2_000 {
                    properties.insert(String(lower.dropLast(".properties".count)))
                }
            }
        }
        package.nativeLibraries = names
        let abiOrder = ["arm64-v8a", "armeabi-v7a", "armeabi", "x86_64", "x86", "riscv64", "mips64", "mips"]
        package.abis = abiSizes.sorted { (abiOrder.firstIndex(of: $0.key) ?? 99, $0.key) < (abiOrder.firstIndex(of: $1.key) ?? 99, $1.key) }
            .map { (name: $0.key, bytes: $0.value) }

        // Frameworks: the toolkit the app is built with.
        var frameworks: [String] = []
        func has(_ library: String) -> Bool { names.contains(library) }
        if has("libflutter.so") || hasFlutterAssets { frameworks.append("Flutter") }
        if has("libreactnativejni.so") || has("libreactnative.so") || hasReactBundle {
            frameworks.append(has("libhermes.so") || has("libhermes_executor.so") ? "React Native (Hermes)" : "React Native")
        }
        if has("libunity.so") || hasUnityData { frameworks.append(has("libil2cpp.so") ? "Unity (IL2CPP)" : "Unity") }
        if has("libmonodroid.so") || has("libmonosgen-2.0.so") || hasXamarinAssemblies {
            frameworks.append(has("libxamarin-app.so") && names.contains(where: { $0.hasPrefix("libSystem.") }) ? ".NET MAUI" : "Xamarin / .NET")
        }
        if has("libgodot_android.so") { frameworks.append("Godot") }
        if has("libUE4.so") || has("libUnreal.so") { frameworks.append("Unreal Engine") }
        if names.contains(where: { $0.hasPrefix("libQt5Core") || $0.hasPrefix("libQt6Core") }) { frameworks.append("Qt") }
        if hasCapacitor { frameworks.append("Capacitor") } else if hasCordova { frameworks.append("Cordova") }
        if metaInfVersions.contains(where: { $0.hasPrefix("androidx.compose.") }) { frameworks.append("Jetpack Compose") }
        if hasKotlin || metaInfVersions.contains(where: { $0.contains("kotlin") }) { frameworks.append("Kotlin") }
        package.frameworks = frameworks

        package.sdks = AndroidSDKs.detect(package: package, properties: properties, libraries: names)

        let total = code.saturatingAdd(native).saturatingAdd(resources).saturatingAdd(assets).saturatingAdd(other)
        var segments: [InspectorSizes.Segment] = []
        if code > 0 { segments.append(.init(title: "Code", bytes: code, tint: .blue, detail: Format.count(package.dexCount, "DEX file"))) }
        if native > 0 { segments.append(.init(title: "Native Libraries", bytes: native, tint: .purple, detail: Format.count(package.abis.count, "architecture"))) }
        if resources > 0 { segments.append(.init(title: "Resources", bytes: resources, tint: .orange, detail: nil)) }
        if assets > 0 { segments.append(.init(title: "Assets", bytes: assets, tint: .teal, detail: nil)) }
        if other > 0 { segments.append(.init(title: "Other", bytes: other, tint: .gray, detail: nil)) }
        package.sizes = InspectorSizes(total: total, segments: segments)
    }
}
