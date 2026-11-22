import Foundation
import AppKit
import Security

/// Everything Greece reads from an installer package, without running or expanding it.
struct InstallerPackage {
    enum Kind: Equatable { case product, component, bundle }

    struct Script {
        enum Role: Equatable {
            /// preinstall, postinstall and their legacy names: Installer runs these itself.
            case hook
            /// Other programs in the scripts archive, which the hooks or JavaScript can run.
            case program
            /// Files the scripts use (property lists, templates).
            case support
        }
        var name: String
        /// The component it belongs to, or nil for product-level scripts.
        var owner: String?
        var text: String?
        var size: UInt64
        var truncated: Bool
        /// highlight.js grammar from the shebang or extension.
        var grammar: String
        var role: Role = .hook
        var isBinary: Bool { text == nil }
        var lineCount: Int { text.map { $0.reduce(into: 1) { if $1 == "\n" { $0 += 1 } } } ?? 0 }
    }

    struct Bundle: Equatable {
        var identifier: String
        var path: String
        var version: String?
    }

    struct Component {
        var name: String
        var identifier: String?
        var version: String?
        var installLocation: String
        var auth: String?
        var relocatable: Bool
        var postinstallAction: String?
        var declaredFiles: Int?
        var installKBytes: Int?
        var bundles: [Bundle] = []
        var scripts: [Script] = []
        var payload: [Bom.Entry]?
        var payloadTruncated = false
        var generator: String?

        var installsAsRoot: Bool { (auth ?? "root").lowercased() == "root" }
        /// Payload paths rooted at the install location, without the leading slash.
        func installedPath(_ relative: String) -> String {
            var base = installLocation.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if base == "." { base = "" }
            return base.isEmpty ? relative : base + "/" + relative
        }
    }

    struct Choice: Equatable {
        var id: String
        var title: String?
        var description: String?
        var visible: Bool
        var packageRefs: [String]
    }

    struct Distribution {
        var title: String?
        var productID: String?
        var productVersion: String?
        var hostArchitectures: [String] = []
        var minimumOS: String?
        var maximumOS: String?
        var customize: String?
        var domains: [String] = []
        var rootVolumeOnly = false
        var allowExternalScripts = false
        var choices: [Choice] = []
        var outline: [String] = []
        var javaScript: String?
        var installationCheck: String?
        var volumeCheck: String?
        var mustClose: [String] = []
        var resources: [String: String] = [:]
        var requiresRestart = false
        /// pkg-ref id → (version, KB, auth, href).
        var packageRefs: [String: (version: String?, installKBytes: Int?, auth: String?, href: String?, identifier: String?)] = [:]
        /// Component folders in the order the Distribution references them.
        var packageOrder: [String] = []
    }

    struct SignatureInfo {
        var certificates: [CertificateSummary]
        var verdict: XarArchive.Verdict
        var checksumMatches: Bool?
        var signedAt: Date?
        var trustedTimestamp: Bool
        var hasCMS: Bool
        /// The certificates form a chain to one of Apple's roots (checked offline, at the signing time).
        var chainsToApple: Bool
    }

    var url: URL
    var kind: Kind
    var distribution: Distribution?
    var components: [Component] = []
    /// Product-level scripts (called from the Distribution's JavaScript with system.run).
    var productScripts: [Script] = []
    var signature: SignatureInfo?
    var ticket: NotarizationTicket?
    var ticketMatches = false
    var tocChecksum: Data?
    var tocChecksumStyle: String?
    var created: Date?
    var license: String?
    var fileSize: UInt64

    var allScripts: [Script] { productScripts + components.flatMap(\.scripts) }
    var installedFiles: Int {
        components.reduce(0) { $0 + ($1.payload.map { $0.filter { $0.kind != .directory }.count } ?? $1.declaredFiles ?? 0) }
    }
    var installedBytes: UInt64 {
        components.reduce(0) { total, component in
            if let payload = component.payload, !payload.isEmpty {
                return total.saturatingAdd(payload.reduce(0) { $1.kind == .file ? $0.saturatingAdd($1.size) : $0 })
            }
            return total.saturatingAdd(UInt64(max(0, component.installKBytes ?? 0)) * 1024)
        }
    }

