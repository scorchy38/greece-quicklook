import Foundation

/// JSON that keeps its keys in order (JSONSerialization doesn't), with numbers as written.
indirect enum JSONValue: Equatable {
    case object([(String, JSONValue)])
    case array([JSONValue])
    case string(String)
    case number(String)
    case bool(Bool)
    case null

    static func == (lhs: JSONValue, rhs: JSONValue) -> Bool {
        switch (lhs, rhs) {
        case (.object(let a), .object(let b)): return a.count == b.count && zip(a, b).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        case (.array(let a), .array(let b)): return a == b
        case (.string(let a), .string(let b)), (.number(let a), .number(let b)): return a == b
        case (.bool(let a), .bool(let b)): return a == b
        case (.null, .null): return true
        default: return false
        }
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let pairs) = self { return pairs.first { $0.0 == key }?.1 }
        return nil
    }

    var string: String? {
        switch self {
        case .string(let s), .number(let s): return s
        case .bool(let b): return b ? "true" : "false"
        default: return nil
        }
    }

    /// One line of JSON, cut off after about `limit` characters.
    func compact(limit: Int = 300) -> String {
        var out = ""
        write(into: &out, limit: limit)
        return out.count > limit ? String(out.prefix(limit)) + "…" : out
    }

    private func write(into out: inout String, limit: Int) {
        guard out.utf8.count <= limit + 8 else { return }
        switch self {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .number(let n): out += n
        case .string(let s): out += JSONValue.quoted(s)
        case .array(let items):
            out += "["
            for (i, item) in items.enumerated() {
                if i > 0 { out += ", " }
                item.write(into: &out, limit: limit)
                if out.utf8.count > limit { break }
            }
            out += "]"
        case .object(let pairs):
            out += "{"
            for (i, (key, value)) in pairs.enumerated() {
                if i > 0 { out += ", " }
                out += JSONValue.quoted(key) + ": "
                value.write(into: &out, limit: limit)
                if out.utf8.count > limit { break }
            }
            out += "}"
        }
    }

    static func quoted(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars.prefix(400) {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            default:
                if scalar.value < 0x20 { out += String(format: "\\u%04x", scalar.value) } else { out.unicodeScalars.append(scalar) }
            }
        }
        return out + "\""
    }
}

/// A strict, bounded JSON reader: depth-limited, never recursing past `maxDepth`.
struct JSONReader {
    enum Failure: Error { case invalid, tooDeep }

    private let bytes: UnsafeBufferPointer<UInt8>
    private var index = 0
    private let maxDepth: Int

    private init(_ bytes: UnsafeBufferPointer<UInt8>, maxDepth: Int) {
        self.bytes = bytes
        self.maxDepth = maxDepth
    }

    static func parse(_ data: Data, maxDepth: Int = 64) throws -> JSONValue {
        try data.withUnsafeBytes { raw in
            try parse(raw.bindMemory(to: UInt8.self), maxDepth: maxDepth)
        }
    }

    static func parse(_ bytes: UnsafeBufferPointer<UInt8>, maxDepth: Int = 64) throws -> JSONValue {
        var reader = JSONReader(bytes, maxDepth: maxDepth)
        reader.skipSpace()
        // A byte-order mark.
        if reader.remaining >= 3, bytes[reader.index] == 0xEF, bytes[reader.index + 1] == 0xBB, bytes[reader.index + 2] == 0xBF { reader.index += 3 }
        let value = try reader.value(depth: 0)
        reader.skipSpace()
        guard reader.index == bytes.count else { throw Failure.invalid }
        return value
    }

    private var remaining: Int { bytes.count - index }

    private mutating func skipSpace() {
        while index < bytes.count {
            switch bytes[index] {
            case 0x20, 0x09, 0x0A, 0x0D: index += 1
            default: return
            }
        }
    }

