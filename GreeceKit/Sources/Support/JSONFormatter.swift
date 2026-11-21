import Foundation

/// Re-indents JSON without parsing it into objects, so key order and number spelling survive.
public enum JSONFormatter {

    /// Squashed onto long lines: one line wider than a window, or any line far too long to read.
    public static func looksMinified(_ text: String) -> Bool {
        let sample = text.utf8.prefix(64 * 1024)
        var newlines = 0, line = 0, longest = 0
        for byte in sample {
            if byte == 0x0A { newlines += 1; longest = max(longest, line); line = 0 } else { line += 1 }
        }
        longest = max(longest, line)
        if newlines <= 1 { return longest > 80 }
        return longest > 400 || sample.count / max(newlines, 1) > 300
    }

    /// `lenient` formats a truncated document (a thumbnail's first kilobytes) instead of refusing it.
    public static func prettyPrinted(_ text: String, indent: Int = 2, lenient: Bool = false) -> String? {
        let input = Array(text.utf8)
        var output: [UInt8] = []
        output.reserveCapacity(input.count + input.count / 2)
        let pad = [UInt8](repeating: 0x20, count: indent)
        var depth = 0
        var inString = false
        var escaped = false
        var index = 0
        let maxDepth = 256
        let outputLimit = input.count * 8 + (1 << 20)

        func newline() {
            output.append(0x0A)
            for _ in 0..<depth { output.append(contentsOf: pad) }
        }

        while index < input.count {
            let byte = input[index]
            if inString {
                output.append(byte)
                if escaped { escaped = false }
                else if byte == 0x5C { escaped = true }
                else if byte == 0x22 { inString = false }
                index += 1
                continue
            }
            switch byte {
            case 0x22: // "
                inString = true
                output.append(byte)
            case 0x7B, 0x5B: // { [
                // Keep empty containers on one line.
                var next = index + 1
                while next < input.count, [0x20, 0x09, 0x0A, 0x0D].contains(input[next]) { next += 1 }
                if next < input.count, input[next] == (byte == 0x7B ? 0x7D : 0x5D) {
                    output.append(byte)
                    output.append(input[next])
                    index = next + 1
                    continue
                }
                output.append(byte)
                depth += 1
                // Real data is never this deep; crafted input would make indentation explode.
                guard depth <= maxDepth else { return nil }
                newline()
            case 0x7D, 0x5D: // } ]
                depth -= 1
                if depth < 0 { if lenient { depth = 0 } else { return nil } }
                newline()
                output.append(byte)
            case 0x2C: // ,
                output.append(byte)
                newline()
            case 0x3A: // :
                output.append(contentsOf: [0x3A, 0x20])
            case 0x20, 0x09, 0x0A, 0x0D:
                break
            default:
                output.append(byte)
            }
            index += 1
            if output.count > outputLimit { return nil }
        }
        guard lenient || (depth == 0 && !inString) else { return nil }
        output.append(0x0A)
        return String(decoding: output, as: UTF8.self)
    }
}
