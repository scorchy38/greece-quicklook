import AppKit
import Quartz

/// `greece` in Terminal: Quick Look for files, lists of paths, or piped text.
///
///     greece README.md src/*.swift      previews the files (arrow keys move between them)
///     git diff | greece                  previews piped text, its kind sniffed (diff, JSON, Markdown…)
///     find . -name '*.md' | greece       previews each path when every line is an existing file
///     curl -s … | greece --name api.json names piped text, to choose how it's shown
enum CommandLineTool {
    static func run() {
        var arguments = Array(CommandLine.arguments.drop { $0 != "--cli" }.dropFirst())
        if arguments.contains("-h") || arguments.contains("--help") {
            print("""
            usage: greece [--name <file name>] [file …]
              Shows files in Quick Look. With no files, reads standard input: a list of paths, or text to preview.
              --name   the name to give piped text, e.g. --name data.json (sets how it's shown)
            """)
            exit(0)
        }
        var name: String?
        if let index = arguments.firstIndex(of: "--name"), index + 1 < arguments.count {
            name = arguments[index + 1]
            arguments.removeSubrange(index...index + 1)
        }

        var urls = arguments.map { URL(fileURLWithPath: $0, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).standardizedFileURL }
        let missing = urls.filter { !FileManager.default.fileExists(atPath: $0.path) }
        for url in missing { FileHandle.standardError.write(Data("greece: no such file: \(url.path)\n".utf8)) }
        urls.removeAll { missing.contains($0) }

        if arguments.isEmpty, isatty(FileHandle.standardInput.fileDescriptor) == 0 {
            let data = FileHandle.standardInput.readDataToEndOfFile()
            urls = paths(in: data) ?? [store(data, named: name)].compactMap { $0 }
        }
        guard !urls.isEmpty else {
            if arguments.isEmpty { FileHandle.standardError.write(Data("usage: greece [--name <file name>] [file …]\n".utf8)) }
            exit(1)
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let host = Host()
        app.delegate = host
        DispatchQueue.main.async {
            app.activate(ignoringOtherApps: true)
            QuickLookPresenter.shared.show(urls, at: 0)
            // Done when the panel closes (Escape, or its close button).
            if let panel = QLPreviewPanel.shared() {
                host.observer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: panel, queue: .main) { _ in exit(0) }
            }
        }
        app.run()
    }

    /// Standard input that is nothing but existing file paths, one per line.
    private static func paths(in data: Data) -> [URL]? {
        guard data.count < 1_000_000 else { return nil }
        let lines = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !lines.isEmpty, lines.count <= 2_000 else { return nil }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let urls = lines.map { URL(fileURLWithPath: $0, relativeTo: cwd).standardizedFileURL }
        return urls.allSatisfy { FileManager.default.fileExists(atPath: $0.path) } ? urls : nil
    }

    /// Saves piped text to a temporary file whose extension tells Greece how to show it.
    private static func store(_ data: Data, named name: String?) -> URL? {
        guard !data.isEmpty else { return nil }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("greece-stdin-\(getpid())", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(name.map { ($0 as NSString).lastPathComponent } ?? "Standard Input.\(sniffExtension(data))")
        do { try data.write(to: file) } catch { return nil }
        return file
    }

    static func sniffExtension(_ data: Data) -> String {
        let text = String(decoding: data.prefix(64 * 1024), as: UTF8.self)
        let trimmed = text.drop { $0.isWhitespace }
        // Patches, including `git show` / `git log -p` / `git format-patch` output with their headers.
        if trimmed.hasPrefix("diff --git ") || (trimmed.hasPrefix("--- ") && text.contains("\n+++ "))
            || ((trimmed.hasPrefix("From ") || trimmed.hasPrefix("commit ")) && text.contains("\ndiff --git ")) { return "patch" }
        if (trimmed.hasPrefix("{") || trimmed.hasPrefix("[")),
           (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil { return "json" }
        if trimmed.hasPrefix("{"), text.split(separator: "\n").prefix(5).allSatisfy({ (try? JSONSerialization.jsonObject(with: Data($0.utf8))) != nil }) { return "jsonl" }
        if trimmed.hasPrefix("<?xml") || trimmed.hasPrefix("<plist") { return "xml" }
        if trimmed.hasPrefix("<!DOCTYPE html") || trimmed.hasPrefix("<html") { return "html" }
        if trimmed.hasPrefix("#!") { return "sh" }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).prefix(200)
        if lines.filter({ $0.contains("\t") }).count > max(2, lines.count / 2) { return "tsv" }
        let markdown = lines.filter { line in
            line.hasPrefix("# ") || line.hasPrefix("## ") || line.hasPrefix("```") || line.hasPrefix("- [") || line.hasPrefix("> ") || line.range(of: #"\[[^\]]+\]\([^)]+\)"#, options: .regularExpression) != nil
        }.count
        if markdown >= 2 { return "md" }
        return "log"
    }

    private final class Host: NSObject, NSApplicationDelegate {
        var observer: Any?
        override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
        override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { QuickLookPresenter.shared.attach(to: panel) }
        override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { QuickLookPresenter.shared.detach(from: panel) }
    }
}

/// Puts a `greece` command on the PATH that runs this copy of the app.
enum CommandLineInstaller {
    static let candidates = ["/usr/local/bin", "/opt/homebrew/bin"]

    static var installedPath: String? {
        candidates.map { $0 + "/greece" }.first { FileManager.default.fileExists(atPath: $0) }
    }

    static var script: String {
        """
        #!/bin/sh
        # Installed by Greece: shows files in Quick Look. Run `greece --help` for usage.
        exec "\(Bundle.main.executablePath ?? "/Applications/Greece.app/Contents/MacOS/Greece")" --cli "$@"
        """
    }

    /// Writes the command where it can, without asking; otherwise asks for an administrator password.
    @discardableResult
    static func install() -> Result<String, Error> {
        let data = Data((script + "\n").utf8)
        for folder in candidates where FileManager.default.isWritableFile(atPath: folder) {
            let path = folder + "/greece"
            do {
                try data.write(to: URL(fileURLWithPath: path), options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
                return .success(path)
            } catch { continue }
        }
        // /usr/local/bin belongs to root on a fresh Mac: write it with the user's permission.
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("greece-cli")
        do { try data.write(to: temporary) } catch { return .failure(error) }
        let command = "mkdir -p /usr/local/bin && install -m 755 '\(temporary.path)' /usr/local/bin/greece"
        var error: NSDictionary?
        NSAppleScript(source: "do shell script \"\(command)\" with administrator privileges")?.executeAndReturnError(&error)
        if let error { return .failure(NSError(domain: "Greece", code: 1, userInfo: [NSLocalizedDescriptionKey: error[NSAppleScript.errorMessage] as? String ?? "Couldn’t install the command."])) }
        return .success("/usr/local/bin/greece")
    }
}