    private mutating func value(depth: Int) throws -> JSONValue {
        guard depth < maxDepth else { throw Failure.tooDeep }
        skipSpace()
        guard index < bytes.count else { throw Failure.invalid }
        switch bytes[index] {
        case UInt8(ascii: "{"):
            index += 1
            var pairs: [(String, JSONValue)] = []
            skipSpace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "}") { index += 1; return .object(pairs) }
            while true {
                skipSpace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw Failure.invalid }
                let key = try string()
                skipSpace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { throw Failure.invalid }
                index += 1
                pairs.append((key, try value(depth: depth + 1)))
                skipSpace()
                guard index < bytes.count else { throw Failure.invalid }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                if bytes[index] == UInt8(ascii: "}") { index += 1; return .object(pairs) }
                throw Failure.invalid
            }
        case UInt8(ascii: "["):
            index += 1
            var items: [JSONValue] = []
            skipSpace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "]") { index += 1; return .array(items) }
            while true {
                items.append(try value(depth: depth + 1))
                skipSpace()
                guard index < bytes.count else { throw Failure.invalid }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                if bytes[index] == UInt8(ascii: "]") { index += 1; return .array(items) }
                throw Failure.invalid
            }
        case UInt8(ascii: "\""):
            return .string(try string())
        case UInt8(ascii: "t"):
            try literal("true"); return .bool(true)
        case UInt8(ascii: "f"):
            try literal("false"); return .bool(false)
        case UInt8(ascii: "n"):
            try literal("null"); return .null
        default:
            return .number(try number())
        }
    }

    private mutating func literal(_ word: String) throws {
        for byte in word.utf8 {
            guard index < bytes.count, bytes[index] == byte else { throw Failure.invalid }
            index += 1
        }
    }

    private mutating func number() throws -> String {
        let start = index
        if index < bytes.count, bytes[index] == UInt8(ascii: "-") { index += 1 }
        var digits = 0
        while index < bytes.count {
            let b = bytes[index]
            if (b >= 48 && b <= 57) { digits += 1 }
            else if b != UInt8(ascii: ".") && b != UInt8(ascii: "e") && b != UInt8(ascii: "E") && b != UInt8(ascii: "+") && b != UInt8(ascii: "-") { break }
            index += 1
        }
        guard digits > 0, index - start < 400 else { throw Failure.invalid }
        return String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<index]), as: UTF8.self)
    }

    private mutating func string() throws -> String {
        index += 1 // opening quote
        let start = index
        var escaped = false
        // Fast path: no escapes.
        while index < bytes.count {
            let b = bytes[index]
            if b == UInt8(ascii: "\"") { break }
            if b == UInt8(ascii: "\\") { escaped = true; break }
            index += 1
        }
        guard index < bytes.count else { throw Failure.invalid }
        if !escaped {
            let text = String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<index]), as: UTF8.self)
            index += 1
            return text
        }
        var out = [UInt8](bytes[start..<index])
        while index < bytes.count {
            let b = bytes[index]
            if b == UInt8(ascii: "\"") { index += 1; return String(decoding: out, as: UTF8.self) }
            if b != UInt8(ascii: "\\") { out.append(b); index += 1; continue }
            index += 1
            guard index < bytes.count else { throw Failure.invalid }
            let e = bytes[index]
            index += 1
            switch e {
            case UInt8(ascii: "n"): out.append(0x0A)
            case UInt8(ascii: "t"): out.append(0x09)
            case UInt8(ascii: "r"): out.append(0x0D)
            case UInt8(ascii: "b"): out.append(0x08)
            case UInt8(ascii: "f"): out.append(0x0C)
            case UInt8(ascii: "u"):
                guard var scalar = hex4() else { throw Failure.invalid }
                // Surrogate pairs.
                if scalar >= 0xD800, scalar < 0xDC00, remaining >= 6, bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u") {
                    index += 2
                    if let low = hex4(), low >= 0xDC00, low < 0xE000 { scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00) }
                }
                out.append(contentsOf: Array(String(Unicode.Scalar(scalar).map(Character.init) ?? "\u{FFFD}").utf8))
            default: out.append(e)
            }
        }
        throw Failure.invalid
    }

    private mutating func hex4() -> UInt32? {
        guard remaining >= 4 else { return nil }
        var value: UInt32 = 0
        for _ in 0..<4 {
            let b = bytes[index]
            let digit: UInt32
            switch b {
            case 48...57: digit = UInt32(b - 48)
            case 65...70: digit = UInt32(b - 55)
            case 97...102: digit = UInt32(b - 87)
            default: return nil
            }
            value = value * 16 + digit
            index += 1
        }
        return value
    }
}
