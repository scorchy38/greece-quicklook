import Foundation

/// Unicode blocks, for grouping a font's characters and naming the scripts it covers.
enum FontScripts {
    struct Block { let start: Int; let end: Int; let name: String; let script: String? }

    static let blocks: [Block] = {
        // start end script|- name
        let table = """
        0000 007F Latin Basic Latin
        0080 00FF Latin Latin-1 Supplement
        0100 017F Latin Latin Extended-A
        0180 024F Latin Latin Extended-B
        0250 02AF - IPA Extensions
        02B0 02FF - Spacing Modifier Letters
        0300 036F - Combining Diacritical Marks
        0370 03FF Greek Greek and Coptic
        0400 04FF Cyrillic Cyrillic
        0500 052F Cyrillic Cyrillic Supplement
        0530 058F Armenian Armenian
        0590 05FF Hebrew Hebrew
        0600 06FF Arabic Arabic
        0700 074F Syriac Syriac
        0750 077F Arabic Arabic Supplement
        0780 07BF Thaana Thaana
        07C0 07FF NKo NKo
        08A0 08FF Arabic Arabic Extended-A
        0900 097F Devanagari Devanagari
        0980 09FF Bengali Bengali
        0A00 0A7F Gurmukhi Gurmukhi
        0A80 0AFF Gujarati Gujarati
        0B00 0B7F Odia Oriya
        0B80 0BFF Tamil Tamil
        0C00 0C7F Telugu Telugu
        0C80 0CFF Kannada Kannada
        0D00 0D7F Malayalam Malayalam
        0D80 0DFF Sinhala Sinhala
        0E00 0E7F Thai Thai
        0E80 0EFF Lao Lao
        0F00 0FFF Tibetan Tibetan
        1000 109F Myanmar Myanmar
        10A0 10FF Georgian Georgian
        1100 11FF Hangul Hangul Jamo
        1200 137F Ethiopic Ethiopic
        13A0 13FF Cherokee Cherokee
        1400 167F Canadian-Syllabics Unified Canadian Aboriginal Syllabics
        1680 169F Ogham Ogham
        16A0 16FF Runic Runic
        1780 17FF Khmer Khmer
        1800 18AF Mongolian Mongolian
        1AB0 1AFF - Combining Diacritical Marks Extended
        1C80 1C8F Cyrillic Cyrillic Extended-C
        1D00 1D7F - Phonetic Extensions
        1D80 1DBF - Phonetic Extensions Supplement
        1DC0 1DFF - Combining Diacritical Marks Supplement
        1E00 1EFF Latin Latin Extended Additional
        1F00 1FFF Greek Greek Extended
        2000 206F - General Punctuation
        2070 209F - Superscripts and Subscripts
        20A0 20CF - Currency Symbols
        20D0 20FF - Combining Marks for Symbols
        2100 214F - Letterlike Symbols
        2150 218F - Number Forms
        2190 21FF - Arrows
        2200 22FF - Mathematical Operators
        2300 23FF - Miscellaneous Technical
        2400 243F - Control Pictures
        2460 24FF - Enclosed Alphanumerics
        2500 257F - Box Drawing
        2580 259F - Block Elements
        25A0 25FF - Geometric Shapes
        2600 26FF - Miscellaneous Symbols
        2700 27BF - Dingbats
        27C0 27EF - Miscellaneous Mathematical Symbols-A
        27F0 27FF - Supplemental Arrows-A
        2800 28FF - Braille Patterns
        2900 297F - Supplemental Arrows-B
        2980 29FF - Miscellaneous Mathematical Symbols-B
        2A00 2AFF - Supplemental Mathematical Operators
        2B00 2BFF - Miscellaneous Symbols and Arrows
        2C60 2C7F Latin Latin Extended-C
        2D00 2D2F Georgian Georgian Supplement
        2DE0 2DFF Cyrillic Cyrillic Extended-A
        2E00 2E7F - Supplemental Punctuation
        2E80 2EFF Han CJK Radicals Supplement
        2F00 2FDF Han Kangxi Radicals
        3000 303F - CJK Symbols and Punctuation
        3040 309F Kana Hiragana
        30A0 30FF Kana Katakana
        3100 312F Bopomofo Bopomofo
        3130 318F Hangul Hangul Compatibility Jamo
        31F0 31FF Kana Katakana Phonetic Extensions
        3200 32FF - Enclosed CJK Letters and Months
        3300 33FF - CJK Compatibility
        3400 4DBF Han CJK Unified Ideographs Extension A
        4DC0 4DFF - Yijing Hexagram Symbols
        4E00 9FFF Han CJK Unified Ideographs
        A000 A48F Yi Yi Syllables
        A640 A69F Cyrillic Cyrillic Extended-B
        A700 A71F - Modifier Tone Letters
        A720 A7FF Latin Latin Extended-D
        A960 A97F Hangul Hangul Jamo Extended-A
        AB30 AB6F Latin Latin Extended-E
        AC00 D7AF Hangul Hangul Syllables
        E000 F8FF - Private Use Area
        F900 FAFF Han CJK Compatibility Ideographs
        FB00 FB4F - Alphabetic Presentation Forms
        FB50 FDFF Arabic Arabic Presentation Forms-A
        FE00 FE0F - Variation Selectors
        FE10 FE1F - Vertical Forms
        FE20 FE2F - Combining Half Marks
        FE30 FE4F - CJK Compatibility Forms
        FE50 FE6F - Small Form Variants
        FE70 FEFF Arabic Arabic Presentation Forms-B
        FF00 FFEF - Halfwidth and Fullwidth Forms
        FFF0 FFFF - Specials
        1D400 1D7FF - Mathematical Alphanumeric Symbols
        1F000 1F02F - Mahjong Tiles
        1F0A0 1F0FF - Playing Cards
        1F100 1F1FF - Enclosed Alphanumeric Supplement
        1F200 1F2FF - Enclosed Ideographic Supplement
        1F300 1F5FF - Miscellaneous Symbols and Pictographs
        1F600 1F64F - Emoticons
        1F680 1F6FF - Transport and Map Symbols
        1F700 1F77F - Alchemical Symbols
        1F780 1F7FF - Geometric Shapes Extended
        1F800 1F8FF - Supplemental Arrows-C
        1F900 1F9FF - Supplemental Symbols and Pictographs
        1FA70 1FAFF - Symbols and Pictographs Extended-A
        1FB00 1FBFF - Symbols for Legacy Computing
        20000 2A6DF Han CJK Unified Ideographs Extension B
        F0000 FFFFF - Supplementary Private Use Area-A
        100000 10FFFF - Supplementary Private Use Area-B
        """
        return table.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 3).map(String.init)
            guard parts.count == 4, let start = Int(parts[0], radix: 16), let end = Int(parts[1], radix: 16) else { return nil }
            let script = parts[2] == "-" ? nil : parts[2].replacingOccurrences(of: "-", with: " ")
            return Block(start: start, end: end, name: parts[3], script: script)
        }
    }()

    static func block(for codepoint: Int) -> Block? {
        var low = 0, high = blocks.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let block = blocks[mid]
            if codepoint < block.start { high = mid - 1 }
            else if codepoint > block.end { low = mid + 1 }
            else { return block }
        }
        return nil
    }

    /// Characters grouped by Unicode block, in code point order. Blocks go by their names in the
    /// Unicode standard, which stay in English as Unicode names them.
    static func group(_ codepoints: [Int]) -> [(String, [Int])] {
        var result: [(String, [Int])] = []
        let other = String(localized: "Other Characters", bundle: .greeceKit, comment: "Heading in a font’s character grid: characters outside the Unicode blocks Greece names")
        for codepoint in codepoints {
            let name = block(for: codepoint)?.name ?? other
            if result.last?.0 == name { result[result.count - 1].1.append(codepoint) } else { result.append((name, [codepoint])) }
        }
        // "Other Characters" can be split by gaps between known blocks: merge each name once.
        var merged: [(String, [Int])] = []
        var index: [String: Int] = [:]
        for (name, members) in result {
            if let at = index[name] { merged[at].1 += members } else { index[name] = merged.count; merged.append((name, members)) }
        }
        return merged
    }

    /// Writing systems with real coverage (not a stray character or two), the best covered first,
    /// with Latin first whenever the basic alphabet is there.
    static func scripts(in codepoints: [Int]) -> [String] {
        var counts: [String: Int] = [:]
        for codepoint in codepoints {
            if let script = block(for: codepoint)?.script { counts[script, default: 0] += 1 }
        }
        let latinLetters = codepoints.filter { (0x41...0x5A).contains($0) || (0x61...0x7A).contains($0) }.count
        if latinLetters < 52 { counts["Latin"] = nil }
        return counts.filter { $0.value >= 20 }
            .sorted { ($0.key == "Latin" ? Int.max : $0.value, $1.key) > ($1.key == "Latin" ? Int.max : $1.value, $0.key) }
            .map(\.key)
    }
}
