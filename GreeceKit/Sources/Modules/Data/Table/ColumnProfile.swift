import Foundation

/// Parses numbers and dates the way they appear in exported data, without Foundation formatters.
enum DataValueParser {
    /// Values that mean "nothing here".
    static func isEmpty(_ text: String) -> Bool {
        if text.isEmpty { return true }
        let utf8 = text.utf8
        if utf8.count > 4 { return utf8.allSatisfy { $0 == 0x20 || $0 == 0x09 } }
        switch text {
        case "null", "NULL", "Null", "None", "NA", "N/A", "n/a", "NaN", "nan", "nil": return true
        default: return utf8.allSatisfy { $0 == 0x20 || $0 == 0x09 }
        }
    }

    /// 1,234.5  -12%  $40  1e6  (+ "€", "£", "¥" prefixes). Nil for anything else.
    static func number(_ text: String) -> Double? {
        number(text, integer: nil)
    }

    static func number(_ text: String, integer: UnsafeMutablePointer<Bool>?) -> Double? {
        var bytes = Array(text.utf8)
        guard !bytes.isEmpty, bytes.count < 48 else { return nil }
        // Trim ASCII spaces.
        while let last = bytes.last, last == 0x20 || last == 0x09 { bytes.removeLast() }
        var start = 0
        while start < bytes.count, bytes[start] == 0x20 || bytes[start] == 0x09 { start += 1 }
        guard start < bytes.count else { return nil }
        var clean: [UInt8] = []
        clean.reserveCapacity(bytes.count + 1)
        var i = start
        // Sign, then an optional currency symbol ("-$5" and "$-5").
        if bytes[i] == UInt8(ascii: "-") || bytes[i] == UInt8(ascii: "+") { clean.append(bytes[i]); i += 1 }
        if i < bytes.count, bytes[i] == UInt8(ascii: "$") { i += 1 }
        else if i + 1 < bytes.count, bytes[i] == 0xC2, bytes[i + 1] == 0xA3 || bytes[i + 1] == 0xA5 { i += 2 }   // £ ¥
        else if i + 2 < bytes.count, bytes[i] == 0xE2, bytes[i + 1] == 0x82, bytes[i + 2] == 0xAC { i += 3 }  // €
        if clean.isEmpty, i < bytes.count, bytes[i] == UInt8(ascii: "-") || bytes[i] == UInt8(ascii: "+") { clean.append(bytes[i]); i += 1 }
        var digits = 0, dots = 0, exponent = false, groupDigits = -1
        var end = bytes.count
        if end > i, bytes[end - 1] == UInt8(ascii: "%") { end -= 1 }
        while i < end {
            let b = bytes[i]
            if b >= 48 && b <= 57 {
                clean.append(b); digits += 1
                if groupDigits >= 0 { groupDigits += 1 }
            } else if b == UInt8(ascii: ",") {
                // Thousands separators only between groups of three digits, before any point.
                guard digits > 0, dots == 0, !exponent, groupDigits == -1 || groupDigits == 3 else { return nil }
                groupDigits = 0
            } else if b == UInt8(ascii: ".") {
                guard dots == 0, !exponent, groupDigits == -1 || groupDigits == 3 else { return nil }
                dots += 1; groupDigits = -1
                clean.append(b)
            } else if (b == UInt8(ascii: "e") || b == UInt8(ascii: "E")), digits > 0, !exponent {
                exponent = true; groupDigits = -1
                clean.append(b)
                if i + 1 < end, bytes[i + 1] == UInt8(ascii: "-") || bytes[i + 1] == UInt8(ascii: "+") { clean.append(bytes[i + 1]); i += 1 }
                guard i + 1 < end else { return nil }
            } else if (b == UInt8(ascii: "_") || b == UInt8(ascii: "'")), digits > 0, !exponent {
                i += 1
                continue
            } else {
                return nil
            }
            i += 1
        }
        guard digits > 0, groupDigits == -1 || groupDigits == 3 else { return nil }
        integer?.pointee = dots == 0 && !exponent
        clean.append(0)
        let value = clean.withUnsafeBufferPointer { strtod(UnsafeRawPointer($0.baseAddress!).assumingMemoryBound(to: CChar.self), nil) }
        return value.isFinite ? value : nil
    }

