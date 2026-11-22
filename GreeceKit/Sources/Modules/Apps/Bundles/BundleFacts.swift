import AppKit

/// Everything Greece learns about a bundle (an app, extension, framework, plug-in…), read once
/// off the main thread from a `BundleSource`.
struct BundleFacts {
    enum Layout { case macOS, shallow, framework }

    struct Nested {
        enum Role: String {
            case appExtension = "Extension"
            case systemExtension = "System Extension"
            case framework = "Framework"
            case loginItem = "Login Item"
            case helper = "Helper"
            case xpcService = "XPC Service"
            case privilegedHelper = "Privileged Helper"
            case launchAgent = "Launch Agent"
            case launchDaemon = "Launch Daemon"
            case plugin = "Plug-in"
            case watchApp = "Watch App"
            case appClip = "App Clip"

            /// What people read: "Extension", "Login Item".
            var title: String {
                switch self {
                case .appExtension: return String(localized: "Extension", bundle: .greeceKit, comment: "A kind of item inside an app: an app extension")
                case .systemExtension: return String(localized: "System Extension", bundle: .greeceKit)
                case .framework: return String(localized: "Framework", bundle: .greeceKit, comment: "A kind of bundle: a code library")
                case .loginItem: return String(localized: "Login Item", bundle: .greeceKit)
                case .helper: return String(localized: "Helper", bundle: .greeceKit, comment: "Inspector row subtitle: a helper app inside an app")
                case .xpcService: return String(localized: "XPC Service", bundle: .greeceKit)
                case .privilegedHelper: return String(localized: "Privileged Helper", bundle: .greeceKit)
                case .launchAgent: return String(localized: "Launch Agent", bundle: .greeceKit)
                case .launchDaemon: return String(localized: "Launch Daemon", bundle: .greeceKit)
                case .plugin: return String(localized: "Plug-in", bundle: .greeceKit, comment: "A kind of bundle")
                case .watchApp: return String(localized: "Watch App", bundle: .greeceKit, comment: "An Apple Watch app inside an iOS app")
                case .appClip: return "App Clip"
                }
            }
        }
        var path: String
        var role: Role
        var name: String
        var identifier: String?
        var version: String?
        var extensionPoint: String?
        var teamID: String?
        var size: UInt64 = 0
    }

    let source: BundleSource
    var layout: Layout
    /// Path prefix inside the bundle ("Contents/" or "").
    var contents: String
    var info: [String: Any]
    var executablePath: String?
    var macho: MachOFile?
    var signature: CodeSignature?
    var files: [(path: String, size: UInt64)] = []
    var filesComplete = true
    var nested: [Nested] = []
    var profile: ProvisioningProfile?
    var privacyManifest: [String: Any]?
    var localizations: [String] = []
    var technologies: [String] = []
    /// An iOS app that macOS runs on Apple silicon ("Wrapper/X.app").
    var isWrappedIOSApp = false
    var icon: NSImage?

    var extensionName: String { (source.name as NSString).pathExtension.lowercased() }

    var name: String {
        for key in ["CFBundleDisplayName", "CFBundleName"] {
            if let value = info[key] as? String, !value.trimmingCharacters(in: .whitespaces).isEmpty { return Format.clean(value, limit: 120) }
        }
        return (source.name as NSString).deletingPathExtension
    }

    var identifier: String? { (info["CFBundleIdentifier"] as? String).map { Format.clean($0, limit: 200) } }
    var shortVersion: String? { (info["CFBundleShortVersionString"] as? String).map { Format.clean($0, limit: 60) } }
    var buildVersion: String? { (info["CFBundleVersion"] as? String).map { Format.clean($0, limit: 60) } }

    var isIOS: Bool {
        if isWrappedIOSApp { return true }
        if let platforms = info["CFBundleSupportedPlatforms"] as? [String] {
            if platforms.contains("MacOSX") { return false }
            if platforms.contains(where: { ["iPhoneOS", "iPhoneSimulator", "AppleTVOS", "WatchOS", "XROS"].contains($0) }) { return true }
        }
        if let build = macho?.preferredSlice?.builds.first {
            return [.iOS, .iOSSimulator, .tvOS, .watchOS, .visionOS].contains(build.platform)
        }
        return layout == .shallow && info["MinimumOSVersion"] != nil
    }

    var isCatalyst: Bool { macho?.preferredSlice?.builds.contains { $0.platform == .macCatalyst } ?? false }