    // MARK: Reading

    static let scriptLimit = 256 * 1024
    static let scriptsArchiveLimit = 16 << 20
    static let bomLimit = 64 << 20

    static func read(_ url: URL) throws -> InstallerPackage {
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        if isDirectory.boolValue { return try readBundle(url) }

        let xar = try XarArchive(url: url)
        let size = UInt64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? xar.data.count)
        var package = InstallerPackage(url: url, kind: .component, fileSize: size)
        package.created = xar.creationDate
        package.tocChecksum = xar.storedChecksum
        package.tocChecksumStyle = xar.checksumStyle

        if let raw = xar.contents(of: "Distribution", limit: 4 << 20), let root = try? PackageXMLNode.parse(raw.data) {
            package.kind = .product
            package.distribution = parseDistribution(root)
        }

        // Components: a root PackageInfo (component package), or folders holding one (product archive).
        var componentRoots: [String] = []
        if xar.entry("PackageInfo") != nil { componentRoots.append("") }
        for entry in xar.entries where entry.name == "PackageInfo" && entry.path.contains("/") {
            let folder = (entry.path as NSString).deletingLastPathComponent
            if !folder.contains("/") { componentRoots.append(folder) }
        }
        for root in componentRoots.prefix(64) {
            let prefix = root.isEmpty ? "" : root + "/"
            guard let info = xar.contents(of: prefix + "PackageInfo", limit: 4 << 20),
                  let node = try? PackageXMLNode.parse(info.data) else { continue }
            var component = parseComponent(node, name: root.isEmpty ? url.deletingPathExtension().lastPathComponent : root)
            if let scripts = xar.contents(of: prefix + "Scripts", limit: scriptsArchiveLimit) {
                component.scripts = scriptsFrom(archive: scripts.data, owner: component.identifier ?? component.name)
            }
            if let bom = xar.contents(of: prefix + "Bom", limit: bomLimit), !bom.truncated,
               let listing = try? Bom.read(bom.data) {
                component.payload = listing.entries
                component.payloadTruncated = listing.truncated
            } else if let payloadEntry = xar.entry(prefix + "Payload"), payloadEntry.length <= 32 << 20,
                      let payload = xar.contents(of: payloadEntry, limit: 64 << 20),
                      let decoded = PackageDecompression.decode(payload.data, limit: 256 << 20), Cpio.isCpio(decoded.data) {
                // No readable Bom: list the payload itself (small payloads only).
                let cpio = Cpio.read(decoded.data)
                component.payload = cpio.entries.map {
                    Bom.Entry(path: $0.path, kind: $0.isDirectory ? .directory : ($0.isSymlink ? .symlink : .file),
                              mode: UInt16(truncatingIfNeeded: $0.mode), uid: 0, gid: 0, size: $0.isDirectory ? 0 : $0.size,
                              modified: $0.modified, linkTarget: nil)
                }
                component.payloadTruncated = cpio.truncated || decoded.truncated
            }
            package.components.append(component)
        }

        // Product-level scripts and the Distribution's order for components.
        if package.kind == .product, let scripts = xar.contents(of: "Scripts", limit: scriptsArchiveLimit) {
            package.productScripts = scriptsFrom(archive: scripts.data, owner: nil)
        }
        if let order = package.distribution?.packageOrder, !order.isEmpty {
            package.components.sort { lhs, rhs in
                (order.firstIndex(of: lhs.name) ?? Int.max) < (order.firstIndex(of: rhs.name) ?? Int.max)
            }
        }

        package.license = license(in: xar, distribution: package.distribution)