    /// A date (and optional time) as seconds since 1970: ISO 8601, 2024/03/15, 03/15/2024, 15.03.2024.
    static func date(_ text: String) -> Double? {
        date(text, hasTime: nil)
    }

    static func date(_ text: String, hasTime: UnsafeMutablePointer<Bool>?) -> Double? {
        let b = Array(text.utf8)
        var n = b.count
        while n > 0, b[n - 1] == 0x20 { n -= 1 }
        var s = 0
        while s < n, b[s] == 0x20 { s += 1 }
        guard n - s >= 8, n - s <= 40, b[s] >= 48, b[s] <= 57 else { return nil }
        func num(_ from: Int, _ count: Int) -> Int? {
            guard from + count <= n else { return nil }
            var value = 0
            for k in from..<(from + count) {
                let c = b[k]
                guard c >= 48 && c <= 57 else { return nil }
                value = value * 10 + Int(c - 48)
            }
            return value
        }
        /// Reads 1–2 digits; returns value and length.
        func short(_ from: Int) -> (Int, Int)? {
            guard let first = num(from, 1) else { return nil }
            if let two = num(from, 2) { return (two, 2) }
            return (first, 1)
        }
        var year = 0, month = 0, day = 0
        var i = s
        if let y = num(s, 4), s + 4 < n, b[s + 4] == UInt8(ascii: "-") || b[s + 4] == UInt8(ascii: "/") {
            let sep = b[s + 4]
            guard let (m, ml) = short(s + 5), s + 5 + ml < n, b[s + 5 + ml] == sep, let (d, dl) = short(s + 6 + ml) else { return nil }
            year = y; month = m; day = d
            i = s + 6 + ml + dl
        } else if let (a, al) = short(s), s + al < n, b[s + al] == UInt8(ascii: "/") || b[s + al] == UInt8(ascii: ".") {
            let sep = b[s + al]
            guard let (c, cl) = short(s + al + 1), s + al + 1 + cl < n, b[s + al + 1 + cl] == sep,
                  let y = num(s + al + cl + 2, 4) else { return nil }
            year = y
            if sep == UInt8(ascii: ".") || a > 12 { day = a; month = c } else { month = a; day = c }
            i = s + al + cl + 6
        } else {
            return nil
        }
        guard year >= 1000, year <= 9999, month >= 1, month <= 12, day >= 1, day <= 31 else { return nil }
        var seconds = Double(daysFromCivil(year, month, day)) * 86_400
        var timed = false
        if i < n {
            guard b[i] == UInt8(ascii: "T") || b[i] == UInt8(ascii: " ") else { return nil }
            guard let h = num(i + 1, 2), i + 3 < n, b[i + 3] == UInt8(ascii: ":"), let m = num(i + 4, 2), h < 24, m < 60 else { return nil }
            seconds += Double(h * 3600 + m * 60)
            timed = true
            i += 6
            if i < n, b[i] == UInt8(ascii: ":"), let sec = num(i + 1, 2), sec <= 60 {
                seconds += Double(sec)
                i += 3
                if i < n, b[i] == UInt8(ascii: ".") || b[i] == UInt8(ascii: ",") {
                    i += 1
                    while i < n, b[i] >= 48, b[i] <= 57 { i += 1 }
                }
            }
            if i < n {
                if b[i] == UInt8(ascii: "Z") || b[i] == UInt8(ascii: "z") { i += 1 }
                else if b[i] == UInt8(ascii: "+") || b[i] == UInt8(ascii: "-") {
                    let sign: Double = b[i] == UInt8(ascii: "-") ? -1 : 1
                    guard let oh = num(i + 1, 2) else { return nil }
                    var j = i + 3
                    if j < n, b[j] == UInt8(ascii: ":") { j += 1 }
                    let om = num(j, 2) ?? 0
                    if num(j, 2) != nil { j += 2 }
                    seconds -= sign * Double(oh * 3600 + om * 60)
                    i = j
                } else if b[i] == UInt8(ascii: " ") {
                    // "UTC", "GMT" and similar trailing zone names are fine.
                    i = n
                }
            }
            guard i >= n else { return nil }
        }
        hasTime?.pointee = timed
        return seconds
    }

