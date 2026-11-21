import Foundation

/// A small, bounded XML tree for installer metadata (xar tables of contents, Distribution and
/// PackageInfo files). Entities are never resolved, documents that declare their own entities are
/// refused, and element count, depth, text size and parse time are all capped.
final class PackageXMLNode {
    let name: String
    let attributes: [String: String]
    private(set) var children: [PackageXMLNode] = []
    fileprivate(set) var text = ""

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }

    subscript(attribute: String) -> String? { attributes[attribute] }

    func child(_ name: String) -> PackageXMLNode? { children.first { $0.name == name } }
    func children(_ name: String) -> [PackageXMLNode] { children.filter { $0.name == name } }

    /// The trimmed text of a direct child.
    func value(_ name: String) -> String? {
        child(name).map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    var trimmedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Every descendant with this name, depth first, bounded.
    func descendants(_ name: String, limit: Int = 10_000) -> [PackageXMLNode] {
        var result: [PackageXMLNode] = []
        var stack: [PackageXMLNode] = [self]
        while let node = stack.popLast(), result.count < limit {
            for child in node.children.reversed() { stack.append(child) }
            if node !== self && node.name == name { result.append(node) }
        }
        return result
    }

    fileprivate func append(_ child: PackageXMLNode) { children.append(child) }

    struct Limits {
        var elements = 200_000
        var depth = 64
        var textPerElement = 1 << 20
        var totalText = 16 << 20
        var seconds: TimeInterval = 2
    }

    enum Failure: Error { case refused, malformed, tooLarge }

    /// Parses a whole document and returns its root element.
    static func parse(_ data: Data, limits: Limits = Limits()) throws -> PackageXMLNode {
        // Installer metadata never needs a DTD; documents that bring their own entities are hostile.
        if data.firstRange(of: Array("<!ENTITY".utf8)) != nil { throw Failure.refused }
        let builder = Builder(limits: limits)
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        parser.delegate = builder
        let ok = parser.parse()
        if builder.exceeded { throw Failure.tooLarge }
        guard let root = builder.root else { throw Failure.malformed }
        // A truncated document still yields what was read before the error; callers decide.
        if !ok && root.children.isEmpty { throw Failure.malformed }
        return root
    }

    private final class Builder: NSObject, XMLParserDelegate {
        let limits: Limits
        let deadline: Date
        var root: PackageXMLNode?
        var stack: [PackageXMLNode] = []
        var elements = 0
        var textTotal = 0
        var exceeded = false

        init(limits: Limits) {
            self.limits = limits
            deadline = Date().addingTimeInterval(limits.seconds)
        }

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            elements += 1
            if elements > limits.elements || stack.count >= limits.depth || (elements % 512 == 0 && Date() > deadline) {
                exceeded = true
                parser.abortParsing()
                return
            }
            let node = PackageXMLNode(name: elementName, attributes: attributes)
            if let parent = stack.last { parent.append(node) } else if root == nil { root = node }
            stack.append(node)
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
            if !stack.isEmpty { stack.removeLast() }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { appendText(string, parser) }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            appendText(String(decoding: CDATABlock, as: UTF8.self), parser)
        }

        private func appendText(_ string: String, _ parser: XMLParser) {
            guard let node = stack.last else { return }
            let length = string.utf8.count
            textTotal += length
            if textTotal > limits.totalText { exceeded = true; parser.abortParsing(); return }
            if node.text.utf8.count + length <= limits.textPerElement { node.text += string }
        }

        func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? { nil }
    }
}
