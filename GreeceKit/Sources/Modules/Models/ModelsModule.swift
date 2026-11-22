import AppKit

/// 3D models and point clouds: glTF/GLB, FBX, 3MF, COLLADA, OBJ, STL, PLY, OFF, 3DS, VRML, AMF,
/// MagicaVoxel, LAS, LAZ and PCD. Previews render with three.js; Finder thumbnails render natively
/// with SceneKit.
enum ModelsModule: PreviewModule {
    static let id = "models"

    /// Larger meshes are not handed to the web view at all.
    static let pageFileLimit = 1024 * 1024 * 1024
    /// Points the page draws at most (LAS is sampled in Swift, LAZ in the page's decoder).
    static let pointBudget = 3_000_000

    static func claims(_ file: FileInfo) -> Bool {
        ModelFormat.detect(file) != nil
    }

    /// What the page script receives.
    struct Page: Encodable {
        var format: String
        var name: String
        var url: String
        var assets: String
        var fileSize: Int
        var zUp: Bool
        var facts: ModelFacts
        var pointBudget: Int
        var las: LASFile.Header?
        var tooLarge: Bool
    }

    static func prepare(_ file: FileInfo, settings: PreviewSettings) throws -> PreparedPreview {
        guard let format = ModelFormat.detect(file) else { throw PreviewError.unsupported }
        let fileSize = file.fileSize ?? 0
        let facts = ModelFacts.read(format, url: file.url)
        let las = format.isPointCloud && format != .pcd ? (try? LASFile(url: file.url)) : nil
        let tooLarge = format != .las && fileSize > pageFileLimit

        let page = Page(format: format.rawValue, name: file.url.lastPathComponent, url: fileURL(file.url),
                        assets: "greece://asset/vendor/", fileSize: fileSize, zUp: format.isZUp && format != .vox, facts: facts,
                        pointBudget: pointBudget, las: las?.header, tooLarge: tooLarge)
        var scripts = ["vendor/three/three.min.js"]
        if let loader = format.loaderScript { scripts.append("vendor/three/three-\(loader).min.js") }
        scripts.append("modules/models.js")
        var document = WebDocument(module: .init("models"), data: page, scripts: scripts, styles: ["modules/models.css"])
        document.readableDirectory = file.url.deletingLastPathComponent()
        document.allowsWasm = format.needsWasm
        if format == .las, let las {
            let url = file.url
            document.resources = { path in
                guard path.hasPrefix("points") else { return nil }
                let sample = las.sample(url: url, budget: pointBudget, deadline: Date().addingTimeInterval(8))
                return (sample.encoded(), "application/octet-stream")
            }
        }

        var details = facts.details(format: format)
        if let size = file.sizeText { details.append(size) }
        let summary = FileSummary(symbol: format.symbol, title: format.title, details: details, trailing: file.modifiedText)
        return .web(document, summary, NSSize(width: 960, height: 720))
    }

    /// A studio render of the model at a three-quarter view (macOS has none for most of these formats).
    static func thumbnail(_ file: FileInfo, size: CGSize, settings: PreviewSettings) -> ThumbnailPage? {
        guard let format = ModelFormat.detect(file) else { return nil }
        return ModelThumbnails.page(file, format: format, size: size)
    }

    /// `greece://file/<percent-encoded absolute path>`, the scheme the page may read from.
    static func fileURL(_ url: URL) -> String {
        var components = URLComponents()
        components.scheme = GreeceSchemeHandler.scheme
        components.host = "file"
        components.path = url.standardizedFileURL.path
        return components.url?.absoluteString ?? ""
    }
}
