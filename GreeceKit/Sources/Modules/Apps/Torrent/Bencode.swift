import Foundation

/// A bencoded value (BitTorrent metadata). Parsing is iterative-safe: depth, count and length are
/// all capped, so hostile files can't exhaust the stack or memory.
indirect enum Bencode: Equatable {
    case integer(Int64)
    case bytes(Data)
    case list([Bencode])
    case dictionary([(key: Data, value: Bencode)])

    static func == (lhs: Bencode, rhs: Bencode) -> Bool {
        switch (lhs, rhs) {
        case let (.integer(a), .integer(b)): return a == b
        case let (.bytes(a), .bytes(b)): return a == b
        case let (.list(a), .list(b)): return a == b
        case let (.dictionary(a), .dictionary(b)):
            return a.count == b.count && zip(a, b).allSatisfy { $0.key == $1.key && $0.value == $1.value }
        default: return false
        }
    }

    enum Failure: Error, Equatable { case malformed, tooDeep, tooLarge }

    struct Limits {
        var depth = 64
        var nodes = 2_000_000
    }

    /// Parses a whole document. `infoRange` receives the byte range of the top-level "info" value,
    /// whose SHA-1 is the torrent's identity.
    static func parse(_ data: Data, limits: Limits = Limits(), infoRange: inout Range<Int>?) throws -> Bencode {
        let bytes = [UInt8](data)
        var parser = Parser(bytes: bytes, limits: limits)
        let value = try parser.value(depth: 0)
        infoRange = parser.infoRange
        return value
    }

    static func parse(_ data: Data) throws -> Bencode {
        var ignored: Range<Int>?
        return try parse(data, infoRange: &ignored)
    }

    private struct Parser {
        let bytes: [UInt8]
        let limits: Limits
        var position = 0
        var nodes = 0
        var infoRange: Range<Int>?

        mutating func value(depth: Int) throws -> Bencode {
            guard depth < limits.depth else { throw Failure.tooDeep }
            nodes += 1
            guard nodes <= limits.nodes else { throw Failure.tooLarge }
            guard position < bytes.count else { throw Failure.malformed }
            switch bytes[position] {
            case UInt8(ascii: "i"):
                position += 1
                guard let end = bytes[position...].firstIndex(of: UInt8(ascii: "e")), end - position <= 21,
                      let number = Int64(String(decoding: bytes[position..<end], as: UTF8.self)) else { throw Failure.malformed }
                position = end + 1
                return .integer(number)
            case UInt8(ascii: "l"):
                position += 1
                var items: [Bencode] = []
                while position < bytes.count && bytes[position] != UInt8(ascii: "e") {
                    items.append(try value(depth: depth + 1))
                }
                guard position < bytes.count else { throw Failure.malformed }
                position += 1
                return .list(items)
            case UInt8(ascii: "d"):
                position += 1
                var entries: [(key: Data, value: Bencode)] = []
                while position < bytes.count && bytes[position] != UInt8(ascii: "e") {
                    guard case .bytes(let key) = try string() else { throw Failure.malformed }
                    let start = position
                    let item = try value(depth: depth + 1)
                    if depth == 0 && key == Data("info".utf8) { infoRange = start..<position }
                    entries.append((key, item))
                }
                guard position < bytes.count else { throw Failure.malformed }
                position += 1
                return .dictionary(entries)
            case UInt8(ascii: "0")...UInt8(ascii: "9"):
                return try string()
            default:
                throw Failure.malformed
            }
        }

        mutating func string() throws -> Bencode {
            guard let colon = bytes[position...].prefix(21).firstIndex(of: UInt8(ascii: ":")),
                  let length = Int(String(decoding: bytes[position..<colon], as: UTF8.self)), length >= 0,
                  colon + 1 + length <= bytes.count else { throw Failure.malformed }
            let start = colon + 1
            position = start + length
            return .bytes(Data(bytes[start..<position]))
        }
    }

    // MARK: Access

    subscript(key: String) -> Bencode? {
        guard case .dictionary(let entries) = self else { return nil }
        let raw = Data(key.utf8)
        return entries.first { $0.key == raw }?.value
    }

    var string: String? {
        guard case .bytes(let data) = self else { return nil }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }

    var data: Data? { if case .bytes(let data) = self { return data } else { return nil } }
    var integer: Int64? { if case .integer(let value) = self { return value } else { return nil } }
    var list: [Bencode]? { if case .list(let items) = self { return items } else { return nil } }
    var keys: [String] {
        guard case .dictionary(let entries) = self else { return [] }
        return entries.map { String(decoding: $0.key, as: UTF8.self) }
    }
}
