import Foundation

/// A package pinned by a lock file.
struct LockedPackage: Equatable {
    enum Kind: String {
        case direct = "Direct", dev = "Dev", directDev = "Direct · Dev", optional = "Optional", transitive = "Transitive"
        case workspace = "Workspace", unknown = ""

        var tint: GridTint {
            switch self {
            case .direct: return .accent
            case .directDev, .dev: return .purple
            case .optional: return .orange
            case .workspace: return .green
            case .transitive, .unknown: return .gray
            }
        }
    }
    var name: String
    var version: String
    var source: String
    var kind: Kind = .unknown
}

/// The packages a lock file pins, and which of them the project asks for directly.
struct LockFile {
    enum Format: String, CaseIterable {
        case npm = "package-lock.json", shrinkwrap = "npm-shrinkwrap.json", yarn = "yarn.lock", pnpm = "pnpm-lock.yaml"
        case bun = "bun.lock", cargo = "cargo.lock", gemfile = "gemfile.lock", poetry = "poetry.lock", uv = "uv.lock"
        case pipenv = "pipfile.lock", podfile = "podfile.lock", swiftpm = "package.resolved", composer = "composer.lock"
        case gosum = "go.sum", mix = "mix.lock", pubspec = "pubspec.lock", flake = "flake.lock"
        case gradle = "gradle.lockfile", nuget = "packages.lock.json"

        /// The tool, as people call it.
        var ecosystem: String {
            switch self {
            case .npm, .shrinkwrap: return "npm"
            case .yarn: return "Yarn"
            case .pnpm: return "pnpm"
            case .bun: return "Bun"
            case .cargo: return "Cargo"
            case .gemfile: return "Bundler"
            case .poetry: return "Poetry"
            case .uv: return "uv"
            case .pipenv: return "Pipenv"
            case .podfile: return "CocoaPods"
            case .swiftpm: return "Swift Package Manager"
            case .composer: return "Composer"
            case .gosum: return "Go Modules"
            case .mix: return "Mix"
            case .pubspec: return "pub"
            case .flake: return "Nix Flakes"
            case .gradle: return "Gradle"
            case .nuget: return "NuGet"
            }
        }
    }

    var format: Format
    var packages: [LockedPackage]
    /// "Lockfile v3", "Bundler 2.4.10"…
    var detail: String?

    var direct: Int { packages.filter { $0.kind == .direct || $0.kind == .directDev }.count }
    var knowsDirect: Bool { packages.contains { $0.kind != .unknown } }

    static func format(forName name: String) -> Format? { Format(rawValue: name.lowercased()) }

    static let readLimit = 48 * 1024 * 1024
    static let maxPackages = 50_000

