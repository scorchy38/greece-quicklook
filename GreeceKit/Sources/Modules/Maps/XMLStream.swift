import Foundation

/// Streams an XML document to two callbacks with local element names (namespace prefixes
/// dropped). Never resolves external entities, keeps text per element capped, and stops at a
/// deadline, so hostile files can't hang or balloon the preview.
final class XMLStream: NSObject, XMLParserDelegate {
    /// Element names from the root to the current element's parent.
    private(set) var path: [String] = []
    var onStart: (_ name: String, _ attributes: [String: String]) -> Void = { _, _ in }
    /// The element's own text (trimmed), when it ends.
    var onEnd: (_ name: String, _ text: String) -> Void = { _, _ in }

    private var texts: [String] = []
    private let deadline: CFAbsoluteTime
    private let maxText: Int
    private var events = 0
    private(set) var timedOut = false
    private(set) var stopped = false
    /// The XML was malformed (as opposed to stopped by a limit).
    private(set) var failed = false
    private weak var parser: XMLParser?

    init(deadline: CFAbsoluteTime, maxText: Int = 64 * 1024) {
        self.deadline = deadline
        self.maxText = maxText
    }

    var parent: String? { path.count >= 2 ? path[path.count - 2] : nil }
    var current: String? { path.last }

    func within(_ name: String) -> Bool { path.contains(name) }

    /// Parses `data`. Returns false if the XML is malformed before anything useful was read.
    @discardableResult
    func parse(_ data: Data) -> Bool {
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        parser.delegate = self
        self.parser = parser
        let ok = parser.parse()
        failed = !ok && !stopped
        return ok || stopped || events > 0
    }

    func stop() {
        stopped = true
        parser?.abortParsing()
    }

    private func tick() {
        events += 1
        if events & 1023 == 0, CFAbsoluteTimeGetCurrent() > deadline {
            timedOut = true
            stop()
        }
    }

    static func localName(_ qualified: String) -> String {
        if let colon = qualified.lastIndex(of: ":") { return String(qualified[qualified.index(after: colon)...]) }
        return qualified
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        guard !stopped else { return }
        tick()
        let name = XMLStream.localName(elementName)
        path.append(name)
        texts.append("")
        if path.count > 256 { stop(); return }
        onStart(name, attributes)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        guard !stopped else { return }
        tick()
        let name = XMLStream.localName(elementName)
        let text = (texts.popLast() ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        onEnd(name, text)
        if !path.isEmpty { path.removeLast() }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard !stopped, !texts.isEmpty else { return }
        tick()
        if texts[texts.count - 1].utf8.count < maxText { texts[texts.count - 1] += string }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard !stopped, !texts.isEmpty else { return }
        if texts[texts.count - 1].utf8.count < maxText {
            texts[texts.count - 1] += String(decoding: CDATABlock.prefix(maxText), as: UTF8.self)
        }
    }

    func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? { nil }
}

/// ISO 8601 timestamps ("2024-05-01T10:15:30Z", fractions and offsets allowed), without a formatter.
enum ISOTime {
    static func parse(_ text: String) -> Double? {
        let b = Array(text.utf8.prefix(40))
        func digits(_ start: Int, _ count: Int) -> Int? {
            guard start + count <= b.count else { return nil }
            var value = 0
            for i in start..<(start + count) {
                guard b[i] >= 0x30, b[i] <= 0x39 else { return nil }
                value = value * 10 + Int(b[i] - 0x30)
            }
            return value
        }
        guard let year = digits(0, 4), b.count >= 10, b[4] == 0x2D, let month = digits(5, 2), b[7] == 0x2D, let day = digits(8, 2),
              (1...12).contains(month), (1...31).contains(day) else { return nil }
        var hour = 0, minute = 0, second = 0.0
        var i = 10
        if b.count > 10, b[10] == 0x54 || b[10] == 0x20 {
            guard let h = digits(11, 2), b.count > 13, b[13] == 0x3A, let m = digits(14, 2) else { return nil }
            hour = h; minute = m
            i = 16
            if b.count > 16, b[16] == 0x3A, let s = digits(17, 2) {
                second = Double(s)
                i = 19
                if b.count > 19, b[19] == 0x2E || b[19] == 0x2C {
                    var scale = 0.1
                    i = 20
                    while i < b.count, b[i] >= 0x30, b[i] <= 0x39 { second += Double(b[i] - 0x30) * scale; scale /= 10; i += 1 }
                }
            }
        }
        var offset = 0
        if i < b.count, b[i] == 0x2B || b[i] == 0x2D {
            let sign = b[i] == 0x2B ? 1 : -1
            if let oh = digits(i + 1, 2) {
                var om = 0
                if let m = digits(i + 4, 2), i + 3 < b.count, b[i + 3] == 0x3A { om = m } else if let m = digits(i + 3, 2) { om = m }
                offset = sign * (oh * 3600 + om * 60)
            }
        }
        // Days from civil (Howard Hinnant).
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        let days = era * 146_097 + doe - 719_468
        return Double(days * 86_400 + hour * 3600 + minute * 60 - offset) + second
    }
}
