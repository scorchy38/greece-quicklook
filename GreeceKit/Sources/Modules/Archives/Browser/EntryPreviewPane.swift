import AppKit
import AVKit
import PDFKit
import ImageIO
import UniformTypeIdentifiers

/// The right-hand pane of the archive browser: the selected file's real preview (Greece's own
/// renderers, images, PDFs, media), or its Get Info card.
@MainActor
final class EntryPreviewPane: NSView {
    enum Mode: Int { case preview, info }

    private let source: MemberSource
    private let scratch: ArchiveScratch
    private var settings: PreviewSettings
    private let header = PaneHeader()
    private let content = NSView()
    private var shown: NSView?
    private var node: FileNode?
    private var nodes: [FileNode] = []
    private(set) var mode = Mode.preview
    private var token: CancelToken?
    private var generation = 0
    /// The last preview built, kept while its file stays selected (switching to Info and back).
    private var cached: (node: FileNode, view: NSView, subtitle: String)?
    private var inner: PreviewView?
    /// Called when the person switches between Preview and Info.
    var onModeChange: ((Mode) -> Void)?

    init(source: MemberSource, scratch: ArchiveScratch, settings: PreviewSettings, headerHeight: CGFloat) {
        self.source = source
        self.scratch = scratch
        self.settings = settings
        super.init(frame: .zero)
        header.onModeChange = { [weak self] mode in
            guard let self else { return }
            self.mode = mode
            self.onModeChange?(mode)
            self.refresh()
        }
        for view in [header, content] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: headerHeight),
            content.topAnchor.constraint(equalTo: header.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The same page colour as Greece's documents, so a preview and its pane read as one surface.
    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        dirtyRect.fill()
    }

    func setMode(_ mode: Mode) {
        self.mode = mode
        header.mode = mode
        refresh()
    }

    func show(_ nodes: [FileNode]) {
        self.nodes = nodes
        node = nodes.count == 1 ? nodes[0] : nil
        refresh()
    }

    func apply(_ settings: PreviewSettings) {
        let previous = self.settings
        self.settings = settings
        if let inner, !inner.update(settings: innerSettings, previous: Self.inner(previous)) {
            cached = nil
            refresh()
        }
    }

    private var innerSettings: PreviewSettings { Self.inner(settings) }

    /// Previews inside the pane go without their own info bar: the pane's header says what they are.
    private static func inner(_ settings: PreviewSettings) -> PreviewSettings {
        var copy = settings
        copy.showInfoBar = false
        return copy
    }

    // MARK: - Content

    private func refresh() {
        token?.cancel()
        generation += 1
        header.mode = mode
        guard let node else {
            let count = nodes.count
            let size = nodes.reduce(UInt64(0)) { $0.saturatingAdd($1.size ?? 0) }
            header.configure(icon: NSImage(systemSymbolName: "square.on.square", accessibilityDescription: nil), title: "\(count) items",
                             subtitle: FileTreeView.bytes(size), allowsPreview: false)
            display(ArchiveStateView(symbol: "square.on.square", title: "\(count.formatted()) Items Selected",
                                     message: "\(FileTreeView.bytes(size)) in all"))
            return
        }
        let kind = FileTreeView.kindName(of: node)
        let canPreview = !node.isDirectory && !node.isSymlink && !node.isEncrypted
        header.configure(icon: FileTreeView.icon(forName: node.name, isDirectory: node.isDirectory), title: node.name,
                         subtitle: EntryInfoView.subtitle(node, kind: kind), allowsPreview: canPreview)
        if mode == .info || !canPreview {
            var note: String?
            if node.isEncrypted { note = "Encrypted. Greece can’t open it without the password." }
            display(EntryInfoView(node: node, kind: kind, note: mode == .preview ? note : nil))
            return
        }
        if let cached, cached.node === node {
            header.subtitle = cached.subtitle
            display(cached.view)
            return
        }
        loadPreview(node, kind: kind)
    }

