import AppKit

/// Lottie animations, as JSON or packaged as dotLottie (a ZIP with a manifest, animations and
/// images). Played by lottie-web's light SVG player, which has no expression engine and so never
/// evaluates code from the file.
enum LottiePreview {
    static let jsonLimit = 48 * 1024 * 1024

    /// Lottie JSON announces itself in its first keys: version, frame rate, in and out points.
    static func looksLikeLottie(_ bytes: [UInt8]) -> Bool {
        guard let first = bytes.first(where: { ![0x20, 0x09, 0x0A, 0x0D, 0xEF, 0xBB, 0xBF].contains($0) }), first == UInt8(ascii: "{") else { return false }
        let head = String(decoding: bytes, as: UTF8.self)
        func has(_ key: String) -> Bool { head.range(of: "\"\(key)\"\\s*:", options: .regularExpression) != nil }
        return has("v") && has("fr") && has("ip") && has("op") && (has("layers") || has("assets") || (has("w") && has("h")))
    }

    struct Marker: Encodable { var name: String; var start: Double; var duration: Double }

    struct Animation: Encodable {
        var id: String
        var name: String?
        var width: Double
        var height: Double
        var frameRate: Double
        var inPoint: Double
        var outPoint: Double
        var layers: Int
        var assets: Int
        var images: Int
        var markers: [Marker]
        var version: String?
        var hasExpressions: Bool
        var hasText: Bool
        var is3D: Bool

        var duration: Double { frameRate > 0 ? (outPoint - inPoint) / frameRate : 0 }
    }

    struct Payload: Encodable {
        var packaged: Bool
        var animations: [Animation]
        var generator: String?
        var author: String?
        var themes: Int
        /// For loose JSON: the folder its image files are read from.
        var directory: String?
    }

    /// Reads the facts the page and info bar show. Nil if this isn't a Lottie animation.
    static func describe(_ json: Data, id: String) -> Animation? {
        guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let frameRate = number(root["fr"]), frameRate > 0, frameRate < 1000,
              let inPoint = number(root["ip"]), let outPoint = number(root["op"]), outPoint > inPoint,
              let width = number(root["w"]), let height = number(root["h"]), width > 0, height > 0,
              let layers = root["layers"] as? [Any] else { return nil }
        let assets = root["assets"] as? [[String: Any]] ?? []
        let markers = (root["markers"] as? [[String: Any]] ?? []).prefix(64).compactMap { marker -> Marker? in
            guard let start = number(marker["tm"]) else { return nil }
            let name = (marker["cm"] as? String).map { $0.count > 80 ? String($0.prefix(80)) : $0 }
                ?? String(localized: "Marker", bundle: .greeceKit, comment: "A Lottie animation’s marker (a named point in its timeline) that has no name of its own")
            return Marker(name: name, start: start, duration: number(marker["dr"]) ?? 0)
        }
        let sample = String(decoding: json.prefix(8 * 1024 * 1024), as: UTF8.self)
        return Animation(
            id: id,
            name: (root["nm"] as? String).flatMap { $0.isEmpty ? nil : String($0.prefix(120)) },
            width: width, height: height, frameRate: frameRate, inPoint: inPoint, outPoint: outPoint,
            layers: layers.count,
            assets: assets.count,
            images: assets.filter { $0["p"] is String && $0["layers"] == nil }.count,
            markers: markers,
            version: root["v"] as? String,
            hasExpressions: sample.range(of: #""x"\s*:\s*""#, options: .regularExpression) != nil,
            hasText: sample.contains("\"ty\":5") || sample.contains("\"ty\": 5"),
            is3D: (number(root["ddd"]) ?? 0) != 0)
    }

    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        return double.isFinite ? double : nil
    }

    // MARK: - dotLottie

    struct Package {
        var animations: [(id: String, json: Data)]
        var generator: String?
        var author: String?
        var themes: Int
    }

    private static var noAnimations: String {
        String(localized: "This dotLottie file has no animations Greece can read.", bundle: .greeceKit)
    }

