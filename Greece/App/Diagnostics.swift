import AppKit
import Quartz
import UniformTypeIdentifiers

/// Explains, and where possible fixes, everything that decides whether a file reaches Greece:
/// its registration, other Quick Look extensions, and how macOS routes each kind of file.
@MainActor
final class Diagnostics: ObservableObject {

    // MARK: - Model

    enum Severity: Int, Comparable {
        case ok, info, warning, problem
        static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
        var symbol: String {
            switch self {
            case .ok: return "checkmark.circle.fill"
            case .info: return "info.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .problem: return "xmark.octagon.fill"
            }
        }
        var color: NSColor {
            switch self {
            case .ok: return .systemGreen
            case .info: return .secondaryLabelColor
            case .warning: return .systemOrange
            case .problem: return .systemRed
            }
        }
    }

    enum Fix: Equatable {
        case reregister
        case restartQuickLook
        case turnOff(identifier: String, name: String)
        case moveToApplications

        var title: String {
            switch self {
            case .reregister: return "Repair"
            case .restartQuickLook: return "Restart Quick Look"
            case .turnOff: return "Turn Off"
            case .moveToApplications: return "Show in Finder"
            }
        }
    }

    struct Finding: Identifiable {
        let id: String
        var severity: Severity
        var title: String
        var detail: String
        var fix: Fix?
    }

    /// A Quick Look extension installed on this Mac.
    struct InstalledExtension: Identifiable {
        let id: String           // bundle identifier
        let app: String          // the app it ships in
        let path: String
        let enabled: Bool
        let types: Set<String>
        let isThumbnail: Bool
        var isApple: Bool { path.hasPrefix("/System/") || id.hasPrefix("com.apple.") }
        var isGreece: Bool { id.hasPrefix("com.scorchy.greece") }
    }

    /// One kind of file, and who shows it.
    struct Route: Identifiable {
        enum Verdict: Equatable {
            case greece
            case greeceShared(with: [String])
            case otherApp(String)
            case macOSKeeps(String)
            case macOS
        }
        enum Observation: Equatable {
            case greece, otherExtension, macOS(String), noAnswer
        }

        let id: String
        let title: String
        let sampleName: String
        let sample: String
        var contentType: String?
        var verdict: Verdict = .macOS
        var observed: Observation?
        var checking = false
    }

    @Published private(set) var findings: [Finding] = []
    @Published private(set) var routes: [Route] = Diagnostics.catalog
    @Published private(set) var extensions: [InstalledExtension] = []
    @Published private(set) var running = false
    @Published var message: String?

    private var greeceTypes: Set<String> = []

    // MARK: - Running

    func run() async {
        running = true
        defer { running = false }
        let all = await Self.installedExtensions()
        extensions = all
        greeceTypes = Self.ownTypes()

        var results: [Finding] = []
        // Eight preview families: one summary when they're all fine, otherwise each issue.
        let families = ExtensionStatus.previewFamilies
        let familyFindings = families.map { registration(of: $0.identifier, appex: $0.file, noun: "\($0.name) previews", lowercase: "\($0.name) previews", in: all) }
        let issues = familyFindings.filter { $0.severity > .ok }
        if issues.isEmpty {
            results.append(Finding(id: "previews", severity: .ok, title: "Previews are on",
                                   detail: "All \(families.count) kinds of preview use this copy of Greece.", fix: nil))
        } else {
            results += issues
        }
        results.append(registration(of: "com.scorchy.greece.thumbnails", appex: "GreeceThumbnails.appex", noun: "Finder thumbnails", lowercase: "Finder thumbnails", in: all))
        if !Bundle.main.bundlePath.hasPrefix("/Applications/") {
            results.append(Finding(id: "location", severity: .warning, title: "Greece isn’t in Applications",
                                   detail: "macOS may stop using Greece’s extensions when it runs from another folder. Move it to Applications and open it from there.",
                                   fix: .moveToApplications))
        }
        // Third-party extensions that claim the same files as Greece compete for them.
        for other in all where !other.isApple && !other.isGreece && other.enabled && !other.isThumbnail {
            let overlap = other.types.intersection(greeceTypes)
            guard !overlap.isEmpty else { continue }
            let examples = overlap.compactMap { UTType($0)?.localizedDescription ?? $0 }.sorted().prefix(4).joined(separator: ", ")
            results.append(Finding(id: "overlap-\(other.id)", severity: .warning, title: "\(other.app) also previews \(overlap.count) of Greece’s file types",
                                   detail: "Quick Look shows only one of them for \(examples)\(overlap.count > 4 ? " and more" : ""). Turn \(other.app)’s extension off to let Greece show them.",
                                   fix: .turnOff(identifier: other.id, name: other.app)))
        }
        let legacy = Self.legacyGenerators()
        if !legacy.isEmpty {
            results.append(Finding(id: "legacy", severity: .info, title: "\(legacy.count) older Quick Look plug-in\(legacy.count == 1 ? "" : "s") installed",
                                   detail: legacy.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ") + ". These use Apple’s retired plug-in system. If previews look wrong for a file type, removing them can help.",
                                   fix: nil))
        }
        findings = results.sorted { $0.severity > $1.severity }
        routes = routes.map(resolve)
    }

