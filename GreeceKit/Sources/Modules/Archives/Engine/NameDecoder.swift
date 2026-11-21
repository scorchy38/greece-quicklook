import Foundation

/// Decodes file names stored in legacy code pages (old ZIPs, LHA, cpio, tar from Windows or DOS).
///
/// Every name in an archive usually shares one encoding, so all undecodable names are judged
/// together: each candidate decodes them, and the result that reads most like real names in one
/// script wins. Box-drawing characters and stray symbols (what CP437 makes of Shift JIS) lose.
enum NameDecoder {
    struct Candidate {
        let name: String
        let encoding: String.Encoding
        let script: Script
    }

    enum Script { case latin, cyrillic, greek, japanese, chinese, korean }

    private static func cf(_ encoding: CFStringEncodings) -> String.Encoding {
        String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(encoding.rawValue)))
    }

    static let candidates: [Candidate] = [
        Candidate(name: "DOS Latin US", encoding: cf(.dosLatinUS), script: .latin),
        Candidate(name: "Shift JIS", encoding: cf(.dosJapanese), script: .japanese),
        Candidate(name: "GBK", encoding: cf(.GB_18030_2000), script: .chinese),
        Candidate(name: "Big5", encoding: cf(.big5_HKSCS_1999), script: .chinese),
        Candidate(name: "EUC-KR", encoding: cf(.dosKorean), script: .korean),
        Candidate(name: "EUC-JP", encoding: .japaneseEUC, script: .japanese),
        Candidate(name: "DOS Cyrillic", encoding: cf(.dosRussian), script: .cyrillic),
        Candidate(name: "Windows Cyrillic", encoding: .windowsCP1251, script: .cyrillic),
        Candidate(name: "KOI8-R", encoding: cf(.KOI8_R), script: .cyrillic),
        Candidate(name: "DOS Greek", encoding: cf(.dosGreek), script: .greek),
        Candidate(name: "Windows Greek", encoding: .windowsCP1253, script: .greek),
        Candidate(name: "Windows Latin 1", encoding: .windowsCP1252, script: .latin),
    ]

    /// Picks the encoding that makes the most sense of these names. `fallback` is the format's
    /// documented default (CP437 for ZIP).
    static func choose(_ names: [[UInt8]], fallback: String.Encoding? = nil) -> Candidate {
        let sample = Array(names.prefix(400))
        let preferred = preferredScripts()
        var best: (Candidate, Double)?
        for candidate in candidates {
            var score = 0.0
            var valid = true
            for bytes in sample {
                guard let text = String(bytes: bytes, encoding: candidate.encoding) else { valid = false; break }
                score += plausibility(text, script: candidate.script)
            }
            guard valid else { continue }
            if candidate.name == "GBK" || candidate.name == "EUC-KR" {
                // Real GB2312 and KS X 1001 text pairs two high bytes; Latin text misread as GBK
                // pairs an accented byte with the ASCII letter after it.
                for bytes in sample { score -= 1.5 * Double(asciiTrailPairs(bytes)) }
            }
            if preferred.contains(candidate.script) { score += 0.5 + abs(score) * 0.05 }
            if candidate.encoding == fallback { score += 0.25 }
            if best == nil || score > best!.1 { best = (candidate, score) }
        }
        return best?.0 ?? candidates[0]
    }

    private static func asciiTrailPairs(_ bytes: [UInt8]) -> Int {
        var count = 0
        var index = 0
        while index < bytes.count {
            if bytes[index] >= 0x81, index + 1 < bytes.count {
                if (0x40...0x7E).contains(bytes[index + 1]) { count += 1 }
                index += 2
            } else {
                index += 1
            }
        }
        return count
    }

    static func decode(_ bytes: [UInt8], with candidate: Candidate) -> String {
        String(bytes: bytes, encoding: candidate.encoding) ?? String(decoding: bytes, as: UTF8.self)
    }

    /// The Cyrillic letters that make up most Russian text, and the rarest ones. Misreading KOI8-R as
    /// Windows-1251 (or the reverse) swaps common letters for rare ones, which is how they're told apart.
    private static let commonCyrillic = Set("оеаинтсрвлкмдпу".unicodeScalars.map(\.value))
    private static let rareCyrillic = Set("фщэъёшжцчхйю".unicodeScalars.map(\.value))

    /// How much a decoded name looks like something a person typed in `script`.
    static func plausibility(_ text: String, script: Script) -> Double {
        var score = 0.0
        // Words are judged whole: "Cafй" (Latin with one Cyrillic letter) is a misreading, not a name.
        var word = 0.0
        var wordHasASCII = false
        var wordHasForeign = false
        var previousUpper: Bool?
        let alphabetic = script == .cyrillic || script == .greek

        func endWord() {
            if alphabetic && wordHasASCII && wordHasForeign { score -= 3 } else { score += word }
            word = 0
            wordHasASCII = false
            wordHasForeign = false
            previousUpper = nil
        }

        for scalar in text.unicodeScalars {
            let value = scalar.value
            let isLetter = CharacterSet.letters.contains(scalar)
            if value < 0x80 {
                if isLetter { wordHasASCII = true } else { endWord() }
                continue
            }
            if !isLetter { endWord() }
            switch value {
            case 0x2500...0x259F, 0x2320...0x2321, 0x2219...0x221A, 0x2248, 0x2261...0x2265, 0x207F, 0x00A0...0x00BF, 0x00D7, 0x00F7:
                score -= 3                                   // box drawing, math and Latin-1 symbols
            case 0x0080...0x009F, 0xE000...0xF8FF, 0xFFFD:
                score -= 6                                   // control and private-use characters
            case 0x00C0...0x024F:
                word += script == .latin ? 1 : -0.5          // accented Latin
            case 0x0370...0x03FF:
                word += script == .greek ? 2 : -2            // CP437 maps bytes to α ß Γ π…
                if script == .greek { wordHasForeign = true }
            case 0x0400...0x04FF:
                guard script == .cyrillic else { word -= 1; break }
                wordHasForeign = true
                let lower = Character(scalar).lowercased().unicodeScalars.first?.value ?? value
                word += commonCyrillic.contains(lower) ? 2 : rareCyrillic.contains(lower) ? 0 : 1
                // Real words are lower case, Capitalised or ALL CAPS, never lower then upper.
                let upper = lower != value
                if previousUpper == false && upper { word -= 1.5 }
                previousUpper = upper
                continue
            case 0x3040...0x30FF:
                word += script == .japanese ? 3 : -1         // kana
            case 0x4E00...0x9FFF:
                word += [.japanese, .chinese].contains(script) ? 2 : -1
            case 0xAC00...0xD7AF:
                word += script == .korean ? 2.5 : -1         // Hangul syllables
            case 0xFF61...0xFF9F:
                score -= 1                                   // half-width katakana: rare in real names
            case 0x3000...0x303F, 0xFF01...0xFF60:
                score += [.japanese, .chinese, .korean].contains(script) ? 0.5 : -1
            default:
                score -= 0.5
            }
            previousUpper = nil
        }
        endWord()
        return score
    }

    private static func preferredScripts() -> Set<Script> {
        var scripts = Set<Script>()
        for language in Locale.preferredLanguages.prefix(3) {
            let code = language.prefix(2)
            switch code {
            case "ja": scripts.insert(.japanese)
            case "zh": scripts.insert(.chinese)
            case "ko": scripts.insert(.korean)
            case "ru", "uk", "be", "bg", "sr", "mk", "kk": scripts.insert(.cyrillic)
            case "el": scripts.insert(.greek)
            default: break
            }
        }
        return scripts
    }
}
