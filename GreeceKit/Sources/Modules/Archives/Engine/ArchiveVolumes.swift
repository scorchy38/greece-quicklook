import Foundation

/// The files that make up one archive: usually just the file itself, or every part of a split set.
struct ArchiveVolumes: Equatable {
    enum Kind: Equatable {
        case single
        /// Byte-for-byte pieces of one file: name.zip.001, name.7z.001, name.001…
        case pieces
        /// A multi-disk ZIP: name.z01, name.z02… name.zip, with offsets per disk.
        case spannedZIP
        /// RAR volumes: name.part1.rar… or name.rar, name.r00, name.r01…
        case rarVolumes
    }

    let kind: Kind
    let urls: [URL]
    /// The name of the whole set ("Atlas.zip" for Atlas.zip.001).
    let displayName: String

    var count: Int { urls.count }
    var first: URL { urls[0] }

    static let maxParts = 999

    /// Finds the rest of a split set from any one of its parts (the one Quick Look was given).
    static func discover(_ url: URL) -> ArchiveVolumes {
        let name = url.lastPathComponent
        let folder = url.deletingLastPathComponent()
        let lower = name.lowercased()
        let single = ArchiveVolumes(kind: .single, urls: [url], displayName: name)

        func existing(_ candidates: String...) -> URL? {
            for candidate in candidates {
                let next = folder.appendingPathComponent(candidate)
                if FileManager.default.fileExists(atPath: next.path) { return next }
            }
            return nil
        }
        func collect(from start: Int, _ name: (Int) -> [String]) -> [URL] {
            var urls: [URL] = []
            var number = start
            while urls.count < maxParts {
                guard let next = name(number).lazy.compactMap({ existing($0) }).first else { break }
                urls.append(next)
                number += 1
            }
            return urls
        }

        // name.ext.001 / name.001: numbered pieces, consecutive from 000 or 001.
        if let match = lower.range(of: #"\.\d{3,4}$"#, options: .regularExpression) {
            let digits = lower.distance(from: match.lowerBound, to: match.upperBound) - 1
            let stem = String(name[..<match.lowerBound])
            let piece = { (number: Int) in [stem + "." + String(format: "%0\(digits)d", number)] }
            let start = existing(piece(0)[0]) != nil ? 0 : 1
            let urls = collect(from: start, piece)
            guard urls.contains(where: { $0.lastPathComponent == name }) else { return single }
            return ArchiveVolumes(kind: .pieces, urls: urls, displayName: stem)
        }

        // name.z01… name.zip: a spanned ZIP, whichever part was selected.
        if lower.hasSuffix(".zip") || lower.range(of: #"\.z\d{2,3}$"#, options: .regularExpression) != nil {
            let stem = (name as NSString).deletingPathExtension
            let parts = collect(from: 1) { [stem + String(format: ".z%02d", $0), stem + String(format: ".Z%02d", $0)] }
            guard !parts.isEmpty, let last = existing(stem + ".zip", stem + ".ZIP") else { return single }
            return ArchiveVolumes(kind: .spannedZIP, urls: parts + [last], displayName: stem + ".zip")
        }

        // name.part1.rar, name.part01.rar…
        if let match = lower.range(of: #"\.part\d{1,4}\.rar$"#, options: .regularExpression) {
            let digits = lower.distance(from: match.lowerBound, to: match.upperBound) - 9
            let stem = String(name[..<match.lowerBound])
            let urls = collect(from: 1) { number in
                let part = stem + ".part" + String(format: "%0\(digits)d", number)
                return [part + ".rar", part + ".RAR"]
            }
            guard urls.count > 1 else { return single }
            return ArchiveVolumes(kind: .rarVolumes, urls: urls, displayName: stem + ".rar")
        }

        // Old style: name.rar, name.r00, name.r01…
        if lower.hasSuffix(".rar") || lower.range(of: #"\.r\d{2}$"#, options: .regularExpression) != nil {
            let stem = (name as NSString).deletingPathExtension
            guard let first = existing(stem + ".rar", stem + ".RAR") else { return single }
            let rest = collect(from: 0) { [stem + String(format: ".r%02d", $0), stem + String(format: ".R%02d", $0)] }
            return rest.isEmpty ? single : ArchiveVolumes(kind: .rarVolumes, urls: [first] + rest, displayName: stem + ".rar")
        }
        return single
    }
}