    static func load(_ url: URL) throws -> LockFile? {
        guard let format = format(forName: url.lastPathComponent) else { return nil }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: readLimit) ?? Data()
        let manifests = Manifests(folder: url.deletingLastPathComponent())
        return parse(data, format: format, manifests: manifests)
    }

    static func parse(_ data: Data, format: Format, manifests: Manifests = Manifests(folder: nil)) -> LockFile? {
        let text = String(decoding: data, as: UTF8.self)
        var lock: LockFile?
        switch format {
        case .npm, .shrinkwrap: lock = npm(data, format: format)
        case .yarn: lock = yarn(text, manifests: manifests)
        case .pnpm: lock = pnpm(text)
        case .bun: lock = bun(data)
        case .cargo: lock = cargo(text)
        case .gemfile: lock = gemfile(text)
        case .poetry: lock = poetry(text, manifests: manifests)
        case .uv: lock = uv(text)
        case .pipenv: lock = pipenv(data)
        case .podfile: lock = podfile(text)
        case .swiftpm: lock = swiftpm(data)
        case .composer: lock = composer(data, manifests: manifests)
        case .gosum: lock = gosum(text, manifests: manifests)
        case .mix: lock = mix(text)
        case .pubspec: lock = pubspec(text)
        case .flake: lock = flake(data)
        case .gradle: lock = gradle(text)
        case .nuget: lock = nuget(data)
        }
        guard var result = lock else { return nil }
        if result.packages.count > maxPackages { result.packages = Array(result.packages.prefix(maxPackages)) }
        result.packages.sort { a, b in
            let order = a.name.localizedCaseInsensitiveCompare(b.name)
            return order == .orderedSame ? NaturalOrder.compare(Array(a.version.utf8), Array(b.version.utf8)) < 0 : order == .orderedAscending
        }
        return result
    }

    // MARK: - Helpers

    /// Where a package comes from, briefly: the registry's host, "git", "local".
    static func source(fromURL raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "" }
        if raw.hasPrefix("git+") || raw.hasPrefix("git:") || raw.hasPrefix("github:") || raw.hasSuffix(".git") { return "git" }
        if raw.hasPrefix("file:") || raw.hasPrefix("link:") || raw.hasPrefix("./") || raw.hasPrefix("../") || raw.hasPrefix("/") { return "local" }
        if let host = URL(string: raw)?.host { return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host }
        return raw
    }

    private static func json(_ data: Data, lenient: Bool = false) -> [String: Any]? {
        let options: JSONSerialization.ReadingOptions = lenient ? [.json5Allowed] : []
        return (try? JSONSerialization.jsonObject(with: data, options: options)) as? [String: Any]
    }

    /// The manifests next to a lock file, when they're there: they say which packages are direct.
    struct Manifests {
        let folder: URL?

        func read(_ name: String) -> Data? {
            guard let folder else { return nil }
            let url = folder.appendingPathComponent(name)
            guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size < 4 * 1024 * 1024 else { return nil }
            return try? Data(contentsOf: url)
        }

        /// package.json's dependencies: (production, development).
        func packageJSON() -> (Set<String>, Set<String>)? {
            guard let data = read("package.json"), let json = LockFile.json(data) else { return nil }
            let prod = Set(((json["dependencies"] as? [String: Any]) ?? [:]).keys).union(((json["optionalDependencies"] as? [String: Any]) ?? [:]).keys)
            let dev = Set(((json["devDependencies"] as? [String: Any]) ?? [:]).keys)
            return (prod, dev)
        }
    }

    private static func mark(_ packages: inout [LockedPackage], prod: Set<String>, dev: Set<String>, rest: LockedPackage.Kind = .transitive) {
        for i in packages.indices where packages[i].kind == .unknown || packages[i].kind == .dev {
            let name = packages[i].name
            if prod.contains(name) { packages[i].kind = dev.contains(name) ? .directDev : .direct }
            else if dev.contains(name) { packages[i].kind = .directDev }
            else if packages[i].kind == .unknown { packages[i].kind = rest }
        }
    }

    // MARK: - npm

    private static func npm(_ data: Data, format: Format) -> LockFile? {
        guard let json = json(data) else { return nil }
        let version = json["lockfileVersion"].map { "Lockfile v\($0)" }
        var packages: [LockedPackage] = []
        if let entries = json["packages"] as? [String: Any] {
            let root = entries[""] as? [String: Any] ?? [:]
            let prod = Set(((root["dependencies"] as? [String: Any]) ?? [:]).keys)
            let dev = Set(((root["devDependencies"] as? [String: Any]) ?? [:]).keys)
            let optional = Set(((root["optionalDependencies"] as? [String: Any]) ?? [:]).keys)
            for (path, value) in entries where !path.isEmpty {
                guard let info = value as? [String: Any], let range = path.range(of: "node_modules/", options: .backwards) else { continue }
                let name = info["name"] as? String ?? String(path[range.upperBound...])
                let nested = path.components(separatedBy: "node_modules/").count > 2
                var kind: LockedPackage.Kind = .transitive
                if info["link"] as? Bool == true { kind = .workspace }
                else if !nested, prod.contains(name) { kind = .direct }
                else if !nested, dev.contains(name) { kind = .directDev }
                else if !nested, optional.contains(name) { kind = .optional }
                else if info["dev"] as? Bool == true { kind = .dev }
                else if info["optional"] as? Bool == true { kind = .optional }
                let source = info["link"] as? Bool == true ? "local" : source(fromURL: info["resolved"] as? String)
                packages.append(LockedPackage(name: name, version: info["version"] as? String ?? "", source: source, kind: kind))
            }
        } else if let dependencies = json["dependencies"] as? [String: Any] {
            // Lockfile v1: a nested tree; the top level is what's installed at the top.
            func walk(_ tree: [String: Any], depth: Int) {
                guard depth < 32, packages.count < maxPackages else { return }
                for (name, value) in tree {
                    guard let info = value as? [String: Any] else { continue }
                    let kind: LockedPackage.Kind = info["dev"] as? Bool == true ? .dev : info["optional"] as? Bool == true ? .optional : .unknown
                    packages.append(LockedPackage(name: name, version: info["version"] as? String ?? "", source: source(fromURL: info["resolved"] as? String), kind: kind))
                    if let nested = info["dependencies"] as? [String: Any] { walk(nested, depth: depth + 1) }
                }
            }
            walk(dependencies, depth: 0)
        } else {
            return nil
        }
        return LockFile(format: format, packages: packages, detail: version)
    }

    // MARK: - Yarn

    /// "@babel/core@^7.0.0" → "@babel/core"; "lodash@npm:4.17.21" → "lodash".
    static func packageName(fromSpec spec: String) -> String {
        let trimmed = spec.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        let searchFrom = trimmed.hasPrefix("@") ? trimmed.index(after: trimmed.startIndex) : trimmed.startIndex
        if let at = trimmed[searchFrom...].firstIndex(of: "@") { return String(trimmed[..<at]) }
        return trimmed
    }

    private static func yarn(_ text: String, manifests: Manifests) -> LockFile? {
        let berry = text.contains("__metadata:")
        var packages: [LockedPackage] = []
        var current: LockedPackage?
        var specs = ""
        func flush() {
            if var package = current {
                if package.source.isEmpty, let protocolRange = specs.range(of: "@(npm|git|github|patch|workspace|file|portal|link|exec):", options: .regularExpression) {
                    let word = specs[protocolRange].dropFirst().dropLast()
                    package.source = word == "npm" ? "npm" : word == "workspace" || word == "portal" || word == "link" || word == "file" ? "local" : String(word)
                }
                if specs.contains("@workspace:") { package.kind = .workspace }
                packages.append(package)
            }
            current = nil
        }
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("#") || line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            if !line.hasPrefix(" ") {
                flush()
                guard line.hasSuffix(":"), !line.hasPrefix("__metadata") else { continue }
                specs = String(line.dropLast())
                let first = specs.split(separator: ",").first.map(String.init) ?? specs
                current = LockedPackage(name: packageName(fromSpec: first), version: "", source: "")
                continue
            }
            guard current != nil else { continue }
            let field = line.trimmingCharacters(in: .whitespaces)
            // Two-space fields only; deeper lines are dependency lists.
            guard line.hasPrefix("  "), !line.hasPrefix("    ") else { continue }
            if berry {
                if field.hasPrefix("version: ") { current?.version = String(field.dropFirst(9)).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
            } else {
                if field.hasPrefix("version ") { current?.version = String(field.dropFirst(8)).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
                if field.hasPrefix("resolved ") {
                    let url = String(field.dropFirst(9)).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                    current?.source = source(fromURL: url)
                }
            }
        }
        flush()
        guard !packages.isEmpty || text.contains("yarn lockfile") || berry else { return nil }
        if let (prod, dev) = manifests.packageJSON() { mark(&packages, prod: prod, dev: dev) }
        let detail = berry ? (text.range(of: #"version: (\d+)"#, options: .regularExpression).map { "Lockfile v" + text[$0].dropFirst(9) }) : "Lockfile v1"
        return LockFile(format: .yarn, packages: packages, detail: detail)
    }

    // MARK: - pnpm

    private static func indent(_ line: Substring) -> Int { line.prefix { $0 == " " }.count }

    private static func unquote(_ text: Substring) -> String {
        text.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
    }

    /// "/@scope/name@1.2.3(react@18)" (v6), "name@1.2.3" (v9), "/name/1.2.3_peer" (v5).
    static func pnpmKey(_ raw: String) -> (name: String, version: String) {
        var key = raw
        if key.hasPrefix("/") { key.removeFirst() }
        if let paren = key.firstIndex(of: "(") { key = String(key[..<paren]) }
        let name = packageName(fromSpec: key)
        if name.count < key.count, key[key.index(key.startIndex, offsetBy: name.count)] == "@" {
            return (name, String(key.dropFirst(name.count + 1)))
        }
        // v5: name/version (scoped: @scope/name/version)
        let parts = key.split(separator: "/")
        if parts.count >= 2 {
            let version = String(parts.last!).split(separator: "_").first.map(String.init) ?? String(parts.last!)
            return (parts.dropLast().joined(separator: "/"), version)
        }
        return (key, "")
    }

    private static func pnpm(_ text: String) -> LockFile? {
        var section = ""
        var importer = ""
        var importerSection = ""
        var prod = Set<String>(), dev = Set<String>(), optional = Set<String>()
        var packages: [String: LockedPackage] = [:]
        var order: [String] = []
        var currentKey: String?
        var version: String?
        for raw in text.split(separator: "\n") {
            let level = indent(raw)
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") || line.isEmpty { continue }
            if level == 0 {
                section = String(line.prefix { $0 != ":" })
                if section == "lockfileVersion" { version = "Lockfile v" + unquote(line.dropFirst(16)) }
                currentKey = nil
                continue
            }
            switch section {
            case "dependencies", "devDependencies", "optionalDependencies":
                if level == 2, let colon = line.firstIndex(of: ":") {
                    let name = unquote(line[..<colon])
                    if section == "dependencies" { prod.insert(name) } else if section == "devDependencies" { dev.insert(name) } else { optional.insert(name) }
                }
            case "importers":
                if level == 2 { importer = unquote(line.dropLast()) }
                else if level == 4 { importerSection = String(line.prefix { $0 != ":" }) }
                else if level == 6, importer == ".", let colon = line.firstIndex(of: ":") {
                    let name = unquote(line[..<colon])
                    if importerSection == "dependencies" { prod.insert(name) } else if importerSection == "devDependencies" { dev.insert(name) } else if importerSection == "optionalDependencies" { optional.insert(name) }
                }
            case "packages":
                if level == 2, line.hasSuffix(":") {
                    let key = unquote(line.dropLast())
                    let (name, version) = pnpmKey(key)
                    currentKey = name + "@" + version
                    if packages[currentKey!] == nil {
                        packages[currentKey!] = LockedPackage(name: name, version: version, source: "npm")
                        order.append(currentKey!)
                    }
                } else if level == 4, let key = currentKey {
                    if line == "dev: true" { packages[key]?.kind = .dev }
                    else if line == "optional: true" { packages[key]?.kind = .optional }
                    else if line.hasPrefix("resolution:") {
                        if let tarball = line.range(of: #"tarball: ([^,}]+)"#, options: .regularExpression) {
                            packages[key]?.source = source(fromURL: String(line[tarball].dropFirst(9)).trimmingCharacters(in: .whitespaces))
                        } else if line.contains("type: git") || line.contains("repo:") { packages[key]?.source = "git" }
                        else if line.contains("directory:") { packages[key]?.source = "local" }
                    }
                }
            default:
                break
            }
            if packages.count >= maxPackages { break }
        }
        guard version != nil || !packages.isEmpty else { return nil }
        var list = order.compactMap { packages[$0] }
        for i in list.indices {
            let name = list[i].name
            if prod.contains(name) { list[i].kind = dev.contains(name) ? .directDev : .direct }
            else if dev.contains(name) { list[i].kind = .directDev }
            else if optional.contains(name) { list[i].kind = .optional }
            else if list[i].kind == .unknown { list[i].kind = .transitive }
        }
        return LockFile(format: .pnpm, packages: list, detail: version)
    }

    // MARK: - Bun

    private static func bun(_ data: Data) -> LockFile? {
        guard let json = json(data, lenient: true), let entries = json["packages"] as? [String: Any] else { return nil }
        let root = ((json["workspaces"] as? [String: Any])?[""] as? [String: Any]) ?? [:]
        let prod = Set(((root["dependencies"] as? [String: Any]) ?? [:]).keys).union(((root["optionalDependencies"] as? [String: Any]) ?? [:]).keys)
        let dev = Set(((root["devDependencies"] as? [String: Any]) ?? [:]).keys)
        var packages: [LockedPackage] = []
        for (key, value) in entries {
            guard let info = value as? [Any], let spec = info.first as? String else { continue }
            let name = packageName(fromSpec: spec)
            let version = spec.count > name.count + 1 ? String(spec.dropFirst(name.count + 1)) : ""
            let registry = info.count > 1 ? info[1] as? String : nil
            let source = version.hasPrefix("workspace:") ? "local" : registry.map { $0.isEmpty ? "npm" : LockFile.source(fromURL: $0) } ?? "npm"
            // Nested installs are keyed "parent/child".
            let nested = key.contains("/") && !(key.hasPrefix("@") && key.split(separator: "/").count == 2)
            var package = LockedPackage(name: name, version: version, source: source)
            if !nested, prod.contains(name) { package.kind = .direct } else if !nested, dev.contains(name) { package.kind = .directDev } else { package.kind = .transitive }
            packages.append(package)
        }
        return LockFile(format: .bun, packages: packages, detail: json["lockfileVersion"].map { "Lockfile v\($0)" })
    }

    // MARK: - TOML lock files (Cargo, Poetry, uv)

    /// `[[package]]` tables from a TOML lock file: keys to raw values, plus sub-tables
    /// (`[package.source]`) under "table.<name>".
    static func tomlPackages(_ text: String) -> [[String: String]] {
        var packages: [[String: String]] = []
        var current: [String: String]?
        var subtable: String?
        var pendingKey: String?
        var pendingValue = ""
        var depth = 0
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let key = pendingKey {
                // Continue a multi-line array.
                pendingValue += " " + line
                depth += line.filter { $0 == "[" }.count - line.filter { $0 == "]" }.count
                if depth <= 0 {
                    current?[subtable.map { "table.\($0).\(key)" } ?? key] = pendingValue
                    pendingKey = nil
                }
                continue
            }
            if line.hasPrefix("#") || line.isEmpty { continue }
            if line == "[[package]]" {
                if let current { packages.append(current) }
                current = [:]
                subtable = nil
                if packages.count >= maxPackages { break }
                continue
            }
            if line.hasPrefix("[") {
                // [package.source], [package.dependencies]… belong to the current package.
                if line.hasPrefix("[package.") || line.hasPrefix("[[package.") {
                    subtable = String(line.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).dropFirst(8))
                } else {
                    if let c = current { packages.append(c) }
                    current = nil
                    subtable = nil
                }
                continue
            }
            guard current != nil, let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            let open = value.filter { $0 == "[" }.count - value.filter { $0 == "]" }.count
            if open > 0 {
                pendingKey = key
                pendingValue = value
                depth = open
                continue
            }
            current?[subtable.map { "table.\($0).\(key)" } ?? key] = value
        }
        if let current { packages.append(current) }
        return packages
    }

    static func tomlString(_ raw: String?) -> String {
        guard let raw else { return "" }
        return raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
    }

    /// Names inside a TOML array of strings ("serde 1.0.0 (registry+…)") or of inline tables ({ name = "x" }).
    static func tomlNames(_ raw: String?) -> [String] {
        guard let raw else { return [] }
        if raw.contains("name") {
            return raw.matches(of: #/name\s*=\s*"([^"]+)"/#).map { String($0.output.1) }
        }
        return raw.matches(of: #/"([^"]+)"/#).map { String($0.output.1).split(separator: " ").first.map(String.init) ?? "" }
    }

    private static func cargo(_ text: String) -> LockFile? {
        let tables = tomlPackages(text)
        guard !tables.isEmpty else { return nil }
        var direct = Set<String>()
        for table in tables where table["source"] == nil { direct.formUnion(tomlNames(table["dependencies"])) }
        let packages = tables.map { table -> LockedPackage in
            let name = tomlString(table["name"])
            let raw = tomlString(table["source"])
            let source: String
            if raw.isEmpty { source = "local" }
            else if raw.contains("crates.io-index") || raw.hasPrefix("sparse+https://index.crates.io") { source = "crates.io" }
            else if raw.hasPrefix("git+") { source = "git" }
            else { source = LockFile.source(fromURL: raw.replacingOccurrences(of: "registry+", with: "")) }
            let kind: LockedPackage.Kind = raw.isEmpty ? .workspace : direct.contains(name) ? .direct : .transitive
            return LockedPackage(name: name, version: tomlString(table["version"]), source: source, kind: kind)
        }
        let version = text.range(of: #"(?m)^version = (\d+)"#, options: .regularExpression).map { "Lockfile v" + text[$0].split(separator: " ").last! }
        return LockFile(format: .cargo, packages: packages, detail: version)
    }

    private static func poetry(_ text: String, manifests: Manifests) -> LockFile? {
        let tables = tomlPackages(text)
        guard !tables.isEmpty else { return nil }
        var packages = tables.map { table -> LockedPackage in
            let type = tomlString(table["table.source.type"])
            let source = type.isEmpty ? "PyPI" : type == "legacy" ? LockFile.source(fromURL: tomlString(table["table.source.url"])) : type
            let kind: LockedPackage.Kind = tomlString(table["category"]) == "dev" ? .dev : .unknown
            return LockedPackage(name: tomlString(table["name"]), version: tomlString(table["version"]), source: source, kind: kind)
        }
        if let (prod, dev) = pyproject(manifests) { mark(&packages, prod: prod, dev: dev) }
        return LockFile(format: .poetry, packages: packages, detail: nil)
    }

    /// pyproject.toml's dependencies, Poetry style or PEP 621.
    static func pyproject(_ manifests: Manifests) -> (Set<String>, Set<String>)? {
        guard let data = manifests.read("pyproject.toml") else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        var prod = Set<String>(), dev = Set<String>()
        var section = ""
        var inArray: String?
        func normalized(_ name: String) -> String { name.lowercased().replacingOccurrences(of: "_", with: "-") }
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { section = line; inArray = nil; continue }
            if let target = inArray {
                for match in line.matches(of: #/"([A-Za-z0-9_.\-]+)/#) {
                    if target == "prod" { prod.insert(normalized(String(match.output.1))) } else { dev.insert(normalized(String(match.output.1))) }
                }
                if line.contains("]") { inArray = nil }
                continue
            }
            if section == "[tool.poetry.dependencies]", let eq = line.firstIndex(of: "=") {
                let name = line[..<eq].trimmingCharacters(in: .whitespaces)
                if name != "python" { prod.insert(normalized(name)) }
            } else if section.hasPrefix("[tool.poetry.group.") && section.hasSuffix(".dependencies]") || section == "[tool.poetry.dev-dependencies]",
                      let eq = line.firstIndex(of: "=") {
                dev.insert(normalized(line[..<eq].trimmingCharacters(in: .whitespaces)))
            } else if section == "[project]", line.hasPrefix("dependencies") {
                inArray = "prod"
                for match in line.matches(of: #/"([A-Za-z0-9_.\-]+)/#) { prod.insert(normalized(String(match.output.1))) }
                if line.contains("]") { inArray = nil }
            } else if section == "[dependency-groups]" || section == "[project.optional-dependencies]", line.contains("= [") {
                inArray = "dev"
                for match in line.matches(of: #/"([A-Za-z0-9_.\-]+)/#) { dev.insert(normalized(String(match.output.1))) }
                if line.hasSuffix("]") { inArray = nil }
            }
        }
        return prod.isEmpty && dev.isEmpty ? nil : (prod, dev)
    }

    private static func uv(_ text: String) -> LockFile? {
        let tables = tomlPackages(text)
        guard !tables.isEmpty else { return nil }
        var direct = Set<String>(), dev = Set<String>()
        for table in tables {
            let source = table["source"] ?? ""
            guard source.contains("editable") || source.contains("virtual") else { continue }
            direct.formUnion(tomlNames(table["dependencies"]))
            for (key, value) in table where key.hasPrefix("table.dev-dependencies.") || key.hasPrefix("table.optional-dependencies.") {
                dev.formUnion(tomlNames(value))
            }
        }
        let packages = tables.map { table -> LockedPackage in
            let raw = table["source"] ?? ""
            let name = tomlString(table["name"])
            var source = "PyPI"
            var kind: LockedPackage.Kind = direct.contains(name) ? .direct : dev.contains(name) ? .directDev : .transitive
            if raw.contains("editable") || raw.contains("virtual") { source = "local"; kind = .workspace }
            else if raw.contains("git") { source = "git" }
            else if raw.contains("path") || raw.contains("directory") { source = "local" }
            else if let match = raw.firstMatch(of: #/registry\s*=\s*"([^"]+)"/#) {
                let host = LockFile.source(fromURL: String(match.output.1))
                source = host == "pypi.org" ? "PyPI" : host
            }
            return LockedPackage(name: name, version: tomlString(table["version"]), source: source, kind: kind)
        }
        return LockFile(format: .uv, packages: packages, detail: nil)
    }

    // MARK: - Pipenv

    private static func pipenv(_ data: Data) -> LockFile? {
        guard let json = json(data) else { return nil }
        var packages: [LockedPackage] = []
        for (section, kind) in [("default", LockedPackage.Kind.unknown), ("develop", .dev)] {
            for (name, value) in (json[section] as? [String: Any]) ?? [:] {
                let info = value as? [String: Any] ?? [:]
                let version = (info["version"] as? String ?? "").replacingOccurrences(of: "==", with: "")
                let source = info["git"] != nil ? "git" : info["path"] != nil ? "local" : (info["index"] as? String).map { $0 == "pypi" ? "PyPI" : $0 } ?? "PyPI"
                packages.append(LockedPackage(name: name, version: version, source: source, kind: kind))
            }
        }
        guard !packages.isEmpty || json["_meta"] != nil else { return nil }
        return LockFile(format: .pipenv, packages: packages, detail: nil)
    }

    // MARK: - Ruby

    private static func gemfile(_ text: String) -> LockFile? {
        var packages: [LockedPackage] = []
        var section = ""
        var remote = ""
        var direct = Set<String>()
        var bundler: String?
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, raw) in lines.enumerated() {
            let level = indent(raw)
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if level == 0 { section = line; remote = ""; continue }
            switch section {
            case "GEM", "GIT", "PATH", "PLUGIN SOURCE":
                if level == 2, line.hasPrefix("remote: ") {
                    let url = String(line.dropFirst(8))
                    remote = section == "GIT" ? "git" : section == "PATH" ? "local" : LockFile.source(fromURL: url)
                } else if level == 4, let open = line.firstIndex(of: "(") {
                    let name = line[..<open].trimmingCharacters(in: .whitespaces)
                    let version = line[line.index(after: open)...].trimmingCharacters(in: CharacterSet(charactersIn: ") "))
                    packages.append(LockedPackage(name: name, version: version, source: remote, kind: section == "PATH" ? .workspace : .unknown))
                }
            case "DEPENDENCIES":
                if level == 2 {
                    direct.insert(String(line.prefix { $0 != " " && $0 != "!" && $0 != "(" }))
                }
            case "BUNDLED WITH":
                bundler = line
            default:
                break
            }
            if index > 2_000_000 { break }
        }
        guard !packages.isEmpty else { return nil }
        for i in packages.indices where packages[i].kind == .unknown {
            packages[i].kind = direct.contains(packages[i].name) ? .direct : .transitive
        }
        return LockFile(format: .gemfile, packages: packages, detail: bundler.map { "Bundler \($0)" })
    }

    // MARK: - CocoaPods

    private static func podfile(_ text: String) -> LockFile? {
        var section = ""
        var pods: [(String, String)] = []
        var direct = Set<String>()
        var repos: [String: String] = [:]
        var external: [String: String] = [:]
        var currentRepo = ""
        var currentExternal = ""
        var cocoapods: String?
        for raw in text.split(separator: "\n") {
            let level = indent(raw)
            let line = raw.trimmingCharacters(in: .whitespaces)
            if level == 0 {
                section = String(line.prefix { $0 != ":" })
                if section == "COCOAPODS" { cocoapods = line.dropFirst(10).trimmingCharacters(in: .whitespaces) }
                continue
            }
            switch section {
            case "PODS":
                if level == 2, line.hasPrefix("- ") {
                    var entry = String(line.dropFirst(2))
                    if entry.hasSuffix(":") { entry.removeLast() }
                    entry = entry.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                    if let open = entry.firstIndex(of: "(") {
                        pods.append((entry[..<open].trimmingCharacters(in: .whitespaces), entry[entry.index(after: open)...].trimmingCharacters(in: CharacterSet(charactersIn: ") "))))
                    }
                }
            case "DEPENDENCIES":
                if line.hasPrefix("- ") {
                    let entry = line.dropFirst(2).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                    direct.insert(entry.prefix { $0 != " " && $0 != "(" }.description)
                }
            case "SPEC REPOS":
                if level == 2 { currentRepo = String(line.dropLast()).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
                else if line.hasPrefix("- ") { repos[line.dropFirst(2).trimmingCharacters(in: CharacterSet(charactersIn: "\""))] = currentRepo == "trunk" ? "CocoaPods trunk" : LockFile.source(fromURL: currentRepo) }
            case "EXTERNAL SOURCES":
                if level == 2 { currentExternal = String(line.dropLast()).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
                else if line.hasPrefix(":path") { external[currentExternal] = "local" }
                else if line.hasPrefix(":git") { external[currentExternal] = "git" }
                else if line.hasPrefix(":podspec") { external[currentExternal] = "podspec" }
            default:
                break
            }
        }
        guard !pods.isEmpty else { return nil }
        let packages = pods.map { name, version -> LockedPackage in
            let root = String(name.split(separator: "/").first ?? Substring(name))
            let source = external[root] ?? repos[root] ?? ""
            let kind: LockedPackage.Kind = direct.contains(name) || direct.contains(root) ? .direct : .transitive
            return LockedPackage(name: name, version: version, source: source, kind: kind)
        }
        return LockFile(format: .podfile, packages: packages, detail: cocoapods.map { "CocoaPods \($0)" })
    }

    // MARK: - Swift Package Manager

    private static func swiftpm(_ data: Data) -> LockFile? {
        guard let json = json(data) else { return nil }
        let pins = (json["pins"] as? [[String: Any]]) ?? ((json["object"] as? [String: Any])?["pins"] as? [[String: Any]]) ?? []
        guard !pins.isEmpty || json["version"] != nil else { return nil }
        let packages = pins.map { pin -> LockedPackage in
            let state = pin["state"] as? [String: Any] ?? [:]
            let version = state["version"] as? String ?? (state["branch"] as? String).map { "branch \($0)" }
                ?? (state["revision"] as? String).map { String($0.prefix(7)) } ?? ""
            let location = pin["location"] as? String ?? pin["repositoryURL"] as? String
            let name = pin["identity"] as? String ?? pin["package"] as? String ?? location.map { ($0 as NSString).lastPathComponent.replacingOccurrences(of: ".git", with: "") } ?? ""
            let kind = pin["kind"] as? String
            return LockedPackage(name: name, version: version, source: kind == "localSourceControl" || kind == "fileSystem" ? "local" : source(fromURL: location))
        }
        return LockFile(format: .swiftpm, packages: packages, detail: json["version"].map { "Format v\($0)" })
    }

    // MARK: - Composer

    private static func composer(_ data: Data, manifests: Manifests) -> LockFile? {
        guard let json = json(data), json["packages"] != nil else { return nil }
        var packages: [LockedPackage] = []
        for (section, kind) in [("packages", LockedPackage.Kind.unknown), ("packages-dev", .dev)] {
            for info in (json[section] as? [[String: Any]]) ?? [] {
                let source = (info["source"] as? [String: Any])?["url"] as? String ?? (info["dist"] as? [String: Any])?["url"] as? String
                packages.append(LockedPackage(name: info["name"] as? String ?? "", version: info["version"] as? String ?? "",
                                              source: LockFile.source(fromURL: source), kind: kind))
            }
        }
        if let manifest = manifests.read("composer.json").flatMap({ LockFile.json($0) }) {
            let prod = Set(((manifest["require"] as? [String: Any]) ?? [:]).keys)
            let dev = Set(((manifest["require-dev"] as? [String: Any]) ?? [:]).keys)
            mark(&packages, prod: prod, dev: dev)
        }
        return LockFile(format: .composer, packages: packages, detail: nil)
    }

    // MARK: - Go

    private static func gosum(_ text: String, manifests: Manifests) -> LockFile? {
        var seen = Set<String>()
        var packages: [LockedPackage] = []
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ")
            guard parts.count == 3, parts[2].hasPrefix("h1:") else { continue }
            // "/go.mod" lines only vouch for a module's go.mod; the module itself has its own line.
            guard !parts[1].hasSuffix("/go.mod") else { continue }
            let key = parts[0] + "@" + parts[1]
            guard seen.insert(String(key)).inserted else { continue }
            let module = String(parts[0])
            let host = module.split(separator: "/").first.map(String.init) ?? module
            packages.append(LockedPackage(name: module, version: String(parts[1]), source: host))
        }
        guard !packages.isEmpty else { return nil }
        if let data = manifests.read("go.mod") {
            var direct = Set<String>(), indirect = Set<String>()
            var inRequire = false
            for raw in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                var line = raw.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("require (") { inRequire = true; continue }
                if inRequire, line == ")" { inRequire = false; continue }
                if line.hasPrefix("require ") { line = String(line.dropFirst(8)) } else if !inRequire { continue }
                let module = String(line.prefix { $0 != " " })
                if line.contains("// indirect") { indirect.insert(module) } else { direct.insert(module) }
            }
            for i in packages.indices {
                packages[i].kind = direct.contains(packages[i].name) ? .direct : .transitive
            }
        }
        return LockFile(format: .gosum, packages: packages, detail: nil)
    }

    // MARK: - Elixir

    private static func mix(_ text: String) -> LockFile? {
        var packages: [LockedPackage] = []
        for line in text.split(separator: "\n") {
            guard let match = line.firstMatch(of: #/^\s*"([^"]+)":\s*\{:(\w+),\s*(.*)$/#) else { continue }
            let name = String(match.output.1)
            let kind = String(match.output.2)
            let rest = String(match.output.3)
            let strings = rest.matches(of: #/"([^"]*)"/#).map { String($0.output.1) }
            switch kind {
            case "hex":
                let repo = strings.count > 3 ? strings[3] : "hexpm"
                packages.append(LockedPackage(name: name, version: strings.first ?? "", source: repo == "hexpm" ? "Hex" : repo))
            case "git":
                let ref = strings.count > 1 ? String(strings[1].prefix(7)) : ""
                packages.append(LockedPackage(name: name, version: ref, source: "git"))
            case "path":
                packages.append(LockedPackage(name: name, version: "", source: "local"))
            default:
                packages.append(LockedPackage(name: name, version: strings.first ?? "", source: kind))
            }
        }
        return packages.isEmpty ? nil : LockFile(format: .mix, packages: packages, detail: nil)
    }

    // MARK: - Dart

    private static func pubspec(_ text: String) -> LockFile? {
        var section = ""
        var packages: [LockedPackage] = []
        var current: LockedPackage?
        var sdk: String?
        func flush() { if let current { packages.append(current) }; current = nil }
        for raw in text.split(separator: "\n") {
            let level = indent(raw)
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") || line.isEmpty { continue }
            if level == 0 { flush(); section = String(line.prefix { $0 != ":" }); continue }
            if section == "sdks", level == 2, line.hasPrefix("dart:") { sdk = "Dart " + unquote(line.dropFirst(5)) }
            guard section == "packages" else { continue }
            if level == 2, line.hasSuffix(":") {
                flush()
                current = LockedPackage(name: unquote(line.dropLast()), version: "", source: "")
            } else if level == 4, current != nil {
                if line.hasPrefix("version:") { current?.version = unquote(line.dropFirst(8)) }
                else if line.hasPrefix("source:") {
                    let value = unquote(line.dropFirst(7))
                    let existing = current?.source ?? ""
                    current?.source = value == "hosted" ? (existing.isEmpty ? "pub.dev" : existing) : value == "path" ? "local" : value
                } else if line.hasPrefix("dependency:") {
                    let value = unquote(line.dropFirst(11))
                    current?.kind = value == "direct main" ? .direct : value == "direct dev" ? .directDev : value == "direct overridden" ? .direct : .transitive
                }
            } else if level == 6, line.hasPrefix("url:"), current?.source != "git" {
                let host = LockFile.source(fromURL: unquote(line.dropFirst(4)))
                current?.source = host
            }
        }
        flush()
        return packages.isEmpty ? nil : LockFile(format: .pubspec, packages: packages, detail: sdk)
    }

    // MARK: - Nix

    private static func flake(_ data: Data) -> LockFile? {
        guard let json = json(data), let nodes = json["nodes"] as? [String: Any] else { return nil }
        let rootName = json["root"] as? String ?? "root"
        let direct = Set((((nodes[rootName] as? [String: Any])?["inputs"] as? [String: Any]) ?? [:]).keys)
        var packages: [LockedPackage] = []
        for (name, value) in nodes where name != rootName {
            guard let node = value as? [String: Any], let locked = node["locked"] as? [String: Any] else { continue }
            let type = locked["type"] as? String ?? ""
            var source = type
            if let owner = locked["owner"] as? String, let repo = locked["repo"] as? String { source = "\(type):\(owner)/\(repo)" }
            else if let url = locked["url"] as? String { source = LockFile.source(fromURL: url) }
            else if type == "path" { source = "local" }
            let version = (locked["rev"] as? String).map { String($0.prefix(7)) } ?? (locked["narHash"] as? String).map { String($0.prefix(12)) } ?? ""
            packages.append(LockedPackage(name: name, version: version, source: source, kind: direct.contains(name) ? .direct : .transitive))
        }
        return LockFile(format: .flake, packages: packages, detail: json["version"].map { "Format v\($0)" })
    }

    // MARK: - Gradle

    private static func gradle(_ text: String) -> LockFile? {
        var packages: [LockedPackage] = []
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), !line.hasPrefix("empty="), let equals = line.firstIndex(of: "=") else { continue }
            let coordinates = line[..<equals].split(separator: ":")
            guard coordinates.count >= 3 else { continue }
            let classpaths = line[line.index(after: equals)...].split(separator: ",").map(String.init)
            let testOnly = !classpaths.isEmpty && classpaths.allSatisfy { $0.lowercased().contains("test") }
            packages.append(LockedPackage(name: "\(coordinates[0]):\(coordinates[1])", version: String(coordinates[2]), source: "Maven",
                                          kind: testOnly ? .dev : .unknown))
        }
        return packages.isEmpty ? nil : LockFile(format: .gradle, packages: packages, detail: nil)
    }

    // MARK: - NuGet

    private static func nuget(_ data: Data) -> LockFile? {
        guard let json = json(data), let frameworks = json["dependencies"] as? [String: Any] else { return nil }
        var seen = Set<String>()
        var packages: [LockedPackage] = []
        for (_, value) in frameworks.sorted(by: { $0.key < $1.key }) {
            for (name, entry) in (value as? [String: Any]) ?? [:] {
                guard let info = entry as? [String: Any] else { continue }
                let version = info["resolved"] as? String ?? ""
                guard seen.insert(name + "@" + version).inserted else { continue }
                let type = info["type"] as? String ?? ""
                let kind: LockedPackage.Kind = type == "Direct" ? .direct : type == "Project" ? .workspace : .transitive
                packages.append(LockedPackage(name: name, version: version, source: type == "Project" ? "local" : "NuGet", kind: kind))
            }
        }
        return LockFile(format: .nuget, packages: packages, detail: json["version"].map { "Format v\($0)" })
    }
}