    /// Days since 1970-01-01 in the proleptic Gregorian calendar (Howard Hinnant's algorithm).
    static func daysFromCivil(_ year: Int, _ month: Int, _ day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    static func isBoolean(_ text: String) -> Bool? {
        switch text.lowercased() {
        case "true", "yes", "y", "t": return true
        case "false", "no", "n", "f": return false
        default: return nil
        }
    }
}

/// What a column holds: its inferred type, emptiness, spread and most common values.
struct ColumnProfile {
    enum Kind: Equatable {
        case empty, boolean, integer, number, date, text

        var title: String {
            switch self {
            case .empty: return "Empty"
            case .boolean: return "Boolean"
            case .integer: return "Integer"
            case .number: return "Number"
            case .date: return "Date"
            case .text: return "Text"
            }
        }
    }

    var kind: Kind = .empty
    /// Rows examined, and rows in the table (more when a large table was sampled).
    var examined = 0
    var totalRows = 0
    var empty = 0
    var distinct = 0
    var distinctCapped = false
    var top: [(value: String, count: Int)] = []
    var minimum: Double?
    var maximum: Double?
    var mean: Double?
    var median: Double?
    var hasTime = false
    var histogram: [Int] = []
    var trueCount = 0
    var shortest = 0
    var longest = 0

    var filled: Int { examined - empty }
    var sampled: Bool { examined < totalRows }
    var isUnique: Bool { kind == .text && filled > 1 && distinct == filled && !distinctCapped }

    static let maxDistinct = 100_000
    static let bins = 24

    /// Profiles one column, reading at most `limit` rows spread evenly through the table.
    static func make(rows: Int, limit: Int = 200_000, text: (Int) -> String) -> ColumnProfile {
        var profile = ColumnProfile()
        profile.totalRows = rows
        let stride = rows > limit ? Double(rows) / Double(limit) : 1
        let count = min(rows, limit)
        var counts: [String: Int] = [:]
        var numbers: [Double] = []
        var integers = 0
        var dates: [Double] = []
        var timed = 0
        var booleans = 0, trues = 0
        var shortest = Int.max, longest = 0
        numbers.reserveCapacity(min(count, 4096))

        for k in 0..<count {
            let row = stride == 1 ? k : min(rows - 1, Int(Double(k) * stride))
            let raw = text(row)
            profile.examined += 1
            let value = raw.utf8.count > 512 ? String(raw.prefix(512)) : raw
            if DataValueParser.isEmpty(value) { profile.empty += 1; continue }
            let length = value.count
            shortest = min(shortest, length)
            longest = max(longest, length)
            if counts.count < maxDistinct || counts[value] != nil { counts[value, default: 0] += 1 } else { profile.distinctCapped = true }
            if let flag = DataValueParser.isBoolean(value) { booleans += 1; if flag { trues += 1 } }
            var isInteger = false
            if let number = DataValueParser.number(value, integer: &isInteger) {
                numbers.append(number)
                if isInteger { integers += 1 }
            } else if value.utf8.count >= 8, let first = value.utf8.first, first >= 48 && first <= 57 {
                var hasTime = false
                if let date = DataValueParser.date(value, hasTime: &hasTime) {
                    dates.append(date)
                    if hasTime { timed += 1 }
                }
            }
        }

        let filled = profile.filled
        profile.distinct = counts.count
        profile.top = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(5).map { ($0.key, $0.value) }
        profile.shortest = shortest == .max ? 0 : shortest
        profile.longest = longest
        guard filled > 0 else { profile.kind = .empty; return profile }

        let threshold = Double(filled) * 0.97
        if booleans == filled {
            profile.kind = .boolean
            profile.trueCount = trues
        } else if Double(dates.count) >= threshold && !dates.isEmpty {
            profile.kind = .date
            profile.hasTime = timed > 0
            profile.fillNumbers(dates)
        } else if Double(numbers.count) >= threshold && !numbers.isEmpty {
            profile.kind = integers == numbers.count ? .integer : .number
            profile.fillNumbers(numbers)
        } else {
            profile.kind = .text
        }
        return profile
    }

