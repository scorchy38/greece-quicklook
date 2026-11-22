import Foundation

/// One reference from a .bib file. Field values keep their LaTeX (accents, math, braces); the
/// page renders them, and `plain` gives readable text for thumbnails.
struct BibEntry: Codable, Equatable {
    var type: String
    var key: String
    var fields: [String: String]

    func plain(_ name: String) -> String? {
        fields[name].map { TeXText.tidy(TeXText.plain($0)) }.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Last names of the authors (or editors), for "Knuth et al." labels.
    var authorSurnames: [String] {
        guard let raw = fields["author"] ?? fields["editor"] else { return [] }
        return BibTeX.names(raw).map { name in
            if name.lowercased() == "others" { return "et al." }
            if let comma = BibTeX.topLevelComma(name) { return TeXText.tidy(TeXText.plain(String(name[..<comma]))) }
            let words = BibTeX.splitWords(name)
            return TeXText.tidy(TeXText.plain(words.last ?? name))
        }
    }

    var year: String? { plain("year") ?? fields["date"].map { String($0.prefix(4)) } }
}

struct BibLibrary {
    var entries: [BibEntry] = []
    var strings: [String: String] = [:]
    var preambles: [String] = []
    var comments = 0
    var truncated = false
}

/// A forgiving BibTeX reader: @string macros and `#` concatenation, @preamble and @comment,
/// braces or quotes, crossref inheritance. Malformed entries are skipped, never fatal.
enum BibTeX {
    static let entryLimit = 20_000
    static let valueLimit = 64 * 1024

    private static let months: [String: String] = [
        "jan": "January", "feb": "February", "mar": "March", "apr": "April", "may": "May", "jun": "June",
        "jul": "July", "aug": "August", "sep": "September", "oct": "October", "nov": "November", "dec": "December",
    ]

    static func parse(_ text: String, limit: Int = entryLimit) -> BibLibrary {
        var library = BibLibrary()
        let s = Array(text.unicodeScalars)
        var i = 0
        let deadline = Date().addingTimeInterval(2)

        func skipSpace() { while i < s.count, s[i].properties.isWhitespace { i += 1 } }
        func identifier() -> String {
            var name = ""
            while i < s.count, !s[i].properties.isWhitespace, !"{}(),=#\"@%".unicodeScalars.contains(s[i]) { name.unicodeScalars.append(s[i]); i += 1 }
            return name
        }
        /// {balanced} without the outer braces.
        func braced() -> String {
            var depth = 0
            var out = String.UnicodeScalarView()
            while i < s.count {
                let c = s[i]
                if c == "\\" && i + 1 < s.count { if out.count < valueLimit { out.append(c); out.append(s[i + 1]) }; i += 2; continue }
                if c == "{" { depth += 1; if depth == 1 { i += 1; continue } }
                if c == "}" { depth -= 1; if depth == 0 { i += 1; break } }
                if out.count < valueLimit { out.append(c) }
                i += 1
            }
            return String(out)
        }
        func quoted() -> String {
            i += 1
            var depth = 0
            var out = String.UnicodeScalarView()
            while i < s.count {
                let c = s[i]
                if c == "\\" && i + 1 < s.count { if out.count < valueLimit { out.append(c); out.append(s[i + 1]) }; i += 2; continue }
                if c == "{" { depth += 1 } else if c == "}" { depth -= 1 } else if c == "\"" && depth <= 0 { i += 1; break }
                if out.count < valueLimit { out.append(c) }
                i += 1
            }
            return String(out)
        }
        /// value # value # …
        func value() -> String {
            var parts: [String] = []
            for _ in 0..<64 {
                skipSpace()
                guard i < s.count else { break }
                let c = s[i]
                if c == "{" { parts.append(braced()) }
                else if c == "\"" { parts.append(quoted()) }
                else {
                    let word = identifier()
                    if word.isEmpty { break }
                    if word.allSatisfy(\.isNumber) { parts.append(word) }
                    else { parts.append(library.strings[word.lowercased()] ?? months[word.lowercased()] ?? word) }
                }
                skipSpace()
                if i < s.count, s[i] == "#" { i += 1; continue }
                break
            }
            return parts.joined().split(whereSeparator: { $0 == "\n" || $0 == "\r" || $0 == "\t" || $0 == " " }).joined(separator: " ")
        }
        func skipToClose(_ close: Unicode.Scalar) {
            var depth = 1
            while i < s.count {
                let c = s[i]
                if c == "{" || (close == ")" && c == "(") { depth += 1 }
                if c == "}" || c == ")" { if c == close || c == "}" { depth -= 1 } }
                i += 1
                if depth == 0 { break }
            }
        }

        while i < s.count {
            if library.entries.count >= limit { library.truncated = true; break }
            if library.entries.count % 256 == 0, Date() > deadline { library.truncated = true; break }
            guard s[i] == "@" else { i += 1; continue }
            i += 1
            skipSpace()
            let type = identifier().lowercased()
            skipSpace()
            guard i < s.count, s[i] == "{" || s[i] == "(" else { continue }
            let close: Unicode.Scalar = s[i] == "{" ? "}" : ")"
            i += 1
            switch type {
            case "comment":
                library.comments += 1
                if close == "}" { i -= 1; _ = braced() } else { skipToClose(close) }
            case "preamble":
                library.preambles.append(value())
                skipSpace()
                if i < s.count, s[i] == close { i += 1 }
            case "string":
                skipSpace()
                let name = identifier().lowercased()
                skipSpace()
                if i < s.count, s[i] == "=" { i += 1 }
                let v = value()
                if !name.isEmpty { library.strings[name] = v }
                skipSpace()
                if i < s.count, s[i] == close { i += 1 }
            case "":
                continue
            default:
                skipSpace()
                var key = ""
                while i < s.count, s[i] != ",", s[i] != close, !s[i].properties.isWhitespace || key.isEmpty, key.unicodeScalars.count < 300 {
                    if s[i].properties.isWhitespace { i += 1; continue }
                    key.unicodeScalars.append(s[i]); i += 1
                }
                skipSpace()
                var fields: [String: String] = [:]
                var malformed = false
                while i < s.count {
                    skipSpace()
                    guard i < s.count else { break }
                    if s[i] == "," { i += 1; continue }
                    if s[i] == close { i += 1; break }
                    if s[i] == "@" { malformed = true; break }
                    let name = identifier().lowercased()
                    skipSpace()
                    guard !name.isEmpty, i < s.count, s[i] == "=" else {
                        // Not a field: skip to the next comma or the entry's end.
                        while i < s.count, s[i] != ",", s[i] != close, s[i] != "@" { i += 1 }
                        continue
                    }
                    i += 1
                    let v = value()
                    if fields.count < 200, fields[name] == nil { fields[name] = v }
                }
                if !key.isEmpty || !fields.isEmpty {
                    library.entries.append(BibEntry(type: type, key: key, fields: fields))
                }
                _ = malformed
            }
        }
        resolveCrossReferences(&library.entries)
        return library
    }