    private func display(_ view: NSView) {
        guard shown !== view else { return }
        shown?.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: content.topAnchor),
            view.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        ])
        shown = view
    }

    private enum Built {
        case image(CGImage)
        case pdf(URL)
        case media(URL, audio: Bool)
        case greece(PreparedPreview, URL)
    }

    private func loadPreview(_ node: FileNode, kind: String) {
        let token = CancelToken()
        self.token = token
        let current = generation
        let source = self.source, scratch = self.scratch, settings = innerSettings

        // A spinner only if extraction takes a moment, so quick previews never flash.
        let spinner = ArchiveStateView.loading()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, self.generation == current, self.shown !== self.cached?.view else { return }
            if !(self.shown is PreviewView) { self.display(spinner) }
        }

        Task.detached(priority: .userInitiated) {
            let result: Result<Built, Error>
            do {
                let file = try source.extract(node, to: scratch, cancel: token)
                result = .success(try EntryPreviewPane.prepare(file, settings: settings))
            } catch {
                result = .failure(error)
            }
            await MainActor.run { [weak self] in
                guard let self, self.generation == current else { return }
                self.finish(result, node: node, kind: kind, current: current)
            }
        }
    }

    nonisolated private static func prepare(_ file: URL, settings: PreviewSettings) throws -> Built {
        let type = UTType(filenameExtension: file.pathExtension)
        if let type, type.conforms(to: .pdf) { return .pdf(file) }
        if let type, type.conforms(to: .audiovisualContent), AVURLAsset.audiovisualTypes().contains(AVFileType(type.identifier)) {
            return .media(file, audio: type.conforms(to: .audio))
        }
        if let type, type.conforms(to: .image), !type.conforms(to: .svg), let image = downsampled(file, maxPixels: 2400) {
            return .image(image)
        }
        return .greece(try PreviewFactory.prepare(file, settings: settings), file)
    }

    nonisolated private static func downsampled(_ url: URL, maxPixels: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ] as CFDictionary)
    }

    private func finish(_ result: Result<Built, Error>, node: FileNode, kind: String, current: Int) {
        switch result {
        case .failure(let error):
            let note: String
            switch error {
            case ArchiveError.tooLarge: note = "Too large to preview inside the archive."
            case ArchiveError.encrypted: note = "Encrypted. Greece can’t open it without the password."
            case ArchiveError.cancelled: return
            case PreviewError.unsupported: note = "There’s no preview for this kind of file."
            default: note = error.localizedDescription
            }
            display(EntryInfoView(node: node, kind: kind, note: note))
        case .success(let built):
            let view: NSView
            var subtitle = header.subtitle
            switch built {
            case .image(let image):
                view = ImagePane(image: image)
                subtitle = [kind, "\(image.width.formatted()) × \(image.height.formatted())", node.size.map(FileTreeView.bytes)].compactMap { $0 }.joined(separator: " · ")
            case .pdf(let url):
                let pdf = PDFView()
                pdf.document = PDFDocument(url: url)
                pdf.autoScales = true
                pdf.displayMode = .singlePageContinuous
                pdf.backgroundColor = .underPageBackgroundColor
                view = pdf
                if let pages = pdf.document?.pageCount {
                    subtitle = [kind, "\(pages) \(pages == 1 ? "page" : "pages")", node.size.map(FileTreeView.bytes)].compactMap { $0 }.joined(separator: " · ")
                }
            case .media(let url, let audio):
                let player = AVPlayerView()
                player.controlsStyle = audio ? .inline : .floating
                player.player = AVPlayer(url: url)
                view = player
            case .greece(let prepared, let url):
                do {
                    let preview = try PreviewFactory.build(prepared, url: url, settings: innerSettings)
                    inner = preview
                    subtitle = ([preview.summary.title] + preview.summary.details).joined(separator: " · ")
                    view = preview
                    // Show it once it has painted, so a web preview never flashes blank.
                    Task { @MainActor [weak self] in
                        await preview.waitUntilReady()
                        guard let self, self.generation == current else { return }
                        self.header.subtitle = subtitle
                        self.cached = (node, view, subtitle)
                        self.display(view)
                    }
                    return
                } catch {
                    display(EntryInfoView(node: node, kind: kind, note: "There’s no preview for this kind of file."))
                    return
                }
            }
            header.subtitle = subtitle
            cached = (node, view, subtitle)
            display(view)
        }
    }
}

