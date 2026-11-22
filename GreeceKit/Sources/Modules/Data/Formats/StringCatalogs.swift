import Foundation

/// Localized strings as a table of keys by languages: Xcode String Catalogs (.xcstrings), classic
/// .strings files (with their sibling .lproj translations) and .stringsdict plural rules.
struct StringTable {
    enum State: Equatable {
        case translated, needsReview, new, stale, missing, notTranslated
    }
    struct Entry {
        var value: String?
        var state: State
        /// "Plural", "Device"… when the value is one of several variations.
        var variation: String?
    }
    struct Row {
        var key: String
        var comment: String?
        var entries: [String: Entry]
    }

    var title: String
    var sourceLanguage: String?
    var languages: [String]
    var rows: [Row]
    var columns: [String] = []

    static let maxRows = 50_000
    static let maxLanguages = 60

    // MARK: - Completion

    /// Share of translatable strings that are translated in `language`.
    func completion(_ language: String) -> (done: Int, review: Int, total: Int) {
        var done = 0, review = 0, total = 0
        for row in rows {
            guard let entry = row.entries[language], entry.state != .notTranslated else {
                if row.entries[language] == nil { total += 1 }
                continue
            }
            total += 1
            if entry.state == .translated { done += 1 }
            if entry.state == .needsReview { review += 1 }
        }
        return (done, review, total)
    }

    var overallCompletion: Double {
        let others = languages.filter { $0 != sourceLanguage }
        guard !others.isEmpty else { return 1 }
        var done = 0, total = 0
        for language in others {
            let c = completion(language)
            done += c.done
            total += c.total
        }
        return total == 0 ? 1 : Double(done) / Double(total)
    }

    // MARK: - Grid

    /// Key, then languages (the source first), then comments.
    func store() -> RecordTable {
        // Several languages side by side: keep each column to about a phrase.
        let width: CGFloat? = languages.count > 2 ? 210 : nil
        var columns = [RecordColumn(title: "Key", profiled: false, width: width)]
        for language in languages {
            let name = Locale.current.localizedString(forIdentifier: language) ?? language
            columns.append(RecordColumn(title: language == sourceLanguage ? "\(name) (source)" : name, toolTip: language, profiled: false, width: width))
        }
        let hasComments = rows.contains { $0.comment?.isEmpty == false }
        if hasComments { columns.append(RecordColumn(title: "Comment", profiled: false, width: width.map { $0 + 60 })) }
        let values: [[GridValue]] = rows.map { row in
            var cells: [GridValue] = [.text(row.key)]
            for language in languages {
                guard let entry = row.entries[language] else {
                    cells.append(.placeholder("Missing"))
                    continue
                }
                var text = entry.value ?? (language == sourceLanguage ? row.key : "")
                if let variation = entry.variation { text = "\(variation): \(text)" }
                switch entry.state {
                case .translated: cells.append(.text(text))
                case .needsReview: cells.append(.status(text, .orange))
                case .new: cells.append(text.isEmpty ? .placeholder("New") : .status(text, .gray))
                case .stale: cells.append(.status(text, .gray))
                case .missing: cells.append(.placeholder("Missing"))
                case .notTranslated: cells.append(.placeholder(language == sourceLanguage ? text : "Not translated"))
                }
            }
            if hasComments { cells.append(row.comment.map { GridValue.secondary($0) } ?? .placeholder("")) }
            return cells
        }
        return RecordTable(columns: columns, rows: values)
    }

    /// Translation progress under each language's title.
    func strip(forColumn column: Int) -> GridHeaderStrip? {
        let index = column - 1
        guard index >= 0, index < languages.count else { return nil }
        let language = languages[index]
        if language == sourceLanguage { return .caption("\(rows.count.formatted()) strings", symbol: nil) }
        let c = completion(language)
        let fraction = c.total == 0 ? 1 : Double(c.done) / Double(c.total)
        var caption = ColumnProfile.percent(fraction)
        if c.review > 0 { caption += " · \(c.review) to review" }
        else if c.total - c.done > 0 { caption += " · \(c.total - c.done) missing" }
        return .progress(fraction, caption: caption)
    }

    // MARK: - String Catalogs

