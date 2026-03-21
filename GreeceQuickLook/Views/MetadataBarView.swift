import Cocoa

/// Bottom bar showing file metadata: size, dates, type.
final class MetadataBarView: NSView {

    private let stackView = NSStackView()
    private let sizeLabel = NSTextField(labelWithString: "")
    private let dateLabel = NSTextField(labelWithString: "")
    private let typeLabel = NSTextField(labelWithString: "")
    private let separatorView = NSBox()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true

        // Separator line at the top
        separatorView.boxType = .separator
        separatorView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separatorView)

        // Stack view for labels
        stackView.orientation = .horizontal
        stackView.spacing = 16
        stackView.alignment = .centerY
        stackView.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        stackView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stackView)

        for label in [sizeLabel, dateLabel, typeLabel] {
            label.font = .systemFont(ofSize: 11, weight: .regular)
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingTail
            label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }

        // Spacer to push type label right
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow - 1, for: .horizontal)

        stackView.addArrangedSubview(sizeLabel)
        stackView.addArrangedSubview(dateLabel)
        stackView.addArrangedSubview(spacer)
        stackView.addArrangedSubview(typeLabel)

        NSLayoutConstraint.activate([
            separatorView.topAnchor.constraint(equalTo: topAnchor),
            separatorView.leadingAnchor.constraint(equalTo: leadingAnchor),
            separatorView.trailingAnchor.constraint(equalTo: trailingAnchor),

            stackView.topAnchor.constraint(equalTo: separatorView.bottomAnchor),
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    func configure(with url: URL, category: GreeceConstants.FileCategory) {
        let settings = GreeceSettings.shared

        // File size
        if settings.bool(forKey: GreeceConstants.Keys.metadataShowSize) {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               let size = attrs[.size] as? Int64 {
                sizeLabel.stringValue = formattedSize(size)
                sizeLabel.isHidden = false
            } else {
                sizeLabel.isHidden = true
            }
        } else {
            sizeLabel.isHidden = true
        }

        // Dates
        if settings.bool(forKey: GreeceConstants.Keys.metadataShowDates) {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               let modified = attrs[.modificationDate] as? Date {
                let formatter = DateFormatter()
                formatter.dateStyle = .medium
                formatter.timeStyle = .short
                dateLabel.stringValue = "Modified: \(formatter.string(from: modified))"
                dateLabel.isHidden = false
            } else {
                dateLabel.isHidden = true
            }
        } else {
            dateLabel.isHidden = true
        }

        // File type
        if settings.bool(forKey: GreeceConstants.Keys.metadataShowType) {
            let ext = url.pathExtension.lowercased()
            switch category {
            case .markdown:
                typeLabel.stringValue = "Markdown"
            case .sourceCode:
                let lang = LanguageDetector.detect(url: url)
                typeLabel.stringValue = LanguageDetector.displayName(forLanguage: lang)
            case .csv:
                typeLabel.stringValue = ext == "tsv" || ext == "tab" ? "TSV" : "CSV"
            case .sqlite:
                typeLabel.stringValue = "SQLite Database"
            case .diff:
                typeLabel.stringValue = ext == "patch" ? "Patch" : "Diff"
            case .archive:
                typeLabel.stringValue = archiveTypeName(for: url)
            case .folder:
                typeLabel.stringValue = "Folder"
            case .textBundle:
                typeLabel.stringValue = "TextBundle"
            case .unknown:
                typeLabel.stringValue = ext.uppercased()
            }
            typeLabel.isHidden = false
        } else {
            typeLabel.isHidden = true
        }
    }

    // MARK: - Dark / Light appearance support

    override func updateLayer() {
        super.updateLayer()
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.95).cgColor
    }

    // MARK: - Helpers

    private func formattedSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private func archiveTypeName(for url: URL) -> String {
        let name = url.lastPathComponent.lowercased()
        if name.hasSuffix(".tar.gz") || name.hasSuffix(".tgz") { return "TAR.GZ Archive" }
        if name.hasSuffix(".tar.bz2") || name.hasSuffix(".tbz2") { return "TAR.BZ2 Archive" }
        switch url.pathExtension.lowercased() {
        case "zip": return "ZIP Archive"
        case "tar": return "TAR Archive"
        case "gz":  return "GZ Archive"
        case "bz2": return "BZ2 Archive"
        default:    return "Archive"
        }
    }
}
