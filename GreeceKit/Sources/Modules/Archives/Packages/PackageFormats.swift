import Foundation
import CArchive

/// Small, strict readers for the metadata formats packages use. Every input is hostile: sizes are
/// capped by the caller (`PackageInspector.metadataLimit`) and nothing here recurses deeply.
enum PackageFormats {

    // MARK: - RFC 822 style headers (wheel METADATA, PKG-INFO, Debian control)

    /// "Key: value" lines with indented continuations, up to the first blank line. Keys repeat
    /// (Requires-Dist, Classifier), so every value is kept in order.
    static func headers(_ text: String, continuationJoiner: String = " ") -> [(String, String)] {
        var result: [(String, String)] = []
        for line in text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).prefix(5000) {
            if line.trimmingCharacters(in: .whitespaces).isEmpty { if result.isEmpty { continue } else { break } }
            if line.first == " " || line.first == "\t" {
                if let last = result.popLast() {
                    let piece = line.trimmingCharacters(in: .whitespaces)
                    result.append((last.0, last.1 + (piece == "." ? "\n" : continuationJoiner + piece)))
                }
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { result.append((key, value)) }
        }
        return result
    }

    static func first(_ headers: [(String, String)], _ key: String) -> String? {
        headers.first { $0.0.caseInsensitiveCompare(key) == .orderedSame }?.1.nilIfEmpty
    }

    static func all(_ headers: [(String, String)], _ key: String) -> [String] {
        headers.filter { $0.0.caseInsensitiveCompare(key) == .orderedSame }.map(\.1).filter { !$0.isEmpty }
    }

    // MARK: - JAR manifests

    /// The main section of META-INF/MANIFEST.MF: 72-byte lines continue with a single leading space.
    static func manifest(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        var lastKey: String?
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).prefix(4000) {
            if raw.isEmpty { if result.isEmpty { continue } else { break } }
            if raw.first == " ", let key = lastKey {
                result[key, default: ""] += raw.dropFirst()
                continue
            }
            guard let colon = raw.firstIndex(of: ":") else { continue }
            let key = String(raw[..<colon])
            result[key] = raw[raw.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            lastKey = key
        }
        return result
    }

