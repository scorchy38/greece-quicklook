import Foundation

/// The YAML front matter at the top of a Markdown file (`---` … `---`), read as flat fields:
/// plain and quoted scalars, block scalars (`|`, `>`), lists (joined with ", ") and one level of
/// nesting (`metadata:` → `version:` becomes "metadata.version"). Enough for what files put there,
/// without a YAML library.
enum FrontMatter {
    static func fields(_ text: String) -> [String: String] {
        var lines = text.prefix(64 * 1024).components(separatedBy: .newlines)
        if lines.first?.hasPrefix("\u{FEFF}") == true { lines[0].removeFirst() }
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: { ["---", "..."].contains($0.trimmingCharacters(in: .whitespaces)) })
        else { return [:] }
        let body = Array(lines[1..<end])

        var fields: [String: String] = [:]
        var i = 0
        while i < body.count {
            let line = body[i]
            i += 1
            guard let (key, value) = pair(line), indent(line) == 0 else { continue }
            if value.isEmpty {
                // A list or a nested map below.
                var items: [String] = []
                while i < body.count, body[i].trimmingCharacters(in: .whitespaces).isEmpty || indent(body[i]) > 0 {
                    let inner = body[i].trimmingCharacters(in: .whitespaces)
                    i += 1
                    if inner.hasPrefix("- ") { items.append(scalar(String(inner.dropFirst(2)))) }
                    else if let (child, childValue) = pair(inner), !childValue.isEmpty { fields[key + "." + child] = scalar(childValue) }
                }
                if !items.isEmpty { fields[key] = items.joined(separator: ", ") }
            } else if let style = value.first, style == "|" || style == ">", value.count <= 3 {
                // A block scalar: the indented lines below, kept (|) or folded into one paragraph (>).
                var block: [String] = []
                while i < body.count, body[i].trimmingCharacters(in: .whitespaces).isEmpty || indent(body[i]) > 0 {
                    block.append(body[i].trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                while block.last?.isEmpty == true { block.removeLast() }
                fields[key] = style == "|" ? block.joined(separator: "\n") : block.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            } else if value.hasPrefix("[") && value.hasSuffix("]") {
                fields[key] = value.dropFirst().dropLast().split(separator: ",").map { scalar(String($0)) }.joined(separator: ", ")
            } else {
                fields[key] = scalar(value)
            }
        }
        return fields
    }

    private static func indent(_ line: String) -> Int { line.prefix { $0 == " " || $0 == "\t" }.count }

    /// `key: value` (value may be empty), ignoring comments and list items.
    private static func pair(_ line: String) -> (String, String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), !trimmed.hasPrefix("- "), let colon = trimmed.firstIndex(of: ":") else { return nil }
        let key = trimmed[..<colon].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        let value = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, !key.contains(" ") || key.count < 40 else { return nil }
        return (key, value)
    }

    /// A scalar without its quotes or a trailing comment.
    private static func scalar(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespaces)
        if let quote = value.first, quote == "\"" || quote == "'", value.count >= 2, value.last == quote {
            value = String(value.dropFirst().dropLast())
            if quote == "\"" { value = value.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\n", with: "\n") }
            else { value = value.replacingOccurrences(of: "''", with: "'") }
            return value
        }
        if let comment = value.range(of: " #") { value = String(value[..<comment.lowerBound]) }
        return value.trimmingCharacters(in: .whitespaces)
    }
}
