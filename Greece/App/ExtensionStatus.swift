import AppKit
import Combine

/// Knows whether Quick Look is actually using this copy of Greece, and can fix it when it isn't.
@MainActor
final class ExtensionStatus: ObservableObject {

    enum State: Equatable {
        case checking
        case active
        case disabled
        case otherCopy(String)
        case notRegistered
    }

    nonisolated static let identifier = "com.scorchy.greece.quicklook"

    @Published private(set) var state: State = .checking
    @Published private(set) var working = false
    @Published var message: String?

    private var observer: Any?

    init() {
        refresh()
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    var ownExtensionPath: String? {
        Bundle.main.builtInPlugInsURL?.appendingPathComponent("GreeceQuickLook.appex").resolvingSymlinksInPath().path
    }

    func refresh() {
        Task {
            let output = await Self.run("/usr/bin/pluginkit", ["-m", "-A", "-D", "-v", "-i", Self.identifier])
            state = Self.parse(output, ownPath: ownExtensionPath)
        }
    }

    /// Registers this copy, removes stale ones (old builds, other folders), enables it and restarts Quick Look.
    func enable() {
        Task { await enableAndWait() }
    }

    /// Every extension inside this copy of Greece: the preview families and the thumbnails.
    nonisolated static var extensions: [(identifier: String, file: String)] {
        guard let plugins = Bundle.main.builtInPlugInsURL,
              let names = try? FileManager.default.contentsOfDirectory(atPath: plugins.path) else { return [] }
        return names.filter { $0.hasSuffix(".appex") }.sorted().compactMap { name in
            let info = plugins.appendingPathComponent(name).appendingPathComponent("Contents/Info.plist")
            guard let id = (NSDictionary(contentsOf: info) as? [String: Any])?["CFBundleIdentifier"] as? String else { return nil }
            return (id, name)
        }
    }

    /// The preview families (everything but thumbnails), for the Preview Kinds settings.
    /// Names are the ones System Settings shows, in the app's language when the extension has it.
    nonisolated static var previewFamilies: [(identifier: String, file: String, name: String)] {
        guard let plugins = Bundle.main.builtInPlugInsURL else { return [] }
        return extensions.filter { $0.identifier != "com.scorchy.greece.thumbnails" }.map { item in
            let bundle = Bundle(url: plugins.appendingPathComponent(item.file))
            return (item.identifier, item.file, bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? item.file)
        }
    }

    func enableAndWait() async {
        guard let plugins = Bundle.main.builtInPlugInsURL else { return }
        working = true
        for (identifier, file) in Self.extensions {
            let own = plugins.appendingPathComponent(file).resolvingSymlinksInPath().path
            let listing = await Self.run("/usr/bin/pluginkit", ["-m", "-A", "-D", "-v", "-i", identifier])
            for path in Self.paths(in: listing, identifier: identifier) where URL(fileURLWithPath: path).resolvingSymlinksInPath().path != own {
                _ = await Self.run("/usr/bin/pluginkit", ["-r", path])
            }
            // Right after an update the registry may ignore the first add; retry until it's listed.
            for _ in 0..<20 {
                _ = await Self.run("/usr/bin/pluginkit", ["-a", own])
                if await Self.run("/usr/bin/pluginkit", ["-m", "-A", "-D", "-v", "-i", identifier]).contains(own) { break }
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            _ = await Self.run("/usr/bin/pluginkit", ["-e", "use", "-i", identifier])
        }
        _ = await Self.run("/usr/bin/qlmanage", ["-r"])
        _ = await Self.run("/usr/bin/qlmanage", ["-r", "cache"])
        try? await Task.sleep(nanoseconds: 600_000_000)
        working = false
        refresh()
        message = String(localized: "Greece is now handling Quick Look previews.")
    }

    func resetQuickLook() {
        working = true
        Task {
            _ = await Self.run("/usr/bin/qlmanage", ["-r"])
            _ = await Self.run("/usr/bin/qlmanage", ["-r", "cache"])
            working = false
            message = String(localized: "Quick Look was restarted. New previews use your latest settings.")
        }
    }

    func openExtensionSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.ExtensionsPreferences?extensionPointIdentifier=com.apple.quicklook.preview",
            "x-apple.systempreferences:com.apple.LoginItems-Settings.extension",
            "x-apple.systempreferences:com.apple.ExtensionsPreferences",
        ]
        for candidate in candidates {
            if let url = URL(string: candidate), NSWorkspace.shared.open(url) { return }
        }
    }

    // MARK: - pluginkit

    nonisolated static func parse(_ output: String, ownPath: String?) -> State {
        let lines = output.split(separator: "\n").filter { $0.contains(identifier) }
        guard !lines.isEmpty else { return .notRegistered }
        // pluginkit lists the active registration first; "+" = enabled, "-" = disabled, " " = default (enabled).
        let entries = lines.map { line -> (flag: Character, path: String) in
            let flag = line.first ?? " "
            let path = line.split(separator: "\t").last.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
            return (flag, path)
        }
        let own = ownPath.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        guard let first = entries.first else { return .notRegistered }
        let firstPath = URL(fileURLWithPath: first.path).resolvingSymlinksInPath().path
        if let own, firstPath != own { return .otherCopy(first.path) }
        return first.flag == "-" ? .disabled : .active
    }

    nonisolated static func paths(in output: String, identifier: String = identifier) -> [String] {
        output.split(separator: "\n").filter { $0.contains(identifier) }.compactMap { line in
            line.split(separator: "\t").last.map { String($0).trimmingCharacters(in: .whitespaces) }
        }
    }

    nonisolated static func run(_ tool: String, _ arguments: [String]) async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: tool)
                process.arguments = arguments
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = Pipe()
                do {
                    try process.run()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    continuation.resume(returning: String(decoding: data, as: UTF8.self))
                } catch {
                    continuation.resume(returning: "")
                }
            }
        }
    }
}