    /// Entries inherit missing fields from the entry they cross-reference (a paper from its proceedings).
    static func resolveCrossReferences(_ entries: inout [BibEntry]) {
        var byKey: [String: BibEntry] = [:]
        for entry in entries where byKey[entry.key.lowercased()] == nil { byKey[entry.key.lowercased()] = entry }
        for index in entries.indices {
            guard let ref = entries[index].fields["crossref"]?.lowercased(), let parent = byKey[ref] else { continue }
            for (name, value) in parent.fields {
                if name == "title" {
                    // The proceedings' title is the paper's booktitle.
                    if entries[index].fields["booktitle"] == nil { entries[index].fields["booktitle"] = value }
                } else if entries[index].fields[name] == nil {
                    entries[index].fields[name] = value
                }
            }
        }
    }

    /// "A and B and others" split at top-level " and ".
    static func names(_ raw: String) -> [String] {
        var parts: [String] = []
        var depth = 0
        var current = ""
        let words = raw.split(separator: " ", omittingEmptySubsequences: true)
        for word in words {
            for c in word { if c == "{" { depth += 1 } else if c == "}" { depth -= 1 } }
            if depth == 0 && word.lowercased() == "and" {
                parts.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
                continue
            }
            current += (current.isEmpty ? "" : " ") + word
        }
        if !current.isEmpty { parts.append(current.trimmingCharacters(in: .whitespaces)) }
        return parts.filter { !$0.isEmpty }
    }

    static func topLevelComma(_ name: String) -> String.Index? {
        var depth = 0
        for index in name.indices {
            let c = name[index]
            if c == "{" { depth += 1 } else if c == "}" { depth -= 1 } else if c == "," && depth == 0 { return index }
        }
        return nil
    }

    static func splitWords(_ name: String) -> [String] {
        var words: [String] = []
        var depth = 0
        var current = ""
        for c in name {
            if c == "{" { depth += 1 } else if c == "}" { depth -= 1 }
            if c == " " && depth == 0 { if !current.isEmpty { words.append(current) }; current = ""; continue }
            current.append(c)
        }
        if !current.isEmpty { words.append(current) }
        return words
    }

    /// "Vaswani et al. 2017" style label for thumbnails.
    static func shortCitation(_ entry: BibEntry) -> String {
        let names = entry.authorSurnames.filter { $0 != "et al." }
        let author: String
        switch names.count {
        case 0: author = entry.plain("organization") ?? entry.plain("publisher") ?? entry.key
        case 1: author = names[0] + (entry.authorSurnames.contains("et al.") ? " et al." : "")
        case 2: author = "\(names[0]) and \(names[1])"
        default: author = "\(names[0]) et al."
        }
        return [author, entry.year].compactMap { $0 }.joined(separator: ", ")
    }

    static let typeNames: [String: String] = [
        "article": "Article", "book": "Book", "booklet": "Booklet", "inbook": "Chapter", "incollection": "In Collection",
        "inproceedings": "Conference Paper", "conference": "Conference Paper", "manual": "Manual", "mastersthesis": "Master’s Thesis",
        "misc": "Misc", "phdthesis": "PhD Thesis", "proceedings": "Proceedings", "techreport": "Report", "unpublished": "Unpublished",
        "online": "Online", "electronic": "Online", "www": "Online", "thesis": "Thesis", "report": "Report", "software": "Software",
        "dataset": "Dataset", "patent": "Patent", "collection": "Collection", "preprint": "Preprint",
    ]
}