    var kindTitle: String {
        switch extensionName {
        case "app":
            if isWrappedIOSApp { return String(localized: "iPhone and iPad App", bundle: .greeceKit) }
            return isIOS ? BundleFacts.iOSAppTitle : String(localized: "Application", bundle: .greeceKit, comment: "Info bar title and inspector row value: a kind of bundle")
        case "appex": return String(localized: "App Extension", bundle: .greeceKit)
        case "framework": return String(localized: "Framework", bundle: .greeceKit, comment: "A kind of bundle: a code library")
        case "kext": return String(localized: "Kernel Extension", bundle: .greeceKit)
        case "systemextension": return String(localized: "System Extension", bundle: .greeceKit)
        case "xpc": return String(localized: "XPC Service", bundle: .greeceKit)
        case "plugin": return String(localized: "Plug-in", bundle: .greeceKit, comment: "A kind of bundle")
        case "qlgenerator": return String(localized: "Quick Look Generator", bundle: .greeceKit)
        case "saver": return String(localized: "Screen Saver", bundle: .greeceKit)
        case "prefpane": return String(localized: "Preference Pane", bundle: .greeceKit)
        case "mdimporter": return String(localized: "Spotlight Importer", bundle: .greeceKit)
        case "dext": return String(localized: "Driver Extension", bundle: .greeceKit)
        default: return String(localized: "Bundle", bundle: .greeceKit, comment: "Info bar title and inspector row value: a kind of file (a macOS bundle)")
        }
    }

    static var iOSAppTitle: String {
        String(localized: "iOS App", bundle: .greeceKit, comment: "Info bar title and inspector row value: a kind of app")
    }

    var symbol: String {
        switch extensionName {
        case "app": return "app.dashed"
        case "appex", "plugin", "qlgenerator", "mdimporter": return "puzzlepiece.extension"
        case "framework": return "shippingbox"
        case "kext", "systemextension", "dext": return "cpu"
        case "xpc": return "gearshape.2"
        default: return "shippingbox"
        }
    }

    var entitlements: [String: Any] { signature?.entitlements ?? [:] }
    var isSandboxed: Bool { entitlements["com.apple.security.app-sandbox"] as? Bool == true }
    var totalSize: UInt64 { files.reduce(0) { $0.saturatingAdd($1.size) } }

    var minimumSystem: String? {
        if let value = info["LSMinimumSystemVersion"] as? String { return value }
        if let value = info["MinimumOSVersion"] as? String { return value }
        return macho?.preferredSlice?.builds.first?.minimum
    }

    // MARK: Reading

    static let fileLimit = 150_000
    static let nestedLimit = 96

    init?(source: BundleSource, deadline: Date = Date().addingTimeInterval(0.25)) {
        if !source.exists("Contents/Info.plist"), !source.exists("Resources/Info.plist"), !source.exists("Info.plist"),
           source.isDirectory("Wrapper"), let inner = source.children("Wrapper").first(where: { $0.hasSuffix(".app") }),
           let url = source.url?.appendingPathComponent("Wrapper/" + inner) {
            // iOS apps installed on a Mac: the real bundle sits inside a wrapper.
            guard var wrapped = BundleFacts(source: DirectoryBundle(url: url), deadline: deadline) else { return nil }
            wrapped.isWrappedIOSApp = true
            self = wrapped
            return
        }
        self.source = source
        if source.exists("Contents/Info.plist") {
            layout = .macOS
            contents = "Contents/"
        } else if source.exists("Resources/Info.plist") {
            layout = .framework
            contents = ""
        } else if source.exists("Info.plist") {
            layout = .shallow
            contents = ""
        } else {
            return nil
        }
        let infoPath = layout == .framework ? "Resources/Info.plist" : contents + "Info.plist"
        info = source.plist(infoPath) ?? [:]

        // Executable: named by the Info.plist, else the bundle's own name.
        let executableName = (info["CFBundleExecutable"] as? String).map { ($0 as NSString).lastPathComponent }
            ?? (source.name as NSString).deletingPathExtension
        let executableDirectory = layout == .macOS ? "Contents/MacOS/" : ""
        let candidate = executableDirectory + executableName
        if !executableName.isEmpty, !executableName.contains(".."), source.exists(candidate), !source.isDirectory(candidate) {
            executablePath = candidate
        }
        if let path = executablePath, let bytes = source.bytes(path), let file = try? MachOFile.parse(bytes) {
            macho = file
            signature = CodeSignature.read(from: bytes, macho: file)
        }

        let listing = source.files(limit: Self.fileLimit, deadline: deadline)
        files = listing.files
        filesComplete = listing.complete
        // Localizations come from the Resources folder itself, so huge bundles don't need a full walk.
        let resources = layout == .macOS ? "Contents/Resources" : layout == .framework ? "Resources" : ""
        localizations = source.children(resources).filter { $0.hasSuffix(".lproj") && $0 != "Base.lproj" }
            .map { String($0.dropLast(".lproj".count)) }.sorted()
        nested = readNested()
        sizeNested()
        let profilePath = layout == .macOS ? "Contents/embedded.provisionprofile" : "embedded.mobileprovision"
        if let data = source.data(profilePath, limit: ProvisioningProfile.maxSize) { profile = ProvisioningProfile(data: data) }
        let privacyPath = layout == .macOS ? "Contents/Resources/PrivacyInfo.xcprivacy" : layout == .framework ? "Resources/PrivacyInfo.xcprivacy" : "PrivacyInfo.xcprivacy"
        privacyManifest = source.plist(privacyPath, limit: 1 << 20)
        technologies = detectTechnologies()
    }