/// The pane's title strip: what's selected, and a Preview / Info switch.
private final class PaneHeader: NSView {
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let switcher = NSSegmentedControl()
    var onModeChange: ((EntryPreviewPane.Mode) -> Void)?

    var mode: EntryPreviewPane.Mode = .preview {
        didSet { switcher.selectedSegment = mode.rawValue }
    }

    var subtitle: String {
        get { detail.stringValue }
        set { detail.stringValue = newValue; detail.toolTip = newValue }
    }

    init() {
        super.init(frame: .zero)
        icon.imageScaling = .scaleProportionallyUpOrDown
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.lineBreakMode = .byTruncatingMiddle
        title.setContentCompressionResistancePriority(.defaultLow + 1, for: .horizontal)
        title.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        detail.font = .systemFont(ofSize: 11.5)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        switcher.segmentCount = 2
        switcher.setImage(NSImage(systemSymbolName: "eye", accessibilityDescription: "Preview"), forSegment: 0)
        switcher.setImage(NSImage(systemSymbolName: "info.circle", accessibilityDescription: "Info"), forSegment: 1)
        switcher.setToolTip("Preview", forSegment: 0)
        switcher.setToolTip("Get Info", forSegment: 1)
        switcher.trackingMode = .selectOne
        switcher.controlSize = .small
        switcher.segmentStyle = .automatic
        switcher.selectedSegment = 0
        switcher.target = self
        switcher.action = #selector(switched)
        switcher.setContentCompressionResistancePriority(.required, for: .horizontal)

        let separator = NSBox()
        separator.boxType = .separator
        let stack = NSStackView(views: [icon, title, detail, NSView(), switcher])
        stack.spacing = 6
        stack.setCustomSpacing(8, after: title)
        stack.alignment = .centerY
        for view in [stack, separator] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(icon image: NSImage?, title text: String, subtitle: String, allowsPreview: Bool) {
        icon.image = image
        title.stringValue = text
        title.toolTip = text
        self.subtitle = subtitle
        switcher.setEnabled(allowsPreview, forSegment: 0)
        switcher.isHidden = false
        switcher.selectedSegment = allowsPreview ? mode.rawValue : 1
    }

    @objc private func switched() {
        let next = EntryPreviewPane.Mode(rawValue: switcher.selectedSegment) ?? .preview
        mode = next
        onModeChange?(next)
    }
}

/// A picture centred in the pane, never enlarged past its own size.
private final class ImagePane: NSView {
    init(image: CGImage) {
        super.init(frame: .zero)
        let view = NSImageView()
        view.image = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        view.imageScaling = .scaleProportionallyDown
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            view.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -20),
            view.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            view.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// A calm, centred message: an empty archive, an encrypted one, a spinner while a file extracts.
final class ArchiveStateView: NSView {
    init(symbol: String?, title: String?, message: String?, spinner: Bool = false) {
        super.init(frame: .zero)
        var views: [NSView] = []
        if spinner {
            let indicator = NSProgressIndicator()
            indicator.style = .spinning
            indicator.controlSize = .small
            indicator.startAnimation(nil)
            views.append(indicator)
        }
        if let symbol {
            let image = NSImageView()
            image.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            image.symbolConfiguration = .init(pointSize: 40, weight: .light)
            image.contentTintColor = .tertiaryLabelColor
            views.append(image)
        }
        if let title {
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 15, weight: .semibold)
            label.textColor = .secondaryLabelColor
            views.append(label)
        }
        if let message {
            let label = NSTextField(wrappingLabelWithString: message)
            label.font = .systemFont(ofSize: 12)
            label.textColor = .tertiaryLabelColor
            label.alignment = .center
            label.preferredMaxLayoutWidth = 320
            views.append(label)
        }
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.spacing = 6
        if views.count > 1 { stack.setCustomSpacing(12, after: views[0]) }
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -12),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
        ])
    }

    static func loading() -> ArchiveStateView { ArchiveStateView(symbol: nil, title: nil, message: nil, spinner: true) }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        dirtyRect.fill()
    }
}