    /// key=value lines (pom.properties).
    static func properties(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline).prefix(2000) where !line.hasPrefix("#") {
            guard let equals = line.firstIndex(of: "=") else { continue }
            result[line[..<equals].trimmingCharacters(in: .whitespaces)] = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
        }
        return result
    }

    // MARK: - JSON

    /// A JSON object, refusing anything deeply nested or large.
    static func json(_ data: Data) -> [String: Any]? {
        guard data.count <= PackageInspector.metadataLimit, maxDepth(data) <= 64 else { return nil }
        return (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) as? [String: Any]
    }

    private static func maxDepth(_ data: Data) -> Int {
        var depth = 0, deepest = 0
        var inString = false, escaped = false
        for byte in data {
            if inString {
                if escaped { escaped = false } else if byte == 0x5C { escaped = true } else if byte == 0x22 { inString = false }
                continue
            }
            switch byte {
            case 0x22: inString = true
            case 0x7B, 0x5B: depth += 1; deepest = max(deepest, depth)
            case 0x7D, 0x5D: depth -= 1
            default: break
            }
        }
        return deepest
    }

    // MARK: - XML (nuspec, vsixmanifest)

    /// Element paths ("package/metadata/id") with their text and attributes, from a small XML file.
    /// Foundation's parser doesn't resolve external entities; size is capped before parsing.
    final class XMLDigest: NSObject, XMLParserDelegate {
        struct Element { let path: String; var attributes: [String: String]; var text: String }
        private(set) var elements: [Element] = []
        private var stack: [String] = []
        private var open: [Int] = []

        init?(_ data: Data) {
            super.init()
            guard data.count <= PackageInspector.metadataLimit else { return nil }
            let parser = XMLParser(data: data)
            parser.shouldResolveExternalEntities = false
            parser.shouldProcessNamespaces = false
            parser.delegate = self
            guard parser.parse() || !elements.isEmpty else { return nil }
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            guard stack.count < 32, elements.count < 20_000 else { parser.abortParsing(); return }
            let local = name.split(separator: ":").last.map(String.init) ?? name
            stack.append(local)
            open.append(elements.count)
            elements.append(Element(path: stack.joined(separator: "/").lowercased(), attributes: attributes, text: ""))
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard let index = open.last, elements[index].text.count < 20_000 else { return }
            elements[index].text += string
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            stack.removeLast()
            if let index = open.popLast() { elements[index].text = elements[index].text.trimmingCharacters(in: .whitespacesAndNewlines) }
        }

        /// Elements whose path ends with `suffix` ("metadata/id").
        func all(_ suffix: String) -> [Element] {
            let wanted = "/" + suffix.lowercased()
            return elements.filter { ("/" + $0.path).hasSuffix(wanted) }
        }

        func text(_ suffix: String) -> String? { all(suffix).first?.text.nilIfEmpty }
    }

    // MARK: - gzip

    /// Inflates a gzip member in memory, up to `limit` bytes of output.
    static func gunzip(_ data: Data, limit: Int = PackageInspector.metadataLimit) -> Data? {
        guard data.count > 18 else { return nil }
        var stream = z_stream()
        guard inflateInit2_(&stream, 15 + 32, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
        defer { inflateEnd(&stream) }
        var output = Data(count: 0)
        let chunk = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: chunk)
        let ok: Bool = data.withUnsafeBytes { input in
            stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(input.count)
            while true {
                let status: Int32 = buffer.withUnsafeMutableBytes { out in
                    stream.next_out = out.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(chunk)
                    return inflate(&stream, Z_NO_FLUSH)
                }
                output.append(contentsOf: buffer[0..<(chunk - Int(stream.avail_out))])
                if output.count > limit { return false }
                if status == Z_STREAM_END { return true }
                if status != Z_OK { return false }
            }
        }
        stream.next_in = nil
        stream.next_out = nil
        return ok ? output : nil
    }

    // MARK: - Gem metadata (YAML)

    /// The handful of gemspec fields Greece shows, read line by line from metadata.gz's YAML.
    /// Not a YAML parser: it only follows the fixed shape `gem build` writes.
    static func gemspec(_ text: String) -> (fields: [String: String], authors: [String], licenses: [String], dependencies: [String]) {
        var fields: [String: String] = [:]
        var authors: [String] = [], licenses: [String] = [], dependencies: [String] = []
        var list: String?
        var dependency: (name: String?, runtime: Bool, requirement: [String])?
        var inRequirement = false
        func flush() {
            if let current = dependency, let name = current.name, current.runtime {
                let requirement = current.requirement.joined()
                dependencies.append(requirement.isEmpty || requirement == ">= 0" ? name : "\(name) \(requirement)")
            }
            dependency = nil
        }
        func clean(_ value: Substring) -> String {
            var value = value.trimmingCharacters(in: .whitespaces)
            if (value.hasPrefix("'") && value.hasSuffix("'")) || (value.hasPrefix("\"") && value.hasSuffix("\"")), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            return value
        }
        var lastTopKey: String?
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).prefix(20_000) {
            let indent = line.prefix { $0 == " " }.count
            let body = line.dropFirst(indent)
            if indent == 0, let colon = body.firstIndex(of: ":"), !body.hasPrefix("-") {
                flush()
                let key = String(body[..<colon])
                let value = clean(body[body.index(after: colon)...])
                lastTopKey = key
                list = value.isEmpty ? key : nil
                inRequirement = false
                if !value.isEmpty, !value.hasPrefix("!") { fields[key] = value }
                continue
            }
            if indent == 0, body.hasPrefix("- "), let key = list {
                let value = clean(body.dropFirst(2))
                if key == "authors" { authors.append(value) }
                if key == "licenses" { licenses.append(value) }
                if key == "dependencies" { flush(); dependency = (nil, false, []) }
                continue
            }
            if lastTopKey == "version", indent == 2, body.hasPrefix("version:") { fields["version"] = clean(body.dropFirst(8)) }
            if lastTopKey == "required_ruby_version" {
                if body.hasPrefix("- - ") { fields["required_ruby_version", default: ""] += clean(body.dropFirst(4)) + " " }
                if body.hasPrefix("version:") { fields["required_ruby_version", default: ""] += clean(body.dropFirst(8)) }
            }
            if lastTopKey == "dependencies", dependency != nil {
                if indent == 2, body.hasPrefix("name:") { dependency?.name = clean(body.dropFirst(5)) }
                if indent == 2, body.hasPrefix("type:") { dependency?.runtime = clean(body.dropFirst(5)) == ":runtime" }
                if indent == 2, body.hasPrefix("requirement:") { inRequirement = true }
                if indent == 2, body.hasPrefix("prerelease:") || body.hasPrefix("version_requirements:") { inRequirement = false }
                if inRequirement {
                    if body.hasPrefix("- - ") {
                        let separator = dependency?.requirement.isEmpty == false ? ", " : ""
                        dependency?.requirement.append(separator + clean(body.dropFirst(4)) + " ")
                    }
                    if body.hasPrefix("version:") { dependency?.requirement.append(clean(body.dropFirst(8))) }
                }
            }
        }
        flush()
        if let ruby = fields["required_ruby_version"] { fields["required_ruby_version"] = ruby.trimmingCharacters(in: .whitespaces) }
        return (fields, authors, licenses, dependencies)
    }
}