    private func registration(of identifier: String, appex: String, noun: String, lowercase: String, in all: [InstalledExtension]) -> Finding {
        let own = Bundle.main.builtInPlugInsURL?.appendingPathComponent(appex).resolvingSymlinksInPath().path
        let copies = all.filter { $0.id == identifier }
        guard let active = copies.first else {
            return Finding(id: identifier, severity: .problem, title: "\(noun) aren’t registered with macOS",
                           detail: "Quick Look doesn’t know about Greece’s \(lowercase) yet.", fix: .reregister)
        }
        if URL(fileURLWithPath: active.path).resolvingSymlinksInPath().path != own {
            return Finding(id: identifier, severity: .problem, title: "\(noun) come from another copy of Greece",
                           detail: "Quick Look is using \(active.path). Repair to use this copy and remove the others.", fix: .reregister)
        }
        if !active.enabled {
            return Finding(id: identifier, severity: .info, title: "\(noun) are off",
                           detail: "macOS shows these files itself. Turn them back on in General › Preview Kinds.", fix: nil)
        }
        if copies.count > 1 {
            return Finding(id: identifier, severity: .warning, title: "\(noun): \(copies.count) copies of Greece are registered",
                           detail: "Extra copies (old downloads, builds) can take over after updates. Repair removes them.", fix: .reregister)
        }
        return Finding(id: identifier, severity: .ok, title: "\(noun) are on", detail: "Quick Look uses this copy of Greece.", fix: nil)
    }

    // MARK: - Routes

    private func resolve(_ route: Route) -> Route {
        var route = route
        let type = Self.contentType(forFileNamed: route.sampleName)
        route.contentType = type?.identifier
        guard let type else { route.verdict = .macOS; return route }
        let id = type.identifier

        if id == UTType.commaSeparatedText.identifier {
            route.verdict = .macOSKeeps("Quick Look always opens CSV in Apple’s Office previewer, before any extension.")
        } else if type.conforms(to: .audiovisualContent) {
            route.verdict = .macOSKeeps("This version of macOS treats .\((route.sampleName as NSString).pathExtension) files as video, so Quick Look opens its movie viewer.")
        } else if id == UTType.plainText.identifier {
            route.verdict = .macOSKeeps("Quick Look keeps plain text for its own text viewer.")
        } else if id == "public.svg-image" {
            route.verdict = .macOSKeeps("Quick Look opens SVG in Apple’s web viewer, before any extension. Greece shows SVGs inside archives.")
        } else if (route.sampleName as NSString).pathExtension == "mobileprovision" {
            route.verdict = .macOSKeeps("Quick Look shows provisioning profiles with its text viewer. Greece shows them inside apps and archives.")
        } else {
            let others = extensions.filter { !$0.isGreece && !$0.isThumbnail && $0.enabled && !$0.isApple && $0.types.contains(id) }.map(\.app)
            if greeceTypes.contains(id) {
                route.verdict = others.isEmpty ? .greece : .greeceShared(with: others)
            } else if let other = others.first {
                route.verdict = .otherApp(other)
            } else {
                route.verdict = .macOS
            }
        }
        return route
    }

    private var lastCheck: Task<Void, Never>?

    /// Opens a sample file in the real Quick Look panel and reads which viewer macOS picked.
    /// Checks share the one panel, so they queue up and run one at a time.
    func check(_ routeID: String) async {
        guard let index = routes.firstIndex(where: { $0.id == routeID }), !routes[index].checking else { return }
        routes[index].checking = true
        let previous = lastCheck
        let task = Task { @MainActor in
            await previous?.value
            await self.runCheck(routeID)
        }
        lastCheck = task
        await task.value
    }