        // Titles and choices may be keys into the English Localizable.strings ("SU_TITLE").
        if var distribution = package.distribution {
            let strings = localizedStrings(in: xar)
            if !strings.isEmpty {
                func localize(_ text: String?) -> String? { text.map { strings[$0].map { Format.clean($0, limit: 200) } ?? $0 } }
                distribution.title = localize(distribution.title)
                for index in distribution.choices.indices {
                    distribution.choices[index].title = localize(distribution.choices[index].title)
                    distribution.choices[index].description = localize(distribution.choices[index].description)
                }
                package.distribution = distribution
            }
        }

        // Signature.
        if let signature = xar.signature ?? xar.cmsSignature {
            let certificates = signature.certificates.prefix(8).compactMap(CertificateSummary.init(der:))
            let date = xar.cmsSigningDate()
            package.signature = SignatureInfo(certificates: Array(certificates), verdict: xar.signature != nil ? xar.verifyRSASignature() : .unknown,
                                              checksumMatches: xar.checksumMatches, signedAt: date?.date,
                                              trustedTimestamp: date?.trusted ?? false, hasCMS: xar.cmsSignature != nil,
                                              chainsToApple: CertificateChain.chainsToApple(signature.certificates, at: date?.date ?? xar.creationDate))
        }
        if let ticket = NotarizationTicket.stapled(atEndOf: url) {
            package.ticket = ticket
            package.ticketMatches = xar.storedChecksum.map(ticket.covers) ?? false
        }
        return package
    }

    // MARK: Distribution

    static func parseDistribution(_ root: PackageXMLNode) -> Distribution {
        var distribution = Distribution()
        distribution.title = root.value("title").map { Format.clean($0, limit: 200) }.flatMap { $0.nilIfEmpty }
        if let product = root.child("product") {
            distribution.productID = product["id"]
            distribution.productVersion = product["version"]
        }
        for options in root.children("options") {
            if let architectures = options["hostArchitectures"] {
                distribution.hostArchitectures = architectures.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            }
            if let customize = options["customize"] { distribution.customize = customize }
            if options["rootVolumeOnly"] == "true" { distribution.rootVolumeOnly = true }
            if options["allow-external-scripts"] == "true" || options["allow-external-scripts"] == "yes" { distribution.allowExternalScripts = true }
            if distribution.minimumOS == nil, let minimum = options["minOSVersion"] { distribution.minimumOS = minimum }
        }
        if let allowed = root.child("allowed-os-versions"), let version = allowed.children("os-version").first {
            distribution.minimumOS = version["min"] ?? distribution.minimumOS
            distribution.maximumOS = version["before"]
        }
        if let domains = root.child("domains") {
            if domains["enable_localSystem"] == "true" { distribution.domains.append("localSystem") }
            if domains["enable_currentUserHome"] == "true" { distribution.domains.append("currentUserHome") }
            if domains["enable_anywhere"] == "true" { distribution.domains.append("anywhere") }
        }
        let scripts = root.children("script").map(\.trimmedText).filter { !$0.isEmpty }
        if !scripts.isEmpty { distribution.javaScript = String(scripts.joined(separator: "\n\n").prefix(scriptLimit)) }
        distribution.installationCheck = root.child("installation-check")?["script"]
        distribution.volumeCheck = root.child("volume-check")?["script"]

        for line in root.descendants("line", limit: 1000) { if let choice = line["choice"] { distribution.outline.append(choice) } }
        for choice in root.children("choice").prefix(500) {
            guard let id = choice["id"] else { continue }
            distribution.choices.append(Choice(id: id, title: choice["title"].map { Format.clean($0, limit: 200) },
                                               description: choice["description"].map { Format.clean($0, limit: 400) },
                                               visible: choice["visible"] != "false",
                                               packageRefs: choice.children("pkg-ref").compactMap { $0["id"] }))
        }
        for ref in root.children("pkg-ref").prefix(500) {
            guard let id = ref["id"] else { continue }
            var current = distribution.packageRefs[id] ?? (nil, nil, nil, nil, nil)
            if let version = ref["version"] { current.version = version }
            if let kilobytes = ref["installKBytes"].flatMap(Int.init) { current.installKBytes = kilobytes }
            if let auth = ref["auth"] { current.auth = auth }
            if let identifier = ref["packageIdentifier"] { current.identifier = identifier }
            let href = ref.trimmedText
            if !href.isEmpty {
                current.href = href
                let folder = href.trimmingCharacters(in: CharacterSet(charactersIn: "#")).removingPercentEncoding ?? href
                if !distribution.packageOrder.contains(folder) { distribution.packageOrder.append(folder) }
            }
            if let action = ref["onConclusion"], action.lowercased().contains("restart") { distribution.requiresRestart = true }
            distribution.packageRefs[id] = current
            for app in ref.child("must-close")?.children("app") ?? [] {
                if let bundle = app["id"], !distribution.mustClose.contains(bundle) { distribution.mustClose.append(bundle) }
            }
        }
        for resource in ["welcome", "readme", "license", "conclusion", "background"] {
            if let file = root.child(resource)?["file"] { distribution.resources[resource] = file }
        }
        return distribution
    }

    // MARK: Components

    static func parseComponent(_ node: PackageXMLNode, name: String) -> Component {
        var component = Component(name: name, identifier: node["identifier"], version: node["version"],
                                  installLocation: node["system-volume-group-install-location"] ?? node["install-location"] ?? "/", auth: node["auth"],
                                  relocatable: node["relocatable"] == "true",
                                  postinstallAction: node["postinstall-action"].flatMap { $0 == "none" ? nil : $0 })
        if let payload = node.child("payload") {
            component.declaredFiles = payload["numberOfFiles"].flatMap(Int.init)
            component.installKBytes = payload["installKBytes"].flatMap(Int.init)
        }
        component.generator = node["generator-version"]
        var bundles: [Bundle] = []
        let candidates = node.children("bundle") + (node.child("bundle-version")?.children("bundle") ?? [])
        for bundle in candidates.prefix(500) {
            guard let id = bundle["id"], let path = bundle["path"] else { continue }
            if bundles.contains(where: { $0.identifier == id && $0.path == path }) { continue }
            var cleaned = path
            while cleaned.hasPrefix("./") { cleaned.removeFirst(2) }
            bundles.append(Bundle(identifier: id, path: cleaned, version: bundle["CFBundleShortVersionString"] ?? bundle["CFBundleVersion"]))
        }
        component.bundles = bundles
        return component
    }

    /// Scripts from a gzip'd cpio "Scripts" member: everything executable or named like an installer hook.
    static let hooks = ["preinstall", "postinstall", "preupgrade", "postupgrade", "preflight", "postflight"]

    /// Scripts from a gzip'd cpio "Scripts" member: the hooks Installer runs, other programs they
    /// can call, and the files they use.
    static func scriptsFrom(archive: Data, owner: String?) -> [Script] {
        guard let decoded = PackageDecompression.decode(archive, limit: scriptsArchiveLimit), Cpio.isCpio(decoded.data) else { return [] }
        let listing = Cpio.read(decoded.data, limit: 2000, keepContentsUpTo: 4 << 20)
        var scripts: [Script] = []
        var supportFiles = 0
        for entry in listing.entries where entry.isFile && !entry.isDirectory && !entry.isSymlink {
            let name = (entry.path as NSString).lastPathComponent
            // Finder litter: AppleDouble resource forks and folder settings.
            if name.hasPrefix("._") || name == ".DS_Store" || entry.path.hasPrefix("__MACOSX") { continue }
            var script = script(named: entry.path, owner: owner, contents: entry.contents, size: entry.size)
            let shebang = entry.contents?.starts(with: Array("#!".utf8)) == true
            let machO = entry.contents.map(isMachO) ?? false
            let scriptExtension = ["sh", "py", "pl", "rb", "command", "zsh", "bash"].contains((name as NSString).pathExtension.lowercased())
            if hooks.contains(name) {
                script.role = .hook
            } else if (entry.mode & 0o111 != 0 || scriptExtension) && (shebang || machO) {
                script.role = .program
            } else {
                supportFiles += 1
                if supportFiles > 20 { continue }
                script.role = .support
                if script.text != nil { script.grammar = grammar(forFile: name) }
            }
            scripts.append(script)
            if scripts.count >= 100 { break }
        }
        // Hooks first, in the order Installer runs them, then programs, then support files.
        func rank(_ script: Script) -> Int {
            switch script.role {
            case .hook: return hooks.firstIndex(of: (script.name as NSString).lastPathComponent) ?? hooks.count
            case .program: return 100
            case .support: return 200
            }
        }
        return scripts.sorted { lhs, rhs in
            let left = rank(lhs), right = rank(rhs)
            return left != right ? left < right : lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    static func isMachO(_ data: Data) -> Bool {
        let magic = [UInt8](data.prefix(4))
        return [[0xCF, 0xFA, 0xED, 0xFE], [0xCE, 0xFA, 0xED, 0xFE], [0xCA, 0xFE, 0xBA, 0xBE], [0xCA, 0xFE, 0xBA, 0xBF]].contains(magic)
    }

    static func grammar(forFile name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "plist", "xml", "mobileconfig", "dist": return "xml"
        case "json": return "json"
        case "sh", "command", "zsh", "bash": return "bash"
        case "py": return "python"
        case "pl": return "perl"
        case "rb": return "ruby"
        case "js": return "javascript"
        default: return "plaintext"
        }
    }

    static func script(named name: String, owner: String?, contents: Data?, size: UInt64) -> Script {
        guard let contents else {
            return Script(name: name, owner: owner, text: nil, size: size, truncated: false, grammar: "plaintext")
        }
        let head = [UInt8](contents.prefix(4096))
        let controls = head.filter { $0 < 0x20 && $0 != 0x09 && $0 != 0x0A && $0 != 0x0D && $0 != 0x0C && $0 != 0x1B }.count
        let isText = !head.contains(0) && controls * 100 <= max(1, head.count) * 2
        guard isText else {
            return Script(name: name, owner: owner, text: nil, size: size, truncated: false, grammar: "plaintext")
        }
        let truncated = contents.count > scriptLimit
        let text = String(decoding: contents.prefix(scriptLimit), as: UTF8.self)
        return Script(name: name, owner: owner, text: text, size: size, truncated: truncated, grammar: grammar(forScript: text, name: name))
    }

    static func grammar(forScript text: String, name: String) -> String {
        let first = text.prefix { $0 != "\n" }.lowercased()
        if first.hasPrefix("#!") {
            if first.contains("python") { return "python" }
            if first.contains("perl") { return "perl" }
            if first.contains("ruby") { return "ruby" }
            if first.contains("osascript") { return "applescript" }
            if first.contains("node") { return "javascript" }
            return "bash"
        }
        switch (name as NSString).pathExtension.lowercased() {
        case "py": return "python"
        case "pl": return "perl"
        case "rb": return "ruby"
        default: return "bash"
        }
    }

    /// The product's English strings table (old-style plist, often UTF-16), if it has one.
    static func localizedStrings(in xar: XarArchive) -> [String: String] {
        for path in ["Resources/en.lproj/Localizable.strings", "Resources/English.lproj/Localizable.strings", "Resources/Base.lproj/Localizable.strings"] {
            guard let raw = xar.contents(of: path, limit: 1 << 20), !raw.truncated,
                  let table = (try? PropertyListSerialization.propertyList(from: raw.data, format: nil)) as? [String: String] else { continue }
            return table
        }
        return [:]
    }

    /// The license agreement as plain text: English first, then any localisation.
    static func license(in xar: XarArchive, distribution: Distribution?) -> String? {
        guard let file = distribution?.resources["license"] else { return nil }
        let candidates = ["Resources/en.lproj/\(file)", "Resources/English.lproj/\(file)", "Resources/Base.lproj/\(file)", "Resources/\(file)"]
            + xar.entries.filter { $0.path.hasPrefix("Resources/") && $0.name == file }.map(\.path)
        for path in candidates {
            guard let raw = xar.contents(of: path, limit: 1 << 20) else { continue }
            return plainText(raw.data, name: file)
        }
        return nil
    }

    static func plainText(_ data: Data, name: String) -> String? {
        let ext = (name as NSString).pathExtension.lowercased()
        if ext == "rtf" || data.starts(with: Array("{\\rtf".utf8)) {
            guard let text = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf],
                                                     documentAttributes: nil).string else { return nil }
            return String(text.prefix(scriptLimit))
        }
        if ext == "html" || ext == "htm" { return nil }
        return String(decoding: data.prefix(scriptLimit), as: UTF8.self)
    }

    // MARK: Bundle-style packages (pre-10.5)

    static func readBundle(_ url: URL) throws -> InstallerPackage {
        let contents = url.appendingPathComponent("Contents")
        let infoURL = contents.appendingPathComponent("Info.plist")
        guard let infoData = try? Data(contentsOf: infoURL), infoData.count < 4 << 20,
              let info = (try? PropertyListSerialization.propertyList(from: infoData, format: nil)) as? [String: Any] else {
            throw XarArchive.Failure.notXar
        }
        var package = InstallerPackage(url: url, kind: .bundle, fileSize: 0)
        let resources = contents.appendingPathComponent("Resources")
        var component = Component(name: url.deletingPathExtension().lastPathComponent,
                                  identifier: info["CFBundleIdentifier"] as? String,
                                  version: (info["CFBundleShortVersionString"] as? String) ?? (info["CFBundleVersion"] as? String),
                                  installLocation: (info["IFPkgFlagDefaultLocation"] as? String) ?? "/",
                                  auth: (info["IFPkgFlagAuthorizationAction"] as? String).map { $0.lowercased().contains("root") ? "root" : "none" },
                                  relocatable: (info["IFPkgFlagRelocatable"] as? Bool) ?? false,
                                  postinstallAction: (info["IFPkgFlagRestartAction"] as? String).flatMap { $0 == "NoRestart" ? nil : $0 })
        if let bom = try? Data(contentsOf: contents.appendingPathComponent("Archive.bom"), options: .alwaysMapped),
           bom.count <= bomLimit, let listing = try? Bom.read(bom) {
            component.payload = listing.entries
            component.payloadTruncated = listing.truncated
        }
        for hook in hooks {
            let script = resources.appendingPathComponent(hook)
            guard let size = (try? script.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
                  let handle = try? FileHandle(forReadingFrom: script) else { continue }
            let data = try? handle.read(upToCount: scriptLimit + 1)
            try? handle.close()
            component.scripts.append(self.script(named: hook, owner: component.identifier, contents: data, size: UInt64(size)))
        }
        package.components = [component]
        // Metapackages list their parts in Contents/Packages.
        let parts = (try? FileManager.default.contentsOfDirectory(at: contents.appendingPathComponent("Packages"), includingPropertiesForKeys: nil)) ?? []
        for part in parts.prefix(64) where ["pkg", "mpkg"].contains(part.pathExtension.lowercased()) {
            if let nested = try? readBundle(part) { package.components += nested.components }
        }
        return package
    }

    static func sniff(probe: [UInt8], ext: String, isDirectory: Bool) -> Bool {
        if isDirectory { return ["pkg", "mpkg"].contains(ext) }
        return XarArchive.sniff(probe) && ["pkg", "mpkg"].contains(ext)
    }
}
