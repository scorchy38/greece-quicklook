import Cocoa
import Quartz
import WebKit

/// Main Quick Look extension entry point.
/// Routes each file URL to the appropriate renderer based on detected file type.
class PreviewViewController: NSViewController, QLPreviewingController {

    // MARK: - Child renderers (lazy)
    private lazy var markdownRenderer = MarkdownRenderer()
    private lazy var sourceCodeRenderer = SourceCodeRenderer()
    private lazy var csvRenderer = CSVRenderer()
    private lazy var sqliteRenderer = SQLiteRenderer()
    private lazy var diffRenderer = DiffRenderer()
    private lazy var archiveRenderer = ArchiveRenderer()
    private lazy var folderRenderer = FolderRenderer()

    // MARK: - Metadata bar
    private lazy var metadataBar = MetadataBarView()
    private var metadataBarHeight: NSLayoutConstraint?

    // MARK: - State
    private var currentFileURL: URL?

    // MARK: - Lifecycle

    override func loadView() {
        self.view = NSView()
        self.view.wantsLayer = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupMetadataBar()
    }

    // MARK: - QLPreviewingController

    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        currentFileURL = url
        let category = FileTypeDetector.detect(url: url)

        // Update metadata bar
        if GreeceSettings.shared.showMetadataBar {
            metadataBar.configure(with: url, category: category)
            metadataBarHeight?.constant = 28
        } else {
            metadataBarHeight?.constant = 0
        }

        // Route to appropriate renderer
        switch category {
        case .markdown, .textBundle:
            embedRenderer(markdownRenderer, for: url, completion: handler)

        case .sourceCode:
            embedRenderer(sourceCodeRenderer, for: url, completion: handler)

        case .csv:
            embedRenderer(csvRenderer, for: url, completion: handler)

        case .sqlite:
            embedRenderer(sqliteRenderer, for: url, completion: handler)

        case .diff:
            embedRenderer(diffRenderer, for: url, completion: handler)

        case .archive:
            embedRenderer(archiveRenderer, for: url, completion: handler)

        case .folder:
            embedRenderer(folderRenderer, for: url, completion: handler)

        case .unknown:
            // Try source code as fallback for text-like files
            embedRenderer(sourceCodeRenderer, for: url, completion: handler)
        }
    }

    // MARK: - Renderer Embedding

    private func embedRenderer(_ renderer: FileRenderer, for url: URL, completion: @escaping (Error?) -> Void) {
        // Remove any existing content views (but keep metadata bar)
        for subview in view.subviews where subview !== metadataBar {
            subview.removeFromSuperview()
        }

        let contentView = renderer.render(fileAt: url) { error in
            completion(error)
        }

        contentView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(contentView, positioned: .below, relativeTo: metadataBar)

        NSLayoutConstraint.activate([
            contentView.topAnchor.constraint(equalTo: view.topAnchor),
            contentView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: metadataBar.topAnchor),
        ])
    }

    // MARK: - Metadata Bar Setup

    private func setupMetadataBar() {
        metadataBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(metadataBar)

        let heightConstraint = metadataBar.heightAnchor.constraint(equalToConstant: 28)
        self.metadataBarHeight = heightConstraint

        NSLayoutConstraint.activate([
            metadataBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            metadataBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            metadataBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            heightConstraint,
        ])
    }
}

// MARK: - File Renderer Protocol

/// Protocol all renderers implement to provide a preview view.
protocol FileRenderer {
    /// Create and return a view that renders the file at the given URL.
    /// Call the completion handler when rendering is finished (or on error).
    func render(fileAt url: URL, completion: @escaping (Error?) -> Void) -> NSView
}