    private func runCheck(_ routeID: String) async {
        guard let index = routes.firstIndex(where: { $0.id == routeID }) else { return }
        let route = routes[index]
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Greece Diagnostics", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(route.sampleName)
        try? route.sample.write(to: file, atomically: true, encoding: .utf8)
        let observed = await Self.observeQuickLook(file)
        if let index = routes.firstIndex(where: { $0.id == routeID }) {
            routes[index].observed = observed
            routes[index].checking = false
        }
    }

    private static func observeQuickLook(_ file: URL) async -> Route.Observation {
        let log = Process()
        log.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        log.arguments = ["stream", "--style", "compact", "--level", "debug", "--predicate",
                         #"(subsystem == "com.apple.quicklook" AND eventMessage CONTAINS "displayBundleID") OR (subsystem == "com.scorchy.greece" AND eventMessage CONTAINS "Preparing preview")"#]
        let pipe = Pipe()
        log.standardOutput = pipe
        log.standardError = Pipe()
        let collected = LockedText()
        pipe.fileHandleForReading.readabilityHandler = { handle in collected.append(String(decoding: handle.availableData, as: UTF8.self)) }
        guard (try? log.run()) != nil else { return .noAnswer }
        defer {
            pipe.fileHandleForReading.readabilityHandler = nil
            log.terminate()
            QLPreviewPanel.shared()?.close()
        }
        try? await Task.sleep(nanoseconds: 900_000_000)
        QuickLookPresenter.shared.show(file)
        // Quick Look's own choice of viewer is the truth; Greece's log line only tells us which
        // extension ran, and it must name this sample's extension to count.
        let ext = file.pathExtension.isEmpty ? "no extension" : file.pathExtension
        for _ in 0..<40 {
            try? await Task.sleep(nanoseconds: 150_000_000)
            let text = collected.value
            guard let range = text.range(of: "got displayBundleID ") else { continue }
            let bundle = text[range.upperBound...].prefix { !$0.isWhitespace }
            guard bundle.hasSuffix(".Extensions") else { return .macOS(viewerName(String(bundle))) }
            for _ in 0..<12 {
                if collected.value.contains("Preparing preview (\(ext))") { return .greece }
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
            return .otherExtension
        }
        return .noAnswer
    }

    private static func viewerName(_ bundle: String) -> String {
        switch bundle.split(separator: ".").last.map(String.init) ?? bundle {
        case "Web2", "Web": return "Apple’s document previewer"
        case "Movie": return "Apple’s movie viewer"
        case "Text": return "Apple’s text viewer"
        case "Image": return "Apple’s image viewer"
        case "PDF": return "Apple’s PDF viewer"
        case "Audio": return "Apple’s audio player"
        default: return "a built-in viewer"
        }
    }

    // MARK: - Fixes

    func perform(_ fix: Fix, status: ExtensionStatus) async {
        switch fix {
        case .reregister:
            await status.enableAndWait()
            message = "Greece is registered and on. Quick Look was restarted."
        case .restartQuickLook:
            status.resetQuickLook()
        case .turnOff(let identifier, let name):
            _ = await ExtensionStatus.run("/usr/bin/pluginkit", ["-e", "ignore", "-i", identifier])
            _ = await ExtensionStatus.run("/usr/bin/qlmanage", ["-r"])
            message = "\(name)’s Quick Look extension is off. You can turn it back on in System Settings › General › Login Items & Extensions."
        case .moveToApplications:
            NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
        }
        await run()
    }

    /// A plain-text summary for support requests. Nothing leaves the Mac unless you paste it somewhere.
    var report: String {
        let info = Bundle.main.infoDictionary
        var lines = ["Greece \(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))",
                     "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)", "App: \(Bundle.main.bundlePath)", ""]
        lines += findings.map { "[\($0.severity)] \($0.title): \($0.detail)" }
        lines += ["", "File types:"]
        lines += routes.map { route in
            let observed = route.observed.map { " · checked: \($0)" } ?? ""
            return "  \(route.title) (\(route.contentType ?? "unknown")): \(route.verdict)\(observed)"
        }
        lines += ["", "Other Quick Look extensions:"]
        lines += extensions.filter { !$0.isApple && !$0.isGreece }.map { "  \($0.app) \($0.id) \($0.enabled ? "on" : "off") \($0.isThumbnail ? "thumbnails" : "previews"), \($0.types.count) types" }
        return lines.joined(separator: "\n")
    }

    // MARK: - Reading the system

    /// Every type Greece's preview families claim.
    private static func ownTypes() -> Set<String> {
        guard let plugins = Bundle.main.builtInPlugInsURL else { return [] }
        return ExtensionStatus.previewFamilies.reduce(into: Set<String>()) { all, family in
            let url = plugins.appendingPathComponent(family.file).appendingPathComponent("Contents/Info.plist")
            if let plist = NSDictionary(contentsOf: url) as? [String: Any] { all.formUnion(types(in: plist)) }
        }
    }

    private static func types(in plist: [String: Any]) -> Set<String> {
        let attributes = ((plist["NSExtension"] as? [String: Any])?["NSExtensionAttributes"] as? [String: Any])
            ?? (plist["EXAppExtensionAttributes"] as? [String: Any])
        return Set(attributes?["QLSupportedContentTypes"] as? [String] ?? [])
    }

    /// Every Quick Look preview and thumbnail extension macOS knows about. (pluginkit's own
    /// extension-point filter misses thumbnail extensions, so classify by each one's Info.plist.)
    private static func installedExtensions() async -> [InstalledExtension] {
        let output = await ExtensionStatus.run("/usr/bin/pluginkit", ["-m", "-A", "-D", "-v"])
        return output.split(separator: "\n").compactMap { line -> InstalledExtension? in
            let fields = line.split(separator: "\t").map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count >= 2, let path = fields.last, path.hasPrefix("/") else { return nil }
            let plist = NSDictionary(contentsOf: URL(fileURLWithPath: path).appendingPathComponent("Contents/Info.plist")) as? [String: Any] ?? [:]
            let point = ((plist["NSExtension"] as? [String: Any])?["NSExtensionPointIdentifier"] as? String)
                ?? ((plist["EXAppExtensionAttributes"] as? [String: Any])?["EXExtensionPointIdentifier"] as? String) ?? ""
            let thumbnail: Bool
            switch point {
            case "com.apple.quicklook.preview": thumbnail = false
            case "com.apple.quicklook.thumbnail", "com.apple.quicklook.thumbnail.secure": thumbnail = true
            default: return nil
            }
            let head = line.prefix { $0 != "\t" }
            let flag = head.first ?? " "
            let identifier = head.dropFirst().trimmingCharacters(in: .whitespaces).split(separator: "(").first.map(String.init) ?? ""
            var app = (path as NSString).lastPathComponent.replacingOccurrences(of: ".appex", with: "")
            if let range = path.range(of: ".app/Contents/") {
                app = ((String(path[..<range.lowerBound]) + ".app") as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
            }
            return InstalledExtension(id: identifier, app: app, path: path, enabled: flag != "-", types: types(in: plist), isThumbnail: thumbnail)
        }
    }

    private static func legacyGenerators() -> [String] {
        let folders = ["/Library/QuickLook", NSHomeDirectory() + "/Library/QuickLook"]
        return folders.flatMap { folder in
            ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [])
                .filter { $0.hasSuffix(".qlgenerator") }.map { folder + "/" + $0 }
        }
    }

    /// How Finder types a file with this name (extensionless names like Dockerfile included).
    static func contentType(forFileNamed name: String) -> UTType? {
        let ext = (name as NSString).pathExtension
        if !ext.isEmpty { return UTType(filenameExtension: ext) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Greece Types", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: Data("x\n".utf8)) }
        return try? file.resourceValues(forKeys: [.contentTypeKey]).contentType
    }

    static let catalog: [Route] = [
        Route(id: "md", title: "Markdown", sampleName: "Notes.md", sample: "# Notes\n\nGreece diagnostics sample.\n"),
        Route(id: "json", title: "JSON", sampleName: "data.json", sample: "{\"greece\": true}\n"),
        Route(id: "yaml", title: "YAML", sampleName: "config.yaml", sample: "greece: true\n"),
        Route(id: "swift", title: "Swift", sampleName: "App.swift", sample: "let greece = true\n"),
        Route(id: "py", title: "Python", sampleName: "tool.py", sample: "print('greece')\n"),
        Route(id: "js", title: "JavaScript", sampleName: "app.js", sample: "const greece = true;\n"),
        Route(id: "ts", title: "TypeScript (.ts)", sampleName: "app.ts", sample: "const greece: boolean = true;\n"),
        Route(id: "tsx", title: "TypeScript (.tsx)", sampleName: "App.tsx", sample: "export const A = () => <div />;\n"),
        Route(id: "sh", title: "Shell script", sampleName: "build.sh", sample: "#!/bin/sh\necho greece\n"),
        Route(id: "go", title: "Go", sampleName: "main.go", sample: "package main\n"),
        Route(id: "rs", title: "Rust", sampleName: "main.rs", sample: "fn main() {}\n"),
        Route(id: "docker", title: "Dockerfile", sampleName: "Dockerfile", sample: "FROM swift\n"),
        Route(id: "make", title: "Makefile", sampleName: "Makefile", sample: "all:\n\techo greece\n"),
        Route(id: "txt", title: "Plain text", sampleName: "readme.txt", sample: "Greece\n"),
        Route(id: "log", title: "Log", sampleName: "server.log", sample: "INFO started\n"),
        Route(id: "csv", title: "CSV", sampleName: "table.csv", sample: "a,b\n1,2\n"),
        Route(id: "tsv", title: "TSV", sampleName: "table.tsv", sample: "a\tb\n1\t2\n"),
        Route(id: "ipynb", title: "Jupyter notebook", sampleName: "analysis.ipynb", sample: "{\"cells\": [], \"metadata\": {}, \"nbformat\": 4, \"nbformat_minor\": 5}\n"),
        Route(id: "patch", title: "Patch", sampleName: "change.patch", sample: "--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\n+b\n"),
        Route(id: "plist", title: "Property list", sampleName: "Info.plist", sample: "<?xml version=\"1.0\"?><plist version=\"1.0\"><dict/></plist>\n"),
        Route(id: "geojson", title: "GeoJSON map", sampleName: "places.geojson", sample: "{\"type\":\"FeatureCollection\",\"features\":[{\"type\":\"Feature\",\"properties\":{},\"geometry\":{\"type\":\"Point\",\"coordinates\":[25.4,37.1]}}]}\n"),
        Route(id: "gpx", title: "GPX track", sampleName: "hike.gpx", sample: "<?xml version=\"1.0\"?><gpx version=\"1.1\" creator=\"Greece\"><trk><trkseg><trkpt lat=\"37.1\" lon=\"25.4\"/><trkpt lat=\"37.2\" lon=\"25.5\"/></trkseg></trk></gpx>\n"),
        Route(id: "kml", title: "KML", sampleName: "places.kml", sample: "<?xml version=\"1.0\"?><kml xmlns=\"http://www.opengis.net/kml/2.2\"><Placemark><Point><coordinates>25.4,37.1</coordinates></Point></Placemark></kml>\n"),
        Route(id: "gltf", title: "glTF model", sampleName: "model.gltf", sample: "{\"asset\":{\"version\":\"2.0\"},\"scenes\":[{\"nodes\":[]}]}\n"),
        Route(id: "stl", title: "STL model", sampleName: "part.stl", sample: "solid part\nendsolid part\n"),
        Route(id: "obj", title: "OBJ model", sampleName: "mesh.obj", sample: "v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3\n"),
        Route(id: "tex", title: "LaTeX", sampleName: "paper.tex", sample: "\\documentclass{article}\\begin{document}Hello\\end{document}\n"),
        Route(id: "bib", title: "BibTeX", sampleName: "refs.bib", sample: "@article{key, title={Greece}}\n"),
        Route(id: "org", title: "Org mode", sampleName: "notes.org", sample: "* Greece\n** TODO Check\n"),
        Route(id: "adoc", title: "AsciiDoc", sampleName: "guide.adoc", sample: "= Greece\n\nHello.\n"),
        Route(id: "rst", title: "reStructuredText", sampleName: "readme.rst", sample: "Greece\n======\n"),
        Route(id: "mermaid", title: "Mermaid diagram", sampleName: "flow.mmd", sample: "graph LR\n  A --> B\n"),
        Route(id: "srt", title: "Subtitles", sampleName: "film.srt", sample: "1\n00:00:01,000 --> 00:00:02,000\nHello\n"),
        Route(id: "mobileprovision", title: "Provisioning profile", sampleName: "app.mobileprovision", sample: "profile\n"),
        Route(id: "svg", title: "SVG image", sampleName: "icon.svg", sample: "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"10\" height=\"10\"/>\n"),
        Route(id: "ttf", title: "Font (TrueType)", sampleName: "font.ttf", sample: "font\n"),
        Route(id: "woff2", title: "Web font", sampleName: "font.woff2", sample: "wOF2\n"),
    ]
}

/// Text collected from a pipe on a background thread.
private final class LockedText: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    func append(_ more: String) { lock.lock(); text += more; lock.unlock() }
    var value: String { lock.lock(); defer { lock.unlock() }; return text }
}