    /// Walks every file with a generous budget (for the deferred Size section of very large bundles).
    func measured(seconds: TimeInterval = 5) -> BundleFacts {
        var copy = self
        let listing = source.files(limit: 2_000_000, deadline: Date().addingTimeInterval(seconds))
        copy.files = listing.files
        copy.filesComplete = listing.complete
        copy.sizeNested()
        return copy
    }

    private static func localizations(in files: [(path: String, size: UInt64)], resources: String) -> [String] {
        var names = Set<String>()
        for file in files where file.path.hasPrefix(resources) {
            let rest = file.path.dropFirst(resources.count)
            guard let first = rest.split(separator: "/").first, first.hasSuffix(".lproj"), rest.contains("/") else { continue }
            let code = String(first.dropLast(".lproj".count))
            if code != "Base" { names.insert(code) }
            if names.count > 400 { break }
        }
        return names.sorted()
    }

    private func readNested() -> [Nested] {
        var result: [Nested] = []
        let c = contents
        let locations: [(String, Nested.Role)] = layout == .macOS ? [
            (c + "PlugIns", .appExtension), (c + "Extensions", .appExtension), (c + "Library/SystemExtensions", .systemExtension),
            (c + "Library/LoginItems", .loginItem), (c + "Library/LaunchServices", .privilegedHelper), (c + "XPCServices", .xpcService),
            (c + "Helpers", .helper), (c + "Library/QuickLook", .plugin), (c + "Library/Spotlight", .plugin),
            (c + "Library/LaunchAgents", .launchAgent), (c + "Library/LaunchDaemons", .launchDaemon), (c + "Frameworks", .framework),
        ] : [
            ("PlugIns", .appExtension), ("Extensions", .appExtension), ("Watch", .watchApp), ("AppClips", .appClip), ("Frameworks", .framework),
        ]
        for (directory, role) in locations where source.isDirectory(directory) {
            for child in source.children(directory) {
                if result.count >= Self.nestedLimit { return result }
                let path = directory + "/" + child
                if role == .launchAgent || role == .launchDaemon {
                    guard child.hasSuffix(".plist"), let plist = source.plist(path, limit: 256 * 1024) else { continue }
                    let label = plist["Label"] as? String ?? (child as NSString).deletingPathExtension
                    let program = (plist["BundleProgram"] as? String) ?? (plist["Program"] as? String) ?? ((plist["ProgramArguments"] as? [String])?.first)
                    result.append(Nested(path: path, role: role, name: Format.clean(label, limit: 120), identifier: program.map { Format.clean($0, limit: 200) }))
                    continue
                }
                let ext = (child as NSString).pathExtension.lowercased()
                if role == .privilegedHelper {
                    // SMJobBless helpers are bare executables named by their label.
                    guard !source.isDirectory(path) else { continue }
                    let team = teamID(executable: path)
                    result.append(Nested(path: path, role: role, name: child, identifier: child, teamID: team))
                    continue
                }
                guard source.isDirectory(path), !ext.isEmpty else { continue }
                if role == .framework && ext != "framework" && ext != "dylib" { continue }
                var nested = Nested(path: path, role: role, name: (child as NSString).deletingPathExtension)
                let infoCandidates = [path + "/Contents/Info.plist", path + "/Resources/Info.plist", path + "/Versions/Current/Resources/Info.plist", path + "/Info.plist"]
                if let plistPath = infoCandidates.first(where: { source.exists($0) }), let plist = source.plist(plistPath, limit: 1 << 20) {
                    nested.identifier = plist["CFBundleIdentifier"] as? String
                    nested.version = (plist["CFBundleShortVersionString"] as? String) ?? (plist["CFBundleVersion"] as? String)
                    if let display = (plist["CFBundleDisplayName"] as? String) ?? (plist["CFBundleName"] as? String), !display.isEmpty, role != .framework {
                        nested.name = Format.clean(display, limit: 120)
                    }
                    let extensionInfo = (plist["NSExtension"] as? [String: Any]) ?? (plist["EXAppExtensionAttributes"] as? [String: Any])
                    nested.extensionPoint = (extensionInfo?["NSExtensionPointIdentifier"] as? String) ?? (extensionInfo?["EXExtensionPointIdentifier"] as? String)
                    if role == .systemExtension, let point = plist["NSSystemExtensionPointIdentifier"] as? String { nested.extensionPoint = point }
                    if let executable = plist["CFBundleExecutable"] as? String, !executable.contains("..") {
                        let candidates = [path + "/Contents/MacOS/" + executable, path + "/" + executable, path + "/Versions/Current/" + executable]
                        if let found = candidates.first(where: { source.exists($0) && !source.isDirectory($0) }) {
                            nested.teamID = teamID(executable: found)
                        }
                    }
                }
                if role == .loginItem || role == .helper, ext != "app" { nested.role = .helper }
                result.append(nested)
            }
        }
        return result
    }

