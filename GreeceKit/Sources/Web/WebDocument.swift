import Foundation

/// A document rendered by the web engine: Markdown, code, diffs and notebooks.
public struct WebDocument {
    public enum Kind: String, Encodable { case markdown, code, diff, notebook }

    public var kind: Kind
    public var text: String
    public var grammar: String?
    public var baseDirectory: URL?
    public var truncated = false

    public init(kind: Kind, text: String, grammar: String? = nil, baseDirectory: URL? = nil, truncated: Bool = false) {
        self.kind = kind
        self.text = text
        self.grammar = grammar
        self.baseDirectory = baseDirectory
        self.truncated = truncated
    }

    // MARK: - Payload

    private struct Payload: Encodable {
        struct Options: Encodable {
            var outline: Bool
            var math: Bool
            var diagrams: Bool
            var remoteImages: Bool
            var frontMatter: Bool
        }
        var kind: Kind
        var text: String
        var language: String?
        var truncated: Bool
        var options: Options
        var diffLanguages: [String: String]?
    }

    // MARK: - Feature detection

    private var mayContainMath: Bool {
        text.contains("$") || text.contains("\\(") || text.contains("\\[") || text.contains("```math") || text.contains("text/latex")
    }

    private var mayContainDiagrams: Bool { text.contains("mermaid") }

    /// highlight.js grammars a document needs beyond the bundled common set.
    private func extraGrammars(diffLanguages: [String: String]) -> [String] {
        var needed = Set<String>()
        switch kind {
        case .code:
            if let grammar { needed.insert(grammar) }
        case .markdown, .notebook:
            for word in fenceLanguages() {
                if WebAssets.hasGrammar(word) { needed.insert(word) }
                if let language = LanguageCatalog.language(forExtension: word) { needed.insert(language.grammar) }
            }
            if kind == .notebook, let language = notebookLanguage() { needed.insert(language) }
        case .diff:
            needed.formUnion(diffLanguages.values)
        }
        return needed
            .filter { !LanguageCatalog.commonGrammars.contains($0) && WebAssets.bundledGrammars.contains($0) }
            .sorted()
    }

    private func fenceLanguages() -> Set<String> {
        var result = Set<String>()
        text.enumerateLines { line, _ in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") else { return }
            let info = trimmed.drop(while: { $0 == "`" || $0 == "~" }).trimmingCharacters(in: .whitespaces)
            if let word = info.split(whereSeparator: { $0 == " " || $0 == "{" || $0 == "," }).first, !word.isEmpty {
                result.insert(word.lowercased())
            }
        }
        return result
    }

    private func notebookLanguage() -> String? {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let meta = json["metadata"] as? [String: Any] else { return nil }
        let name = ((meta["kernelspec"] as? [String: Any])?["language"] as? String)
            ?? ((meta["language_info"] as? [String: Any])?["name"] as? String)
        guard let name = name?.lowercased() else { return nil }
        return WebAssets.hasGrammar(name) ? name : LanguageCatalog.language(forExtension: name)?.grammar
    }

    /// File extensions in a diff mapped to grammars, so each file highlights in its own language.
    private func diffLanguageMap() -> [String: String] {
        guard kind == .diff else { return [:] }
        var map: [String: String] = [:]
        text.enumerateLines { line, _ in
            guard line.hasPrefix("+++ ") || line.hasPrefix("diff --git ") else { return }
            guard let last = line.split(separator: " ").last else { return }
            let ext = (String(last) as NSString).pathExtension.lowercased()
            guard !ext.isEmpty, map[ext] == nil else { return }
            let name = (String(last) as NSString).lastPathComponent
            if let language = LanguageCatalog.language(forFileName: name) ?? LanguageCatalog.language(forExtension: ext), !language.isPlainText {
                map[ext] = language.grammar
            }
        }
        return map
    }

    // MARK: - HTML

