import Cocoa
import Compression

/// Renders ZIP/TAR/GZ/BZ2 archives as a browsable directory tree using NSOutlineView.
final class ArchiveRenderer: FileRenderer {

    func render(fileAt url: URL, completion: @escaping (Error?) -> Void) -> NSView {
        // Parse archive entries
        let entries: [ArchiveEntry]
        let archiveType: String

        let name = url.lastPathComponent.lowercased()
        let ext = url.pathExtension.lowercased()

        do {
            if ext == "zip" {
                entries = try ZIPParser.parse(url: url)
                archiveType = "ZIP"
            } else if ext == "tar" {
                entries = try TARParser.parse(url: url)
                archiveType = "TAR"
            } else if name.hasSuffix(".tar.gz") || ext == "tgz" {
                entries = try TARParser.parseGzipped(url: url)
                archiveType = "TAR.GZ"
            } else if name.hasSuffix(".tar.bz2") || ext == "tbz2" {
                entries = try TARParser.parseBz2(url: url)
                archiveType = "TAR.BZ2"
            } else if ext == "gz" {
                // Single file gzip — show metadata only
                entries = [ArchiveEntry(path: url.deletingPathExtension().lastPathComponent, isDirectory: false, size: 0, compressedSize: 0, modificationDate: nil)]
                archiveType = "GZ"
            } else if ext == "bz2" {
                entries = [ArchiveEntry(path: url.deletingPathExtension().lastPathComponent, isDirectory: false, size: 0, compressedSize: 0, modificationDate: nil)]
                archiveType = "BZ2"
            } else {
                throw NSError(domain: "GreeceQL", code: 7, userInfo: [NSLocalizedDescriptionKey: "Unsupported archive format"])
            }
        } catch {
            completion(error)
            return NSView()
        }

        // Build tree structure
        let root = buildTree(from: entries)

        // Create UI
        let container = NSView()
        container.wantsLayer = true

        // Header label
        let headerLabel = NSTextField(labelWithString: "\(archiveType) Archive — \(entries.count) entries")
        headerLabel.font = .systemFont(ofSize: 12, weight: .medium)
        headerLabel.textColor = .secondaryLabelColor
        headerLabel.translatesAutoresizingMaskIntoConstraints = false

        // Scroll view with outline view
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let outlineView = NSOutlineView()
        outlineView.style = .fullWidth
        outlineView.usesAlternatingRowBackgroundColors = true
        outlineView.allowsColumnReordering = true
        outlineView.allowsColumnResizing = true
        outlineView.rowHeight = 22
        outlineView.indentationPerLevel = 18
        outlineView.gridStyleMask = [.solidVerticalGridLineMask]
        outlineView.gridColor = .separatorColor

        // Columns: Name, Size, Compressed, Date, Type
        let nameCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        nameCol.title = "Name"
        nameCol.minWidth = 200
        nameCol.width = 350
        nameCol.sortDescriptorPrototype = NSSortDescriptor(key: "name", ascending: true, selector: #selector(NSString.localizedStandardCompare(_:)))
        outlineView.addTableColumn(nameCol)
        outlineView.outlineTableColumn = nameCol

        let sizeCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("size"))
        sizeCol.title = "Size"
        sizeCol.minWidth = 70
        sizeCol.width = 90
        sizeCol.sortDescriptorPrototype = NSSortDescriptor(key: "size", ascending: true)
        outlineView.addTableColumn(sizeCol)

        let compressedCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("compressed"))
        compressedCol.title = "Compressed"
        compressedCol.minWidth = 70
        compressedCol.width = 90
        outlineView.addTableColumn(compressedCol)

        let dateCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("date"))
        dateCol.title = "Date Modified"
        dateCol.minWidth = 100
        dateCol.width = 150
        dateCol.sortDescriptorPrototype = NSSortDescriptor(key: "date", ascending: true)
        outlineView.addTableColumn(dateCol)

        let typeCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("type"))
        typeCol.title = "Kind"
        typeCol.minWidth = 60
        typeCol.width = 100
        outlineView.addTableColumn(typeCol)

        let dataSource = ArchiveOutlineDataSource(root: root)
        outlineView.dataSource = dataSource
        outlineView.delegate = dataSource

        // Keep strong ref
        let holder = StrongRefView()
        holder.ref = dataSource
        container.addSubview(holder)

        scrollView.documentView = outlineView
        container.addSubview(headerLabel)
        container.addSubview(scrollView)

        NSLayoutConstraint.activate([
            headerLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            headerLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            headerLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),

            scrollView.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 6),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        // Expand top-level items
        DispatchQueue.main.async {
            for child in root.children {
                outlineView.expandItem(child)
            }
        }

        completion(nil)
        return container
    }

    // MARK: - Tree Building

    private func buildTree(from entries: [ArchiveEntry]) -> ArchiveTreeNode {
        let root = ArchiveTreeNode(name: "/", entry: nil)

        for entry in entries {
            let components = entry.path.split(separator: "/").map(String.init)
            var currentNode = root

            for (i, component) in components.enumerated() {
                if let existing = currentNode.children.first(where: { $0.name == component }) {
                    currentNode = existing
                } else {
                    let isLast = (i == components.count - 1)
                    let newNode = ArchiveTreeNode(
                        name: component,
                        entry: isLast ? entry : nil
                    )
                    newNode.isDirectory = !isLast || entry.isDirectory
                    currentNode.children.append(newNode)
                    currentNode = newNode
                }
            }
        }

        // Sort: directories first, then by name
        sortTree(root)
        return root
    }

    private func sortTree(_ node: ArchiveTreeNode) {
        node.children.sort { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        node.children.forEach { sortTree($0) }
    }
}

