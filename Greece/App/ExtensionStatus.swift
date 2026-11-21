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
        guard let own = ownExtensionPath else { return }
        working = true
        Task {
            let listing = await Self.run("/usr/bin/pluginkit", ["-m", "-A", "-D", "-v", "-i", Self.identifier])
            for path in Self.paths(in: listing) where path != own {
                _ = await Self.run("/usr/bin/pluginkit", ["-r", path])
            }
            _ = await Self.run("/usr/bin/pluginkit", ["-a", own])
            _ = await Self.run("/usr/bin/pluginkit", ["-e", "use", "-i", Self.identifier])
            _ = await Self.run("/usr/bin/qlmanage", ["-r"])
            _ = await Self.run("/usr/bin/qlmanage", ["-r", "cache"])
            try? await Task.sleep(nanoseconds: 600_000_000)
            working = false
            refresh()
            message = "Greece is now handling Quick Look previews."
        }
    }

    func resetQuickLook() {
        working = true
        Task {
            _ = await Self.run("/usr/bin/qlmanage", ["-r"])
            _ = await Self.run("/usr/bin/qlmanage", ["-r", "cache"])
            working = false
            message = "Quick Look was restarted. New previews use your latest settings."
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

    nonisolated static func paths(in output: String) -> [String] {
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
