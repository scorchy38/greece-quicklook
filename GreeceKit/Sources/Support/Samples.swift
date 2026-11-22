import Foundation

/// Example files bundled with Greece, used for onboarding and live settings previews.
public enum Samples {
    public static var folder: URL { WebAssets.bundle.resourceURL!.appendingPathComponent("Samples", isDirectory: true) }

    public static func url(_ name: String) -> URL { folder.appendingPathComponent(name) }

    public static let markdown = url("Welcome.md")
    public static let swift = url("Lighthouse.swift")
    public static let python = url("ferries.py")
    public static let json = url("harbor.json")
    public static let csv = url("Islands.csv")
    public static let sqlite = url("Islands.sqlite")
    public static let patch = url("Timetable.patch")
    public static let notebook = url("Voyage.ipynb")
    public static let zip = url("Atlas.zip")
    public static let map = url("Cyclades Ferries.geojson")
    public static let model = url("Mykonos Windmill.fbx")
    public static let book = url("Aesop's Fables.epub")
    public static let animation = url("Lighthouse.json")
    public static let comic = url("Aegean Tales.cbz")
    public static let skill = url("Harbour Forms.skill")

    /// Third-party licenses for the bundled web libraries.
    public static var licenses: [(name: String, text: String)] {
        let directory = WebAssets.bundle.resourceURL!.appendingPathComponent("Licenses")
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.sorted { $0.deletingPathExtension().lastPathComponent.lowercased() < $1.deletingPathExtension().lastPathComponent.lowercased() }.compactMap { file in
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
            return (file.deletingPathExtension().lastPathComponent, text)
        }
    }
}