// MARK: - Strong Ref Holder

private class StrongRefView: NSView {
    var ref: AnyObject?
    override init(frame: NSRect) {
        super.init(frame: .zero)
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - Tree Node

class ArchiveTreeNode: NSObject {
    let name: String
    var entry: ArchiveEntry?
    var children: [ArchiveTreeNode] = []
    var isDirectory: Bool = false

    init(name: String, entry: ArchiveEntry?) {
        self.name = name
        self.entry = entry
        self.isDirectory = entry?.isDirectory ?? false
    }
}

// MARK: - Archive Entry

struct ArchiveEntry {
    let path: String
    let isDirectory: Bool
    let size: UInt64
    let compressedSize: UInt64
    let modificationDate: Date?
}

// MARK: - Outline Data Source

final class ArchiveOutlineDataSource: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    let root: ArchiveTreeNode
    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
    private let sizeFormatter = ByteCountFormatter()

    init(root: ArchiveTreeNode) {
        self.root = root
        sizeFormatter.countStyle = .file
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        let node = item as? ArchiveTreeNode ?? root
        return node.children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        let node = item as? ArchiveTreeNode ?? root
        return node.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? ArchiveTreeNode else { return false }
        return node.isDirectory && !node.children.isEmpty
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? ArchiveTreeNode, let colID = tableColumn?.identifier.rawValue else { return nil }

        switch colID {
        case "name":
            let cell = NSTableCellView()
            let imageView = NSImageView()
            let textField = NSTextField(labelWithString: node.name)
            textField.font = .systemFont(ofSize: 13)
            textField.lineBreakMode = .byTruncatingMiddle

            let icon: NSImage
            if node.isDirectory {
                icon = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: "Folder")
                    ?? NSImage(named: NSImage.folderName) ?? NSImage()
                imageView.contentTintColor = .systemBlue
            } else {
                icon = NSImage(systemSymbolName: "doc.fill", accessibilityDescription: "File")
                    ?? NSImage(named: NSImage.pathTemplateName) ?? NSImage()
                imageView.contentTintColor = .secondaryLabelColor
            }
            imageView.image = icon
            imageView.translatesAutoresizingMaskIntoConstraints = false
            textField.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(imageView)
            cell.addSubview(textField)
            NSLayoutConstraint.activate([
                imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                imageView.widthAnchor.constraint(equalToConstant: 16),
                imageView.heightAnchor.constraint(equalToConstant: 16),
                textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 6),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell

        case "size":
            let size = node.entry?.size ?? 0
            let text = node.isDirectory ? "--" : sizeFormatter.string(fromByteCount: Int64(size))
            let label = NSTextField(labelWithString: text)
            label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            label.textColor = .secondaryLabelColor
            label.alignment = .right
            return label

        case "compressed":
            let size = node.entry?.compressedSize ?? 0
            let text = node.isDirectory ? "--" : sizeFormatter.string(fromByteCount: Int64(size))
            let label = NSTextField(labelWithString: text)
            label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            label.textColor = .tertiaryLabelColor
            label.alignment = .right
            return label

        case "date":
            let text = node.entry?.modificationDate.map { dateFormatter.string(from: $0) } ?? "--"
            let label = NSTextField(labelWithString: text)
            label.font = .systemFont(ofSize: 12)
            label.textColor = .secondaryLabelColor
            return label

        case "type":
            let text: String
            if node.isDirectory {
                text = "Folder"
            } else {
                let ext = (node.name as NSString).pathExtension.uppercased()
                text = ext.isEmpty ? "File" : ext
            }
            let label = NSTextField(labelWithString: text)
            label.font = .systemFont(ofSize: 12)
            label.textColor = .secondaryLabelColor
            return label

        default:
            return nil
        }
    }
}