    /// The team that signed a nested executable ("" for ad hoc), reading only the start of its signature.
    private func teamID(executable path: String) -> String? {
        guard let bytes = source.bytes(path), let file = try? MachOFile.parse(bytes),
              let range = file.preferredSlice?.codeSignature,
              let data = bytes.read(range.lowerBound, Int(min(UInt64(64 * 1024), UInt64(range.count)))) else { return nil }
        return CodeSignature.teamIdentity(in: data)
    }

    /// Each nested item's size, in one pass over the file list.
    mutating func sizeNested() {
        guard !nested.isEmpty else { return }
        var index: [String: Int] = [:]
        for (position, item) in nested.enumerated() { index[item.path] = position }
        let depths = Set(nested.map { $0.path.split(separator: "/").count })
        var totals = [UInt64](repeating: 0, count: nested.count)
        for file in files {
            let components = file.path.split(separator: "/", omittingEmptySubsequences: true)
            for depth in depths where depth < components.count {
                if let position = index[components.prefix(depth).joined(separator: "/")] {
                    totals[position] = totals[position].saturatingAdd(file.size)
                    break
                }
            }
        }
        for position in nested.indices { nested[position].size = totals[position] }
    }

    private func detectTechnologies() -> [String] {
        var found: [String] = []
        let frameworks = Set(nested.filter { $0.role == .framework }.map { $0.name })
        let libraries = macho?.preferredSlice?.libraries.map(\.name) ?? []
        func has(_ name: String) -> Bool { frameworks.contains(name) || libraries.contains(name) }
        if has("Electron Framework") {
            let version = nested.first { $0.name == "Electron Framework" }?.version
            found.append(version.map { "Electron \($0)" } ?? "Electron")
        }
        if has("FlutterMacOS") || has("Flutter") { found.append("Flutter") }
        if has("Chromium Embedded Framework") { found.append("Chromium Embedded Framework") }
        if has("QtCore") || has("QtGui") { found.append("Qt") }
        if has("UnityPlayer") || has("UnityFramework") || files.contains(where: { $0.path.hasSuffix("UnityPlayer.dylib") }) { found.append("Unity") }
        if has("React") || has("hermes") || has("hermesvm") { found.append("React Native") }
        if has("libmonosgen-2.0") || has("Xamarin.Mac") || files.contains(where: { $0.path.hasSuffix("libmonosgen-2.0.dylib") }) { found.append(".NET") }
        if has("Sparkle") {
            found.append(String(localized: "Sparkle updates", bundle: .greeceKit, comment: "In a list of technologies an app uses: the Sparkle update framework"))
        }
        if files.contains(where: { $0.path.hasSuffix("libjli.dylib") }) { found.append("Java") }
        if files.contains(where: { $0.path.contains("/lib/python3") }) || has("Python") { found.append("Python") }
        if libraries.contains("WebKit") && !found.contains(where: { $0.hasPrefix("Electron") }) && files.contains(where: { $0.path.hasSuffix("tauri.conf.json") }) {
            found.append("Tauri")
        }
        if isCatalyst { found.append("Mac Catalyst") }
        if let slice = macho?.preferredSlice {
            if slice.hasSection(named: "__swift5_types") || slice.hasSection(named: "__swift5_typeref") || libraries.contains("libswiftCore") {
                found.append(libraries.contains("SwiftUI") ? "SwiftUI" : "Swift")
            } else if slice.hasSection(named: "__objc_classlist") {
                found.append("Objective-C")
            }
            if slice.hasSection(named: "__go_buildinfo") || slice.hasSection(named: "__gopclntab") { found.append("Go") }
        }
        return found
    }
}
