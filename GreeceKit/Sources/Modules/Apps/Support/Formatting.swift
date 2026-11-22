import Foundation

/// Plain, specific copy for inspector pages: "12 files", "182 MB", "Expires in 3 months".
enum Format {
    static func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file)
    }

    static func bytes(_ value: Int) -> String { bytes(UInt64(max(0, value))) }

    static func date(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .omitted)
    }

    static func dateTime(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    /// "in 3 months", "2 years ago".
    static func relative(_ date: Date, to now: Date = Date()) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = .greeceKitText
        formatter.unitsStyle = .full
        formatter.dateTimeStyle = .named
        return formatter.localizedString(for: date, relativeTo: now)
    }

    /// "Expires in 3 months" / "Expired 2 years ago", with a tone for how soon.
    static func expiry(_ date: Date, now: Date = Date()) -> (text: String, tone: InspectorTone) {
        let remaining = date.timeIntervalSince(now)
        let when = relative(date, to: now)
        if remaining < 0 {
            return (String(localized: "Expired \(when)", bundle: .greeceKit,
                           comment: "A certificate or profile. The argument is a relative time, such as “2 years ago”"), .critical)
        }
        return (String(localized: "Expires \(when)", bundle: .greeceKit,
                       comment: "A certificate or profile. The argument is a relative time, such as “in 3 months”"),
                remaining < 30 * 86_400 ? .caution : .neutral)
    }

    /// Joins non-empty parts with a middle dot.
    static func joined(_ parts: [String?], separator: String = " · ") -> String {
        parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: separator)
    }

    /// "Version 2.1 (214)", or nil when nothing is known. Identical numbers are shown once.
    static func version(_ short: String?, build: String?) -> String? {
        let short = short?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        let build = build?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        switch (short, build) {
        case let (s?, b?) where s == b: return String(localized: "Version \(s)", bundle: .greeceKit, comment: "Under an app’s name. The argument is its version")
        case let (s?, b?): return String(localized: "Version \(s) (\(b))", bundle: .greeceKit, comment: "Under an app’s name. The arguments are its version and build")
        case let (s?, nil): return String(localized: "Version \(s)", bundle: .greeceKit, comment: "Under an app’s name. The argument is its version")
        case let (nil, b?): return String(localized: "Build \(b)", bundle: .greeceKit, comment: "Under an app’s name. The argument is its build number")
        default: return nil
        }
    }

    /// Hex with a space every `group` characters, for fingerprints.
    static func grouped(hex: String, group: Int = 2) -> String {
        var result = ""
        for (index, character) in hex.uppercased().enumerated() {
            if index > 0 && index % group == 0 { result.append(" ") }
            result.append(character)
        }
        return result
    }

    /// Keeps hostile strings from blowing up a layout: single line, bounded length.
    static func clean(_ text: String, limit: Int = 300) -> String {
        var value = text.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        value = String(value.unicodeScalars.filter { $0.value >= 0x20 || $0 == "\n" || $0 == "\t" }.map(Character.init))
        if value.count > limit { value = String(value.prefix(limit)) + "…" }
        return value
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
