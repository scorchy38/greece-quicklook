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
        "com.scorchy.greece.quicklook": ("Source code, JSON, property lists, patches and logs", "chevron.left.forwardslash.chevron.right"),
        "com.scorchy.greece.quicklook.documents": ("Markdown, notebooks, LaTeX, EPUB, Org and more", "doc.richtext"),
        "com.scorchy.greece.quicklook.data": ("TSV, SQLite, HAR, lock files, Parquet and more", "tablecells"),
        "com.scorchy.greece.quicklook.archives": ("ZIP, 7z, RAR, tar, comics, packages and folders", "archivebox"),
        "com.scorchy.greece.quicklook.apps": ("Apps, installers, disk images, profiles and binaries", "app.badge"),
        "com.scorchy.greece.quicklook.models": ("glTF, FBX, STL, OBJ, 3MF and point clouds", "cube"),
        "com.scorchy.greece.quicklook.maps": ("GeoJSON, KML, GPX, shapefiles and map tiles", "map"),
        "com.scorchy.greece.quicklook.media": ("Fonts, subtitles, SVG, Lottie and colour palettes", "textformat"),
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