    public func html(settings: PreviewSettings) -> String {
        let usesMarkdown = kind == .markdown || kind == .notebook
        let math = usesMarkdown && settings.renderMath && mayContainMath
        let diagrams = usesMarkdown && settings.renderDiagrams && mayContainDiagrams
        let diffLanguages = diffLanguageMap()

        var scripts = ["vendor/highlight/highlight.min.js"]
        scripts += extraGrammars(diffLanguages: diffLanguages).map { "vendor/highlight/languages/\($0).min.js" }
        var styles = ["greece.css"]
        if usesMarkdown {
            scripts += ["vendor/markdown-it/markdown-it.min.js", "vendor/markdown-it/markdown-it-footnote.min.js", "vendor/markdown-it/markdown-it-emoji.min.js"]
        }
        if math {
            scripts.append("vendor/katex/katex.min.js")
            styles.insert("vendor/katex/katex.min.css", at: 0)
        }
        if diagrams { scripts.append("vendor/mermaid/mermaid.min.js") }
        scripts.append("greece.js")

        let payload = Payload(
            kind: kind,
            text: text,
            language: grammar,
            truncated: truncated,
            options: .init(outline: settings.showOutline, math: math, diagrams: diagrams,
                           remoteImages: settings.loadRemoteImages, frontMatter: settings.showFrontMatter),
            diffLanguages: diffLanguages.isEmpty ? nil : diffLanguages)
        let json = (try? JSONEncoder().encode(payload)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        // Make the JSON inert inside <script>: no "<" can ever close the element or open a comment.
        let safeJSON = json.replacingOccurrences(of: "<", with: "\\u003c")

        let remote = settings.loadRemoteImages ? " https: http:" : ""
        let csp = [
            "default-src 'none'",
            "script-src greece://asset",
            "style-src greece://asset 'unsafe-inline'",
            "font-src greece://asset data:",
            "img-src greece: data:\(remote)",
            "media-src greece:\(remote)",
            "worker-src blob:", "connect-src greece://asset", "frame-src 'none'", "object-src 'none'", "base-uri 'none'", "form-action 'none'",
        ].joined(separator: "; ")

        let classes = WebDocument.classes(settings: settings, kind: kind).filter(\.value).map(\.key).sorted().joined(separator: " ")
        return """
        <!DOCTYPE html>
        <html lang="en" class="\(classes)">
        <head>
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="\(csp)">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="color-scheme" content="light dark">
        \(styles.map { "<link rel=\"stylesheet\" href=\"greece://asset/\(WebDocument.attribute($0))\">" }.joined(separator: "\n"))
        <style id="theme">\(settings.codeTheme.css)</style>
        <style id="vars">\(WebDocument.variablesCSS(settings))</style>
        <script id="payload" type="application/json">\(safeJSON)</script>
        </head>
        <body>
        <main id="root"></main>
        \(scripts.map { "<script src=\"greece://asset/\(WebDocument.attribute($0))\"></script>" }.joined(separator: "\n"))
        </body>
        </html>
        """
    }

    // MARK: - Live styling

    static func classes(settings: PreviewSettings, kind: Kind?) -> [String: Bool] {
        [
            "wrap": settings.wrapLines,
            "no-lines": !settings.lineNumbers,
            "outline-on": settings.showOutline,
        ]
    }

    static func variablesCSS(_ settings: PreviewSettings) -> String {
        let font: String
        switch settings.codeFont {
        case "SF Mono", "": font = "ui-monospace, 'SF Mono', Menlo, monospace"
        default: font = "'\(settings.codeFont.replacingOccurrences(of: "'", with: ""))', ui-monospace, Menlo, monospace"
        }
        let ligatures = ["JetBrains Mono", "Fira Code", "Cascadia Code", "Monaspace Neon", "Iosevka"].contains(settings.codeFont)
        let heading = settings.readingFont == .serif ? "--heading-font: ui-serif, 'New York', Georgia, serif;" : ""
        return """
        :root{--code-font:\(font);--code-size:\(settings.codeFontSize)px;--code-lh:1.55;--tab:\(settings.tabWidth);\
        --code-ligatures:\(ligatures ? "normal" : "none");--read-font:\(settings.readingFont.cssStack);\
        --read-size:\(settings.readingSize)px;--measure:\(settings.readingWidth.css);\(heading)}
        """
    }

    static func liveUpdateScript(settings: PreviewSettings, kind: Kind) -> String {
        struct Update: Encodable { var themeCSS: String; var varsCSS: String; var classes: [String: Bool] }
        let update = Update(themeCSS: settings.codeTheme.css, varsCSS: variablesCSS(settings), classes: classes(settings: settings, kind: kind))
        let json = (try? JSONEncoder().encode(update)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return "window.greece && window.greece.apply(\(json));"
    }

    /// Settings that require rebuilding the page rather than restyling it.
    static func structuralKey(_ settings: PreviewSettings) -> [Bool] {
        [settings.renderMath, settings.renderDiagrams, settings.loadRemoteImages, settings.showFrontMatter, settings.showOutline]
    }

    /// Escapes a value for an HTML attribute. Asset names are already whitelisted; this is belt and braces.
    static func attribute(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
}