    private mutating func fillNumbers(_ values: [Double]) {
        guard !values.isEmpty else { return }
        var sorted = values
        sorted.sort()
        minimum = sorted.first
        maximum = sorted.last
        median = sorted.count % 2 == 1 ? sorted[sorted.count / 2] : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
        var sum = 0.0
        for value in sorted { sum += value }
        mean = sum / Double(sorted.count)
        var bins = [Int](repeating: 0, count: Self.bins)
        let low = sorted.first!, high = sorted.last!
        if high > low {
            let scale = Double(Self.bins) / (high - low)
            for value in sorted { bins[min(Self.bins - 1, Int((value - low) * scale))] += 1 }
        } else {
            bins[Self.bins / 2] = sorted.count
        }
        histogram = bins
    }

    // MARK: - Presentation

    /// The header strip: kind, one key fact, and a histogram or a share bar.
    var strip: GridHeaderStrip {
        let emptyShare = examined > 0 ? Double(empty) / Double(examined) : 0
        var detail: String?
        var warning = false
        if kind != .empty && empty > 0 && emptyShare >= 0.005 {
            detail = "\(Self.percent(emptyShare)) empty"
            warning = true
        } else {
            switch kind {
            case .text: detail = isUnique ? "all unique" : "\(Self.count(distinct, capped: distinctCapped)) distinct"
            case .boolean: detail = "\(Self.percent(Double(trueCount) / Double(max(filled, 1)))) true"
            case .integer, .number:
                if let minimum, let maximum { detail = minimum == maximum ? Self.short(minimum) : "\(Self.short(minimum))–\(Self.short(maximum))" }
            case .date:
                if let minimum, let maximum {
                    let a = Self.year(minimum), b = Self.year(maximum)
                    detail = a == b ? String(a) : "\(a)–\(b)"
                }
            case .empty: detail = nil
            }
        }
        let kindTitle = isUnique ? "Unique" : kind.title
        var bars: [CGFloat] = []
        var segments: [CGFloat] = []
        switch kind {
        case .integer, .number, .date:
            let peak = CGFloat(histogram.max() ?? 0)
            if peak > 0 { bars = histogram.map { CGFloat($0) / peak } }
        case .boolean:
            if filled > 0 { segments = [CGFloat(trueCount) / CGFloat(filled), CGFloat(filled - trueCount) / CGFloat(filled)] }
        case .text:
            if filled > 0, !isUnique { segments = top.map { CGFloat($0.count) / CGFloat(filled) } }
        case .empty:
            break
        }
        return .profile(kind: kindTitle, detail: detail, bars: bars, segments: segments, warning: warning)
    }

    static func percent(_ share: Double) -> String {
        if share > 0 && share < 0.01 { return "<1%" }
        if share < 1 && share > 0.99 { return ">99%" }
        return "\(Int((share * 100).rounded()))%"
    }

    static func count(_ value: Int, capped: Bool) -> String {
        capped ? "\(short(Double(value)))+" : short(Double(value), integerBelow: 10_000)
    }

    /// 1.2K, 3.4M, 12.5 — compact numbers for tight spaces.
    static func short(_ value: Double, integerBelow: Double = 1_000) -> String {
        let magnitude = abs(value)
        if magnitude >= 1e9 { return trim(value / 1e9) + "B" }
        if magnitude >= 1e6 { return trim(value / 1e6) + "M" }
        if magnitude >= integerBelow && magnitude >= 1e3 { return trim(value / 1e3) + "K" }
        if value == value.rounded() { return Int(value).formatted() }
        if magnitude >= 100 { return String(format: "%.0f", value) }
        if magnitude >= 1 { return trim(value) }
        return String(format: "%.3g", value)
    }

    private static func trim(_ value: Double) -> String {
        let text = String(format: abs(value) >= 100 ? "%.0f" : "%.1f", value)
        return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
    }

    static func year(_ seconds: Double) -> Int {
        Calendar(identifier: .gregorian).component(.year, from: Date(timeIntervalSince1970: seconds))
    }

    /// A full number for the profile popover.
    static func full(_ value: Double) -> String {
        if value == value.rounded() && abs(value) < 1e15 { return Int(value).formatted() }
        return value.formatted(.number.precision(.significantDigits(1...8)))
    }

    /// At most two decimals, for averages.
    static func rounded(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...2)))
    }

    static func dateText(_ seconds: Double, time: Bool) -> String {
        let date = Date(timeIntervalSince1970: seconds)
        var style = Date.FormatStyle(date: .abbreviated, time: time ? .shortened : .omitted)
        style.timeZone = TimeZone(secondsFromGMT: 0)!
        return date.formatted(style)
    }
}
