import Foundation

/// A property list as JSON, for the tree view: dictionaries and arrays as they are, dates as ISO
/// 8601, data as a short hex excerpt with its length.
public enum PropertyListTree {

    static let maxBytes = 16 * 1024 * 1024
    static let maxDepth = 256

    public static func json(from object: Any) -> String? {
        let value = compatible(object, depth: 0)
        guard JSONSerialization.isValidJSONObject(value) || value is String || value is NSNumber,
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes]),
              data.count <= maxBytes else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private static let dates: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static func compatible(_ object: Any, depth: Int) -> Any {
        guard depth < maxDepth else { return "…" }
        switch object {
        case let dictionary as [String: Any]:
            return dictionary.mapValues { compatible($0, depth: depth + 1) }
        case let array as [Any]:
            return array.map { compatible($0, depth: depth + 1) }
        case let string as String:
            return string
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue }
            if !number.doubleValue.isFinite { return number.stringValue }
            return number
        case let date as Date:
            return dates.string(from: date)
        case let data as Data:
            return describe(data)
        default:
            return String(describing: object)
        }
    }

    /// `<0a1b2c3d 4e5f…>  (1,204 bytes)`, as Xcode shows data.
    static func describe(_ data: Data) -> String {
        let shown = data.prefix(16)
        var hex = ""
        for (index, byte) in shown.enumerated() {
            if index > 0 && index % 4 == 0 { hex += " " }
            hex += String(format: "%02x", byte)
        }
        let more = data.count > shown.count ? "…" : ""
        let count = String(localized: "\(data.count) bytes", bundle: .greeceKit, comment: "Length of a data value in a property list’s tree view")
        return "<\(hex)\(more)>  (\(count))"
    }
}