    static func unpack(_ data: Data) throws -> Package {
        guard let zip = ZIPArchive.media(data) else { throw MediaError.unreadable(String(localized: "This dotLottie file is damaged.", bundle: .greeceKit)) }
        var package = Package(animations: [], generator: nil, author: nil, themes: 0)
        var ids: [String] = []
        if let entry = zip.member(named: "manifest.json"), let manifest = try? zip.contents(of: entry, limit: 1024 * 1024),
           let object = try? JSONSerialization.jsonObject(with: manifest) as? [String: Any] {
            ids = (object["animations"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
            package.generator = object["generator"] as? String
            package.author = object["author"] as? String
            package.themes = (object["themes"] as? [Any])?.count ?? 0
        }
        let folders = ["animations/", "a/"]
        if ids.isEmpty {
            ids = zip.members.compactMap { entry in
                guard let folder = folders.first(where: { entry.path.hasPrefix($0) }), entry.path.hasSuffix(".json") else { return nil }
                return String(entry.path.dropFirst(folder.count).dropLast(5))
            }
        }
        var budget = jsonLimit
        for id in ids.prefix(32) where !id.contains("/") && !id.contains("..") {
            guard let entry = folders.lazy.compactMap({ zip.member(named: $0 + id + ".json") }).first,
                  var json = try? zip.contents(of: entry, limit: min(budget, jsonLimit)) else { continue }
            budget -= json.count
            json = embedImages(json, zip: zip, budget: &budget)
            package.animations.append((id, json))
            if budget <= 0 { break }
        }
        guard !package.animations.isEmpty else { throw MediaError.unreadable(noAnimations) }
        return package
    }

    /// Image assets stored beside the animation in the package become data URLs inside it.
    private static func embedImages(_ json: Data, zip: ZIPArchive, budget: inout Int) -> Data {
        guard var root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              var assets = root["assets"] as? [[String: Any]] else { return json }
        var changed = false
        for index in assets.indices {
            guard let name = assets[index]["p"] as? String, !name.hasPrefix("data:"), (assets[index]["e"] as? Int ?? 0) == 0,
                  !name.contains(".."), name.count < 256 else { continue }
            let file = (name as NSString).lastPathComponent
            guard let entry = ["images/" + file, "i/" + file].lazy.compactMap({ zip.member(named: $0) }).first,
                  let bytes = try? zip.contents(of: entry, limit: min(budget, 16 * 1024 * 1024)) else { continue }
            let type: String
            switch (file as NSString).pathExtension.lowercased() {
            case "png": type = "image/png"
            case "jpg", "jpeg": type = "image/jpeg"
            case "webp": type = "image/webp"
            case "gif": type = "image/gif"
            case "svg": continue // never inline markup
            default: continue
            }
            budget -= bytes.count * 4 / 3
            assets[index]["p"] = "data:\(type);base64," + bytes.base64EncodedString()
            assets[index]["u"] = ""
            assets[index]["e"] = 1
            changed = true
        }
        guard changed else { return json }
        root["assets"] = assets
        return (try? JSONSerialization.data(withJSONObject: root)) ?? json
    }

    // MARK: - Preview

    static func load(_ file: FileInfo, packaged: Bool) throws -> (Payload, [Data]) {
        if packaged {
            let package = try unpack(try file.mediaData(limit: 64 * 1024 * 1024))
            let described = package.animations.compactMap { item in describe(item.json, id: item.id).map { ($0, item.json) } }
            guard !described.isEmpty else { throw MediaError.unreadable(noAnimations) }
            return (Payload(packaged: true, animations: described.map(\.0), generator: package.generator, author: package.author, themes: package.themes),
                    described.map(\.1))
        }
        let json = try file.mediaData(limit: jsonLimit)
        guard let animation = describe(json, id: file.url.deletingPathExtension().lastPathComponent) else {
            throw MediaError.unreadable(String(localized: "This JSON file isn’t a Lottie animation Greece can play.", bundle: .greeceKit))
        }
        var generator: String?
        if let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any], let meta = root["meta"] as? [String: Any] {
            generator = meta["g"] as? String
        }
        return (Payload(packaged: false, animations: [animation], generator: generator, author: nil, themes: 0,
                        directory: file.url.deletingLastPathComponent().path), [json])
    }

    static func prepare(_ file: FileInfo, packaged: Bool) throws -> PreparedPreview {
        let (payload, animations) = try load(file, packaged: packaged)
        var document = WebDocument(module: .init("media-lottie"), data: payload,
                                   scripts: ["modules/media.common.js", "vendor/lottie/lottie_light.min.js", "modules/media.lottie.js"],
                                   styles: ["modules/media.css"])
        document.resources = { path in
            guard path.hasPrefix("animation/"), let index = Int(path.dropFirst(10).replacingOccurrences(of: ".json", with: "")),
                  animations.indices.contains(index) else { return nil }
            return (animations[index], "application/json; charset=utf-8")
        }
        // Loose JSON may point at image files next to it.
        if !packaged { document.readableDirectory = file.url.deletingLastPathComponent() }

        let first = payload.animations[0]
        var details: [String] = []
        if payload.animations.count > 1 {
            details.append(String(localized: "\(payload.animations.count) animations", bundle: .greeceKit, comment: "Info bar detail: how many animations a dotLottie file holds"))
        }
        details.append("\(SVGPreview.format(first.width)) × \(SVGPreview.format(first.height))")
        let frameRate = first.frameRate.formatted(.number.precision(.fractionLength(0...2)))
        details.append(String(localized: "\(frameRate) fps", bundle: .greeceKit, comment: "Info bar detail: an animation’s frame rate, such as “30 fps” (frames per second)"))
        details.append(MediaText.seconds(first.duration))
        details.append(String(localized: "\(first.layers) layers", bundle: .greeceKit, comment: "Info bar detail: how many layers an animation has"))
        if let size = file.sizeText { details.append(size) }
        let title = packaged
            ? String(localized: "dotLottie Animation", bundle: .greeceKit, comment: "Info bar title. dotLottie is a file format")
            : String(localized: "Lottie Animation", bundle: .greeceKit, comment: "Info bar title. Lottie is a file format")
        let summary = FileSummary(symbol: "wand.and.rays", title: title, details: details, trailing: file.modifiedText)
        return .web(document, summary, NSSize(width: 900, height: 760))
    }
}