    static func catalog(_ data: Data) -> StringTable? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let strings = json["strings"] as? [String: Any] else { return nil }
        let source = json["sourceLanguage"] as? String ?? "en"
        var languages = Set<String>([source])
        var rows: [Row] = []
        for (key, value) in strings.sorted(by: { $0.key.localizedStandardCompare($1.key) == .orderedAscending }).prefix(maxRows) {
            let info = value as? [String: Any] ?? [:]
            var row = Row(key: key, comment: info["comment"] as? String, entries: [:])
            let shouldTranslate = info["shouldTranslate"] as? Bool ?? true
            for (language, localization) in (info["localizations"] as? [String: Any]) ?? [:] {
                guard languages.count < maxLanguages || languages.contains(language) else { continue }
                languages.insert(language)
                row.entries[language] = entry(localization as? [String: Any] ?? [:])
            }
            if !shouldTranslate {
                for language in languages where row.entries[language] == nil { row.entries[language] = Entry(value: nil, state: .notTranslated) }
            }
            if row.entries[source] == nil { row.entries[source] = Entry(value: key, state: .translated) }
            if info["extractionState"] as? String == "stale" {
                for language in Array(row.entries.keys) where row.entries[language]?.state != .notTranslated {
                    row.entries[language]?.state = .stale
                }
            }
            rows.append(row)
        }
        // A key that's not translatable stays so in languages added later in the loop.
        for i in rows.indices where rows[i].entries.values.contains(where: { $0.state == .notTranslated }) {
            for language in languages where rows[i].entries[language] == nil { rows[i].entries[language] = Entry(value: nil, state: .notTranslated) }
        }
        let others = languages.subtracting([source]).sorted { a, b in
            (Locale.current.localizedString(forIdentifier: a) ?? a).localizedStandardCompare(Locale.current.localizedString(forIdentifier: b) ?? b) == .orderedAscending
        }
        return StringTable(title: "String Catalog", sourceLanguage: source, languages: [source] + others, rows: rows)
    }

    /// A localization's value and state; variations report their "other" form and their worst state.
    private static func entry(_ localization: [String: Any]) -> Entry {
        if let unit = localization["stringUnit"] as? [String: Any] {
            return Entry(value: unit["value"] as? String, state: state(unit["state"] as? String))
        }
        if let variations = localization["variations"] as? [String: Any], let (kind, forms) = variations.first, let cases = forms as? [String: Any] {
            var entries: [String: Entry] = [:]
            for (name, form) in cases { entries[name] = entry(form as? [String: Any] ?? [:]) }
            let preferred = entries["other"] ?? entries.values.first
            let worst = entries.values.map(\.state).max { rank($0) < rank($1) } ?? .translated
            let label = kind == "plural" ? "Plural" : kind == "device" ? "Device" : kind.capitalized
            return Entry(value: preferred?.value, state: worst, variation: "\(label) (\(entries.count))")
        }
        if let substitutions = localization["substitutions"] as? [String: Any], !substitutions.isEmpty {
            return Entry(value: nil, state: .translated, variation: "Substitutions")
        }
        return Entry(value: nil, state: .new)
    }

    private static func rank(_ state: State) -> Int {
        switch state {
        case .translated, .notTranslated: return 0
        case .stale: return 1
        case .needsReview: return 2
        case .new: return 3
        case .missing: return 4
        }
    }

    private static func state(_ raw: String?) -> State {
        switch raw {
        case "translated": return .translated
        case "needs_review": return .needsReview
        case "stale": return .stale
        case "new": return .new
        default: return .translated
        }
    }

    // MARK: - .strings

    /// Key/value pairs in order, with the comment written above each.
    static func parseStrings(_ data: Data) -> [(key: String, value: String, comment: String?)]? {
        if data.starts(with: Array("bplist".utf8)) {
            guard let dictionary = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String] else { return nil }
            return dictionary.keys.sorted().map { ($0, dictionary[$0] ?? "", nil) }
        }
        let text = TextFile.decode(data.prefix(32 * 1024 * 1024)).0
        var result: [(String, String, String?)] = []
        var scanner = StringsScanner(text)
        var pendingComment: String?
        while let token = scanner.next() {
            switch token {
            case .comment(let comment):
                pendingComment = comment
            case .string(let key):
                guard case .equals? = scanner.next(), case .string(let value)? = scanner.next() else {
                    // "key"; on its own means key = key.
                    result.append((key, key, pendingComment))
                    pendingComment = nil
                    continue
                }
                _ = scanner.skipSemicolon()
                result.append((key, value, pendingComment))
                pendingComment = nil
                if result.count >= maxRows { return result }
            case .equals, .semicolon:
                continue
            }
        }
        return result.isEmpty && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : result
    }

    /// A .strings file, joined with its translations in sibling .lproj folders when there are any.
    static func strings(_ url: URL) throws -> StringTable? {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard let pairs = parseStrings(data) else { return nil }
        let folder = url.deletingLastPathComponent()
        let here = folder.pathExtension == "lproj" ? folder.deletingPathExtension().lastPathComponent : nil
        var tables: [(String, [(key: String, value: String, comment: String?)])] = [(here ?? "Value", pairs)]
        if let here {
            let parent = folder.deletingLastPathComponent()
            let siblings = ((try? FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "lproj" && $0.lastPathComponent != folder.lastPathComponent }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
                .prefix(maxLanguages)
            for sibling in siblings {
                let file = sibling.appendingPathComponent(url.lastPathComponent)
                guard let data = try? Data(contentsOf: file, options: .mappedIfSafe), data.count < 16 * 1024 * 1024,
                      let pairs = parseStrings(data) else { continue }
                tables.append((sibling.deletingPathExtension().lastPathComponent, pairs))
            }
        }
        var order: [String] = []
        var rows: [String: Row] = [:]
        for (language, pairs) in tables {
            for pair in pairs {
                if rows[pair.key] == nil {
                    order.append(pair.key)
                    rows[pair.key] = Row(key: pair.key, comment: pair.comment, entries: [:])
                }
                rows[pair.key]?.entries[language] = Entry(value: pair.value, state: .translated)
                if rows[pair.key]?.comment == nil { rows[pair.key]?.comment = pair.comment }
            }
        }
        let languages = tables.map(\.0)
        let source = here ?? "Value"
        return StringTable(title: "Strings", sourceLanguage: tables.count > 1 ? source : nil, languages: languages,
                           rows: order.prefix(maxRows).compactMap { rows[$0] })
    }

    // MARK: - .stringsdict

    struct PluralRule {
        var key: String
        var format: String
        var variable: String
        var forms: [String: String]
    }

    static let pluralForms = ["zero", "one", "two", "few", "many", "other"]

    static func stringsdict(_ data: Data) -> [PluralRule]? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        var rules: [PluralRule] = []
        for key in plist.keys.sorted().prefix(maxRows) {
            guard let entry = plist[key] as? [String: Any] else { continue }
            let format = entry["NSStringLocalizedFormatKey"] as? String ?? ""
            let variables = entry.keys.filter { $0 != "NSStringLocalizedFormatKey" }.sorted()
            if variables.isEmpty { rules.append(PluralRule(key: key, format: format, variable: "", forms: [:])) }
            for variable in variables {
                guard let rule = entry[variable] as? [String: Any] else { continue }
                var forms: [String: String] = [:]
                for form in pluralForms { if let value = rule[form] as? String { forms[form] = value } }
                rules.append(PluralRule(key: key, format: format, variable: variable, forms: forms))
            }
        }
        return rules
    }

    static func stringsdictStore(_ rules: [PluralRule]) -> RecordTable {
        let used = pluralForms.filter { form in rules.contains { $0.forms[form] != nil } }
        var columns = [RecordColumn(title: "Key", profiled: false), RecordColumn(title: "Format", profiled: false), RecordColumn(title: "Variable", profiled: false)]
        columns += used.map { RecordColumn(title: $0.capitalized, profiled: false) }
        let rows: [[GridValue]] = rules.map { rule in
            [.text(rule.key), .secondary(rule.format), .secondary(rule.variable)] + used.map { form in rule.forms[form].map { GridValue.text($0) } ?? .placeholder("") }
        }
        return RecordTable(columns: columns, rows: rows)
    }
}

