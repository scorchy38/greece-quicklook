import Foundation

/// Recognises software packages (by extension, then by what's inside) and reads their metadata.
enum PackageInspector {
    /// The most Greece reads of any one metadata file.
    static let metadataLimit = 1024 * 1024
    static let iconLimit: UInt64 = 2 * 1024 * 1024

    static func inspect(_ session: ArchiveSession, listing: ArchiveListing, flavor: ArchiveIdentity.Flavor, members: [String: Data]) -> PackageInfo? {
        let files = listing.entries.filter { !$0.isDirectory }
        var byPath: [String: ArchiveEntry] = [:]
        for entry in files.prefix(50_000) { byPath[ArchiveSession.normalized(entry.path)] = entry }
        let reader = Reader(session: session, byPath: byPath)

        if case .package(let kind) = flavor, let info = inspect(kind, reader: reader, listing: listing, members: members, files: files) {
            return info
        }
        // Content decides for plain archives (a renamed wheel, an npm tarball, a Python sdist).
        for kind in candidates(byPath: byPath) {
            if let info = inspect(kind, reader: reader, listing: listing, members: members, files: files) { return info }
        }
        return nil
    }

    private static func candidates(byPath: [String: ArchiveEntry]) -> [PackageKind] {
        var kinds: [PackageKind] = []
        let paths = byPath.keys
        if paths.contains(where: { $0.hasSuffix(".dist-info/METADATA") && $0.split(separator: "/").count == 2 }) { kinds.append(.wheel) }
        if byPath["AndroidManifest.xml"] != nil, byPath["classes.dex"] != nil || byPath["resources.arsc"] != nil { kinds.append(.apk) }
        if byPath["base/manifest/AndroidManifest.xml"] != nil { kinds.append(.aab) }
        if byPath["extension.vsixmanifest"] != nil { kinds.append(.vsix) }
        if paths.contains(where: { !$0.contains("/") && $0.hasSuffix(".nuspec") }) { kinds.append(.nuget) }
        if byPath["manifest.json"] != nil { kinds.append(.crx) }
        if byPath["package/package.json"] != nil { kinds.append(.npm) }
        if paths.contains(where: { $0.hasSuffix("/PKG-INFO") && $0.split(separator: "/").count == 2 }) { kinds.append(.sdist) }
        if byPath["META-INF/MANIFEST.MF"] != nil { kinds.append(.jar) }
        if skillFile(in: Array(paths)) != nil { kinds.append(.skill) }
        return kinds
    }

    /// Reads small members by path, within the metadata limit.
    struct Reader {
        let session: ArchiveSession
        let byPath: [String: ArchiveEntry]

        func data(_ path: String, limit: Int = PackageInspector.metadataLimit) -> Data? {
            guard let entry = byPath[path], entry.size <= UInt64(limit), !entry.isEncrypted else { return nil }
            return session.data(entry, limit: UInt64(limit))
        }

        func text(_ path: String) -> String? { data(path).map { TextFile.decode($0).0 } }

        func first(where match: (String) -> Bool) -> String? { byPath.keys.sorted().first(where: match) }

        /// An image member, for the package's icon.
        func image(_ path: String?) -> Data? {
            guard let path, let entry = byPath[ArchiveSession.normalized(path)], entry.size <= PackageInspector.iconLimit else { return nil }
            return session.data(entry, limit: PackageInspector.iconLimit)
        }
    }

    // MARK: - Per kind

    private static func inspect(_ kind: PackageKind, reader: Reader, listing: ArchiveListing, members: [String: Data], files: [ArchiveEntry]) -> PackageInfo? {
        switch kind {
        case .wheel: return wheel(reader)
        case .sdist: return sdist(reader)
        case .jar, .war, .ear: return java(reader, kind: kind, files: files)
        case .nuget: return nuget(reader)
        case .vsix: return vsix(reader)
        case .xpi, .crx: return browserExtension(reader, kind: kind)
        case .apk: return apk(reader, files: files)
        case .aab: return aab(reader)
        case .gem: return gem(members)
        case .deb: return deb(members)
        case .rpm: return rpm(reader.session)
        case .npm: return npm(reader)
        case .skill: return skill(reader, files: files)
        }
    }

    // MARK: Python

