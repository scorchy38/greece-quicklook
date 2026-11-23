import AppKit

/// Greece's preview families, each its own Quick Look extension, so each can be switched off.
/// Off means macOS shows those files itself, as if Greece weren't installed.
@MainActor
final class PreviewKinds: ObservableObject {
    struct Kind: Identifiable {
        let id: String          // extension bundle identifier
        let name: String
        let detail: String
        let symbol: String
        var isOn: Bool
    }

    @Published private(set) var kinds: [Kind] = []
    @Published private(set) var working = false

    private static let descriptions: [String: (detail: String, symbol: String)] = [
        "com.scorchy.greece.quicklook": (String(localized: "Source code, JSON, property lists, patches and logs", comment: "Preview Kinds: what this kind covers"), "chevron.left.forwardslash.chevron.right"),
        "com.scorchy.greece.quicklook.documents": (String(localized: "Markdown, notebooks, LaTeX, EPUB, Org and more", comment: "Preview Kinds: what this kind covers"), "doc.richtext"),
        "com.scorchy.greece.quicklook.data": (String(localized: "TSV, SQLite, HAR, lock files, Parquet and more", comment: "Preview Kinds: what this kind covers"), "tablecells"),
        "com.scorchy.greece.quicklook.archives": (String(localized: "ZIP, 7z, RAR, tar, comics, packages and folders", comment: "Preview Kinds: what this kind covers"), "archivebox"),
        "com.scorchy.greece.quicklook.apps": (String(localized: "Apps, installers, disk images, profiles and binaries", comment: "Preview Kinds: what this kind covers"), "app.badge"),
        "com.scorchy.greece.quicklook.models": (String(localized: "glTF, FBX, STL, OBJ, 3MF and point clouds", comment: "Preview Kinds: what this kind covers"), "cube"),
        "com.scorchy.greece.quicklook.maps": (String(localized: "GeoJSON, KML, GPX, shapefiles and map tiles", comment: "Preview Kinds: what this kind covers"), "map"),
        "com.scorchy.greece.quicklook.media": (String(localized: "Fonts, subtitles, SVG, Lottie and colour palettes", comment: "Preview Kinds: what this kind covers"), "textformat"),
    ]

    func refresh() {
        Task {
            var result: [Kind] = []
            for family in ExtensionStatus.previewFamilies {
                let listing = await ExtensionStatus.run("/usr/bin/pluginkit", ["-m", "-A", "-D", "-v", "-i", family.identifier])
                let flag = listing.split(separator: "\n").first { $0.contains(family.identifier) }?.first
                let info = Self.descriptions[family.identifier] ?? ("", "eye")
                result.append(Kind(id: family.identifier, name: family.name, detail: info.detail, symbol: info.symbol, isOn: flag != "-"))
            }
            kinds = result
        }
    }

    func set(_ id: String, on: Bool) {
        guard let index = kinds.firstIndex(where: { $0.id == id }) else { return }
        kinds[index].isOn = on
        working = true
        Task {
            _ = await ExtensionStatus.run("/usr/bin/pluginkit", ["-e", on ? "use" : "ignore", "-i", id])
            _ = await ExtensionStatus.run("/usr/bin/qlmanage", ["-r"])
            working = false
            refresh()
        }
    }
}