/// Tokens of the old-style property list format .strings files use.
private struct StringsScanner {
    enum Token { case comment(String), string(String), equals, semicolon }
    private let scalars: [Unicode.Scalar]
    private var index = 0

    init(_ text: String) { scalars = Array(text.unicodeScalars) }

    mutating func skipSemicolon() -> Bool {
        skipSpace()
        if index < scalars.count, scalars[index] == ";" { index += 1; return true }
        return false
    }

    private mutating func skipSpace() {
        while index < scalars.count, CharacterSet.whitespacesAndNewlines.contains(scalars[index]) || scalars[index] == "\u{FEFF}" { index += 1 }
    }

    mutating func next() -> Token? {
        skipSpace()
        guard index < scalars.count else { return nil }
        let c = scalars[index]
        if c == "/", index + 1 < scalars.count, scalars[index + 1] == "*" {
            let start = index + 2
            index = start
            while index + 1 < scalars.count, !(scalars[index] == "*" && scalars[index + 1] == "/") { index += 1 }
            let comment = String(String.UnicodeScalarView(scalars[start..<min(index, scalars.count)]))
            index = min(index + 2, scalars.count)
            return .comment(comment.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if c == "/", index + 1 < scalars.count, scalars[index + 1] == "/" {
            let start = index + 2
            while index < scalars.count, scalars[index] != "\n" { index += 1 }
            return .comment(String(String.UnicodeScalarView(scalars[start..<index])).trimmingCharacters(in: .whitespaces))
        }
        if c == "=" { index += 1; return .equals }
        if c == ";" { index += 1; return .semicolon }
        if c == "\"" {
            index += 1
            var out = String.UnicodeScalarView()
            while index < scalars.count, scalars[index] != "\"" {
                if scalars[index] == "\\", index + 1 < scalars.count {
                    index += 1
                    switch scalars[index] {
                    case "n": out.append("\n")
                    case "t": out.append("\t")
                    case "r": out.append("\r")
                    case "U", "u":
                        var hex = ""
                        while hex.count < 4, index + 1 < scalars.count, scalars[index + 1].properties.isASCIIHexDigit { index += 1; hex.unicodeScalars.append(scalars[index]) }
                        if let value = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(value) { out.append(scalar) }
                    default: out.append(scalars[index])
                    }
                } else {
                    out.append(scalars[index])
                }
                index += 1
            }
            index += 1
            return .string(String(out))
        }
        // Unquoted word.
        let start = index
        while index < scalars.count, !CharacterSet.whitespacesAndNewlines.contains(scalars[index]), scalars[index] != "=", scalars[index] != ";" { index += 1 }
        if index == start { index += 1; return next() }
        return .string(String(String.UnicodeScalarView(scalars[start..<index])))
    }
}