    private static func python(_ headers: [(String, String)], kind: PackageKind) -> PackageInfo {
        let first = { PackageFormats.first(headers, $0) }
        var info = PackageInfo(kind: kind, name: first("Name"), version: first("Version"), summary: first("Summary"))
        info.fact(String(localized: "Requires Python", bundle: .greeceKit, comment: "Package fact label: the Python versions a package needs, such as “≥ 3.9”"),
                  first("Requires-Python").map(prettyRequirement))
        var license = first("License-Expression") ?? first("License").flatMap { $0.count <= 40 && !$0.contains("\n") ? $0 : nil }
        if license == nil {
            license = PackageFormats.all(headers, "Classifier").first { $0.hasPrefix("License ::") }?.components(separatedBy: " :: ").last
        }
        info.fact(String(localized: "License", bundle: .greeceKit, comment: "Package fact label"), license)
        let author = first("Author") ?? first("Author-email").map { $0.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) ?? $0 }
        info.fact(String(localized: "Author", bundle: .greeceKit, comment: "Package fact label"), author)
        let urls = PackageFormats.all(headers, "Project-URL")
        info.homepage = first("Home-page") ?? urls.first { $0.lowercased().hasPrefix("homepage") || $0.lowercased().hasPrefix("source") }?.components(separatedBy: ",").last?.trimmingCharacters(in: .whitespaces)
        let requirements = PackageFormats.all(headers, "Requires-Dist")
        // Environment markers ("; platform_system == 'Windows'") are detail the card leaves out.
        info.dependencies = requirements.filter { !$0.contains("extra ==") && !$0.contains("extra==") }
            .map { $0.components(separatedBy: ";")[0].replacingOccurrences(of: " ", with: "") }
        let extras = PackageFormats.all(headers, "Provides-Extra")
        if !extras.isEmpty {
            info.fact(String(localized: "Extras", bundle: .greeceKit, comment: "Package fact label: a Python package’s optional feature sets"),
                      extras.prefix(8).joined(separator: ", "))
        }
        return info
    }

    private static func prettyRequirement(_ value: String) -> String {
        value.replacingOccurrences(of: ">=", with: "≥ ").replacingOccurrences(of: "<=", with: "≤ ").replacingOccurrences(of: "!=", with: "≠ ")
            .replacingOccurrences(of: ",", with: ", ").replacingOccurrences(of: "  ", with: " ")
    }

    private static func wheel(_ reader: Reader) -> PackageInfo? {
        guard let path = reader.first(where: { $0.hasSuffix(".dist-info/METADATA") && $0.split(separator: "/").count == 2 }),
              let text = reader.text(path) else { return nil }
        var info = python(PackageFormats.headers(text), kind: .wheel)
        if let wheel = reader.text(path.replacingOccurrences(of: "/METADATA", with: "/WHEEL")) {
            let tags = PackageFormats.all(PackageFormats.headers(wheel), "Tag")
            let more = tags.count - 1
            info.fact(String(localized: "Built for", bundle: .greeceKit, comment: "Package fact label: the platforms a Python wheel is built for, such as “py3-none-any”"),
                      tags.count == 1 ? tags[0] : tags.isEmpty ? nil
                        : String(localized: "\(tags[0]) and \(more) more", bundle: .greeceKit,
                                 comment: "The first argument is a name, the second how many more there are, such as “py3-none-any and 2 more”"))
        }
        return info.name == nil ? nil : info
    }

    private static func sdist(_ reader: Reader) -> PackageInfo? {
        guard let path = reader.first(where: { $0.hasSuffix("/PKG-INFO") && $0.split(separator: "/").count == 2 }), let text = reader.text(path) else { return nil }
        let info = python(PackageFormats.headers(text), kind: .sdist)
        return info.name == nil ? nil : info
    }

    // MARK: Java

    private static func java(_ reader: Reader, kind: PackageKind, files: [ArchiveEntry]) -> PackageInfo? {
        let manifest = reader.text("META-INF/MANIFEST.MF").map(PackageFormats.manifest) ?? [:]
        let pomPath = reader.first { $0.hasPrefix("META-INF/maven/") && $0.hasSuffix("/pom.properties") }
        let pom = pomPath.flatMap { reader.text($0) }.map(PackageFormats.properties) ?? [:]
        guard !manifest.isEmpty || !pom.isEmpty else { return nil }
        let name = manifest["Implementation-Title"] ?? manifest["Bundle-Name"] ?? manifest["Specification-Title"] ?? pom["artifactId"]
            ?? manifest["Automatic-Module-Name"]
        var info = PackageInfo(kind: kind, name: name, version: manifest["Implementation-Version"] ?? manifest["Bundle-Version"] ?? pom["version"],
                               summary: manifest["Bundle-Description"])
        if let group = pom["groupId"], let artifact = pom["artifactId"] { info.fact("Maven", "\(group):\(artifact)") }
        info.fact(String(localized: "Main class", bundle: .greeceKit, comment: "Package fact label: the Java class a .jar starts from"), manifest["Main-Class"])
        info.fact(String(localized: "Vendor", bundle: .greeceKit, comment: "Package fact label"), manifest["Implementation-Vendor"] ?? manifest["Bundle-Vendor"])
        info.fact(String(localized: "Module", bundle: .greeceKit, comment: "Package fact label: a Java module’s name"),
                  manifest["Automatic-Module-Name"] ?? manifest["Bundle-SymbolicName"]?.components(separatedBy: ";").first)
        if let jdk = manifest["Build-Jdk-Spec"] ?? manifest["Build-Jdk"] { info.fact("Java", jdk) }
        else { info.fact(String(localized: "Built by", bundle: .greeceKit, comment: "Package fact label: the tool that built a .jar"), manifest["Created-By"]) }
        let classes = files.lazy.filter { $0.path.hasSuffix(".class") }.count
        if classes > 0 { info.fact(String(localized: "Classes", bundle: .greeceKit, comment: "Package fact label: how many Java classes a .jar holds"), classes.formatted()) }
        if kind == .war {
            let libraries = files.lazy.filter { $0.path.hasPrefix("WEB-INF/lib/") && $0.path.hasSuffix(".jar") }.count
            if libraries > 0 {
                info.fact(String(localized: "Libraries", bundle: .greeceKit, comment: "Package fact label: how many libraries a web application bundles"), libraries.formatted())
            }
            if let web = reader.data("WEB-INF/web.xml").flatMap(PackageFormats.XMLDigest.init), let display = web.text("web-app/display-name") {
                if info.name == nil { info.name = display } else { info.fact(String(localized: "Display name", bundle: .greeceKit, comment: "Package fact label"), display) }
            }
        }
        return info
    }

    // MARK: .NET and editors

    private static func nuget(_ reader: Reader) -> PackageInfo? {
        guard let path = reader.first(where: { !$0.contains("/") && $0.hasSuffix(".nuspec") }),
              let xml = reader.data(path).flatMap(PackageFormats.XMLDigest.init) else { return nil }
        let id = xml.text("metadata/id")
        var info = PackageInfo(kind: .nuget, name: xml.text("metadata/title") ?? id, version: xml.text("metadata/version"),
                               summary: (xml.text("metadata/summary") ?? xml.text("metadata/description")).map(firstSentence))
        if let id, id != info.name { info.fact(String(localized: "ID", bundle: .greeceKit, comment: "Package fact label: the package’s identifier"), id) }
        info.fact(String(localized: "Authors", bundle: .greeceKit, comment: "Package fact label"), xml.text("metadata/authors"))
        info.fact(String(localized: "License", bundle: .greeceKit, comment: "Package fact label"), xml.text("metadata/license") ?? xml.text("metadata/licenseurl"))
        let frameworks = xml.all("dependencies/group").compactMap { $0.attributes["targetFramework"] }
        if !frameworks.isEmpty {
            info.fact(String(localized: "Frameworks", bundle: .greeceKit, comment: "Package fact label: the .NET versions a NuGet package targets, such as “net8.0”"),
                      frameworks.prefix(6).joined(separator: ", "))
        }
        var seen = Set<String>()
        info.dependencies = xml.all("dependency").compactMap { element in
            guard let id = element.attributes["id"], seen.insert(id.lowercased()).inserted else { return nil }
            return element.attributes["version"].map { "\(id) \($0)" } ?? id
        }
        info.homepage = xml.text("metadata/projecturl")
        info.icon = reader.image(xml.text("metadata/icon"))
        return info
    }

    private static func vsix(_ reader: Reader) -> PackageInfo? {
        if let json = reader.data("extension/package.json").flatMap(PackageFormats.json), let name = json["name"] as? String {
            let publisher = json["publisher"] as? String
            var info = PackageInfo(kind: .vsix, name: (json["displayName"] as? String) ?? name, version: json["version"] as? String,
                                   summary: json["description"] as? String)
            info.fact(String(localized: "Identifier", bundle: .greeceKit, comment: "Package fact label"), publisher.map { "\($0).\(name)" } ?? name)
            info.fact("VS Code", ((json["engines"] as? [String: Any])?["vscode"] as? String).map(prettyRequirement))
            info.fact(String(localized: "Categories", bundle: .greeceKit, comment: "Package fact label"),
                      (json["categories"] as? [String])?.prefix(4).joined(separator: ", "))
            info.fact(String(localized: "License", bundle: .greeceKit, comment: "Package fact label"), json["license"] as? String)
            info.dependencies = (json["extensionDependencies"] as? [String]) ?? []
            info.icon = reader.image((json["icon"] as? String).map { "extension/" + $0 })
            return info
        }
        guard let xml = reader.data("extension.vsixmanifest").flatMap(PackageFormats.XMLDigest.init) else { return nil }
        let identity = xml.all("metadata/identity").first?.attributes ?? [:]
        var info = PackageInfo(kind: .vsix, name: xml.text("metadata/displayname") ?? identity["Id"], version: identity["Version"],
                               summary: xml.text("metadata/description"))
        info.fact(String(localized: "Publisher", bundle: .greeceKit, comment: "Package fact label"), identity["Publisher"])
        let targets = xml.all("installationtarget").compactMap { $0.attributes["Id"]?.components(separatedBy: ".").last }
        if !targets.isEmpty {
            info.fact(String(localized: "Installs into", bundle: .greeceKit, comment: "Package fact label: the editors a Visual Studio extension installs into"),
                      Array(Set(targets)).sorted().joined(separator: ", "))
        }
        info.icon = reader.image(xml.text("metadata/icon"))
        return info.name == nil ? nil : info
    }

    // MARK: Browsers

    private static func browserExtension(_ reader: Reader, kind: PackageKind) -> PackageInfo? {
        guard let json = reader.data("manifest.json").flatMap(PackageFormats.json), json["manifest_version"] != nil else { return nil }
        // __MSG_name__ strings come from the default locale's messages.
        var messages: [String: Any] = [:]
        if let locale = json["default_locale"] as? String, locale.range(of: #"^[A-Za-z_-]{1,16}$"#, options: .regularExpression) != nil {
            messages = reader.data("_locales/\(locale)/messages.json").flatMap(PackageFormats.json) ?? [:]
        }
        func localized(_ value: Any?) -> String? {
            guard let text = value as? String else { return nil }
            guard text.hasPrefix("__MSG_"), text.hasSuffix("__") else { return text }
            let key = String(text.dropFirst(6).dropLast(2))
            let entry = messages.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value as? [String: Any]
            return entry?["message"] as? String
        }
        let gecko = ((json["browser_specific_settings"] ?? json["applications"]) as? [String: Any])?["gecko"] as? [String: Any]
        let actualKind: PackageKind = gecko != nil ? .xpi : kind
        var info = PackageInfo(kind: actualKind, name: localized(json["name"]), version: json["version"] as? String,
                               summary: localized(json["description"]))
        info.fact(String(localized: "Manifest", bundle: .greeceKit, comment: "Package fact label: which version of the browser extension manifest format it uses"),
                  (json["manifest_version"] as? Int).map {
                      String(localized: "Version \(String($0))", bundle: .greeceKit, comment: "A browser extension’s manifest format version; the argument is a number, such as “3”")
                  })
        let permissions = ((json["permissions"] as? [Any]) ?? []) + ((json["host_permissions"] as? [Any]) ?? [])
        if !permissions.isEmpty {
            info.fact(String(localized: "Permissions", bundle: .greeceKit, comment: "Package fact label: what an app or extension is allowed to do"),
                      permissions.compactMap { $0 as? String }.prefix(6).joined(separator: ", ") + (permissions.count > 6 ? "…" : ""))
        }
        info.fact(String(localized: "ID", bundle: .greeceKit, comment: "Package fact label: the package’s identifier"), gecko?["id"] as? String)
        info.fact(String(localized: "Author", bundle: .greeceKit, comment: "Package fact label"),
                  (json["author"] as? String) ?? ((json["author"] as? [String: Any])?["email"] as? String))
        info.homepage = json["homepage_url"] as? String
        if let icons = json["icons"] as? [String: Any] {
            let best = icons.compactMap { key, value -> (Int, String)? in
                guard let size = Int(key), let path = value as? String else { return nil }
                return (size, path)
            }.max { $0.0 < $1.0 }
            info.icon = reader.image(best?.1)
        }
        return info.name == nil ? nil : info
    }

    // MARK: Android

    private static func apk(_ reader: Reader, files: [ArchiveEntry]) -> PackageInfo? {
        guard let data = reader.data("AndroidManifest.xml", limit: 8 * 1024 * 1024), let manifest = AndroidManifest(binaryXML: data) else { return nil }
        var info = android(manifest, kind: .apk)
        let dex = files.lazy.filter { !$0.path.contains("/") && $0.path.hasPrefix("classes") && $0.path.hasSuffix(".dex") }.count
        if dex > 1 { info.fact(String(localized: "Dex files", bundle: .greeceKit, comment: "Package fact label: how many Dalvik executables an Android package holds"), dex.formatted()) }
        let abis = Set(files.compactMap { entry -> String? in
            let parts = entry.path.split(separator: "/")
            return parts.count >= 3 && parts[0] == "lib" ? String(parts[1]) : nil
        })
        if !abis.isEmpty {
            info.fact(String(localized: "Native code", bundle: .greeceKit, comment: "Package fact label: the processor architectures an Android package has code for, such as “arm64-v8a”"),
                      abis.sorted().joined(separator: ", "))
        }
        // The launcher icon, when it's a plain bitmap with a conventional name.
        let icon = files.filter { entry in
            let path = entry.path.lowercased()
            return path.hasPrefix("res/mipmap") && (path.hasSuffix("/ic_launcher.png") || path.hasSuffix("/ic_launcher.webp"))
        }.max { $0.size < $1.size }
        info.icon = reader.image(icon?.path)
        return info
    }

    private static func aab(_ reader: Reader) -> PackageInfo? {
        guard let data = reader.data("base/manifest/AndroidManifest.xml", limit: 8 * 1024 * 1024),
              let manifest = AndroidManifest(protobufXML: data) else { return nil }
        return android(manifest, kind: .aab)
    }

    private static func android(_ manifest: AndroidManifest, kind: PackageKind) -> PackageInfo {
        var info = PackageInfo(kind: kind, name: manifest.label ?? manifest.package, version: manifest.versionName)
        if manifest.label != nil { info.summary = manifest.package }
        info.fact(String(localized: "Version code", bundle: .greeceKit, comment: "Package fact label: an Android app’s internal version number"), manifest.versionCode)
        info.fact(String(localized: "Minimum Android", bundle: .greeceKit, comment: "Package fact label: the oldest Android version an app runs on"),
                  manifest.minSDK.map(androidVersion))
        info.fact(String(localized: "Target", bundle: .greeceKit, comment: "Package fact label: the Android version an app is built for"),
                  manifest.targetSDK.map(androidVersion))
        if !manifest.permissions.isEmpty {
            info.fact(String(localized: "Permissions", bundle: .greeceKit, comment: "Package fact label: what an app or extension is allowed to do"),
                      "\(manifest.permissions.count)")
            info.dependencies = manifest.permissions.map { $0.replacingOccurrences(of: "android.permission.", with: "") }
        }
        return info
    }

    private static func androidVersion(_ sdk: String) -> String {
        let names: [Int: String] = [21: "5.0", 22: "5.1", 23: "6", 24: "7", 25: "7.1", 26: "8", 27: "8.1", 28: "9", 29: "10", 30: "11",
                                    31: "12", 32: "12L", 33: "13", 34: "14", 35: "15", 36: "16"]
        guard let level = Int(sdk) else { return sdk }
        return names[level].map { "Android \($0) (API \(level))" } ?? "API \(level)"
    }

    // MARK: Linux and Ruby

    private static func gem(_ members: [String: Data]) -> PackageInfo? {
        guard let compressed = members["metadata.gz"], let yaml = PackageFormats.gunzip(compressed) else { return nil }
        let spec = PackageFormats.gemspec(String(decoding: yaml, as: UTF8.self))
        guard let name = spec.fields["name"] else { return nil }
        var info = PackageInfo(kind: .gem, name: name, version: spec.fields["version"], summary: spec.fields["summary"])
        info.fact("Ruby", spec.fields["required_ruby_version"].map(prettyRequirement))
        info.fact(String(localized: "Platform", bundle: .greeceKit, comment: "Package fact label: the platform a Ruby gem is built for"),
                  spec.fields["platform"].flatMap { $0 == "ruby" ? nil : $0 })
        info.fact(String(localized: "License", bundle: .greeceKit, comment: "Package fact label"), spec.licenses.joined(separator: ", "))
        info.fact(String(localized: "Authors", bundle: .greeceKit, comment: "Package fact label"),
                  spec.authors.prefix(3).joined(separator: ", ") + (spec.authors.count > 3 ? "…" : ""))
        info.homepage = spec.fields["homepage"]
        info.dependencies = spec.dependencies
        return info
    }

    private static func deb(_ members: [String: Data]) -> PackageInfo? {
        guard let control = members["control"] else { return nil }
        let headers = PackageFormats.headers(TextFile.decode(control).0, continuationJoiner: "\n")
        let first = { PackageFormats.first(headers, $0) }
        guard let name = first("Package") else { return nil }
        let description = first("Description")
        var info = PackageInfo(kind: .deb, name: name, version: first("Version"),
                               summary: description?.components(separatedBy: "\n").first)
        info.fact(String(localized: "Architecture", bundle: .greeceKit, comment: "Package fact label: the processor a Linux package is built for, such as “arm64”"),
                  first("Architecture"))
        info.fact(String(localized: "Section", bundle: .greeceKit, comment: "Package fact label: a Debian package’s category, such as “utils”"), first("Section"))
        info.fact(String(localized: "Maintainer", bundle: .greeceKit, comment: "Package fact label"),
                  first("Maintainer").map { $0.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces) ?? $0 })
        if let installed = first("Installed-Size").flatMap(Int64.init) {
            info.fact(String(localized: "Installed size", bundle: .greeceKit, comment: "Package fact label: how much space a package takes once installed"),
                      ByteCountFormatter.string(fromByteCount: installed * 1024, countStyle: .file))
        }
        info.homepage = first("Homepage")
        info.dependencies = (first("Depends") ?? "").components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return info
    }

    private static func rpm(_ session: ArchiveSession) -> PackageInfo? {
        guard case .rpm(let header, _) = session.layout, let name = header.name else { return nil }
        var info = PackageInfo(kind: .rpm, name: name, version: [header.version, header.release].compactMap { $0 }.joined(separator: "-").nilIfEmpty,
                               summary: header.string(1004))
        let source = String(localized: "Source [package architecture]", defaultValue: "Source", bundle: .greeceKit,
                            comment: "Package fact value: the package holds source code rather than a build for one processor")
        info.fact(String(localized: "Architecture", bundle: .greeceKit, comment: "Package fact label: the processor a Linux package is built for, such as “arm64”"),
                  header.isSource ? source : header.string(1022))
        info.fact(String(localized: "License", bundle: .greeceKit, comment: "Package fact label"), header.string(1014))
        info.fact(String(localized: "Group", bundle: .greeceKit, comment: "Package fact label: an RPM package’s category, such as “System Environment/Base”"),
                  header.string(1016).flatMap { $0 == "Unspecified" ? nil : $0 })
        info.fact(String(localized: "Vendor", bundle: .greeceKit, comment: "Package fact label"), header.string(1011) ?? header.string(1015))
        if let size = header.ints(5009).first ?? header.ints(1009).first {
            info.fact(String(localized: "Installed size", bundle: .greeceKit, comment: "Package fact label: how much space a package takes once installed"),
                      ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
        }
        if let built = header.ints(1006).first {
            info.fact(String(localized: "Built", bundle: .greeceKit, comment: "Package fact label: the date a package was built"),
                      Date(timeIntervalSince1970: TimeInterval(built)).formatted(date: .abbreviated, time: .omitted))
        }
        info.homepage = header.string(1020)
        var seen = Set<String>()
        info.dependencies = header.strings(1049).filter { !$0.hasPrefix("rpmlib(") && !$0.hasPrefix("/") && seen.insert($0).inserted }
        return info
    }

    // MARK: npm

    private static func npm(_ reader: Reader) -> PackageInfo? {
        guard let json = reader.data("package/package.json").flatMap(PackageFormats.json), let name = json["name"] as? String else { return nil }
        var info = PackageInfo(kind: .npm, name: name, version: json["version"] as? String, summary: json["description"] as? String)
        info.fact(String(localized: "License", bundle: .greeceKit, comment: "Package fact label"), json["license"] as? String)
        info.fact("Node", ((json["engines"] as? [String: Any])?["node"] as? String).map(prettyRequirement))
        info.fact(String(localized: "Author", bundle: .greeceKit, comment: "Package fact label"),
                  (json["author"] as? String)?.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces)
                    ?? ((json["author"] as? [String: Any])?["name"] as? String))
        if let module = json["type"] as? String, module == "module" {
            info.fact(String(localized: "Modules", bundle: .greeceKit, comment: "Package fact label: the JavaScript module system an npm package uses"),
                      String(localized: "ES modules", bundle: .greeceKit, comment: "Package fact value: the package uses JavaScript’s standard (ECMAScript) modules"))
        }
        info.homepage = json["homepage"] as? String
        if let dependencies = json["dependencies"] as? [String: Any] {
            info.dependencies = dependencies.keys.sorted().map { key in (dependencies[key] as? String).map { "\(key) \($0)" } ?? key }
        }
        return info
    }

    // MARK: Agent skills

    /// A skill's instructions: SKILL.md at the top, or in the one folder the package holds.
    static func skillFile(in paths: [String]) -> String? {
        paths.filter { ($0 as NSString).lastPathComponent == "SKILL.md" && $0.split(separator: "/").count <= 2 }
            .min { $0.count < $1.count }
    }

    /// An agent skill (Claude and others): its name and description from SKILL.md's front matter,
    /// and what it bundles (scripts, references, assets).
    private static func skill(_ reader: Reader, files: [ArchiveEntry]) -> PackageInfo? {
        guard let path = skillFile(in: Array(reader.byPath.keys)), let text = reader.text(path) else { return nil }
        let front = FrontMatter.fields(text)
        let folder = path.contains("/") ? String(path.split(separator: "/")[0]) : nil
        var info = PackageInfo(kind: .skill, name: front["name"] ?? folder, version: front["version"] ?? front["metadata.version"],
                               summary: front["description"].map(firstSentence))
        info.fact(String(localized: "License", bundle: .greeceKit, comment: "Package fact label"), front["license"])
        info.fact(String(localized: "Allowed Tools", bundle: .greeceKit, comment: "Package fact label: the tools an agent skill may use without asking"),
                  front["allowed-tools"])
        info.fact(String(localized: "Compatibility", bundle: .greeceKit, comment: "Package fact label: what an agent skill needs to work"), front["compatibility"])
        let inside = files.map { ArchiveSession.normalized($0.path) }.map { path in
            folder.map { path.hasPrefix($0 + "/") ? String(path.dropFirst($0.count + 1)) : path } ?? path
        }
        let folders = [
            (String(localized: "Scripts", bundle: .greeceKit, comment: "Package fact label: how many scripts an agent skill bundles"), "scripts/"),
            (String(localized: "References", bundle: .greeceKit, comment: "Package fact label: how many reference documents an agent skill bundles"), "references/"),
            (String(localized: "Assets", bundle: .greeceKit, comment: "Package fact label: how many other files (templates, images) an agent skill bundles"), "assets/"),
        ]
        for (label, prefix) in folders {
            let count = inside.filter { $0.hasPrefix(prefix) }.count
            if count > 0 { info.fact(label, String(localized: "\(count) files", bundle: .greeceKit, comment: "A count of files")) }
        }
        return info
    }

    private static func firstSentence(_ text: String) -> String {
        let line = text.components(separatedBy: .newlines).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? text
        if line.count <= 160 { return line }
        if let stop = line.range(of: ". ") { return String(line[..<stop.lowerBound]) + "." }
        return String(line.prefix(160)) + "…"
    }
}
