import AppKit

/// The inspector page for a disk image: the app inside, the image's format and partitions, the volume,
/// its license agreement, and every file, all read without mounting. Signature and notarization are
/// added by the caller from `DiskImage.codeSignatureRange`.
enum DiskImagePage {
    static func page(for url: URL, settings: PreviewSettings) throws -> InspectorPage {
        let image = try DiskImage(url: url)
        return page(for: image, settings: settings)
    }

    static func page(for image: DiskImage, settings: PreviewSettings, deadline: DiskDeadline = DiskDeadline(seconds: 1.5)) -> InspectorPage {
        let url = image.url
        let contents = image.contents(deadline: deadline)
        let apps = contents?.apps ?? []

        // Header: the app inside when there's exactly one, else the image itself.
        var header = InspectorHeader(icon: .contentType(contentType(for: image)), title: url.lastPathComponent)
        if apps.count == 1, let app = apps.first {
            header = InspectorHeader(icon: app.icon.map { .image($0, shape: .asIs) } ?? .contentType("com.apple.application-bundle"),
                                     title: app.name, subtitle: Format.version(app.version, build: app.build), identifier: app.bundleID)
        } else {
            header.subtitle = Format.joined([kindName(for: image), Format.bytes(image.fileSize)])
        }

        var badges: [InspectorBadge] = []
        if let badge = formatBadge(image) { badges.append(badge) }
        if image.container == .encrypted {
            badges.append(InspectorBadge("encrypted", symbol: "lock.fill", title: "Encrypted", tone: .accent,
                                         help: "Encrypted with \(image.encryption?.algorithm ?? "AES"). Its files can only be read with the password."))
        }
        if image.udif?.hasLicenseAgreement == true {
            badges.append(InspectorBadge("license", symbol: "doc.text", title: "License Agreement",
                                         help: "Finder shows a license agreement that has to be accepted before the disk opens."))
        }

        var sections: [InspectorSection] = []
        if !apps.isEmpty, let contents, let section = applicationsSection(apps, contents: contents) { sections.append(section) }
        sections.append(imageSection(image))
        if let contents {
            sections.append(volumeSection(contents))
        } else if image.container == .encrypted {
            sections.append(InspectorSection("volume", title: "Volume", rows: [
                .note(InspectorNote(symbol: "lock", text: "The files are encrypted. Open the disk image in Finder and enter its password to see them.", tone: .neutral)),
            ]))
        } else if let unreadable = image.partitionMap.partitions.first(where: { $0.fileSystem != nil })?.fileSystem {
            sections.append(InspectorSection("volume", title: "Volume", rows: [
                .note(InspectorNote(symbol: "externaldrive.badge.questionmark", text: "Greece can’t list files on \(unreadable.rawValue) volumes.", tone: .neutral)),
            ]))
        }
        if let license = image.udif?.licenseText {
            let limited = license.count > 200_000 ? String(license.prefix(200_000)) : license
            // The agreement's own first line ("Software License Agreement for …") names it best.
            let firstLine = license.split(separator: "\n").first.map { Format.clean(String($0), limit: 80) } ?? ""
            sections.append(InspectorSection("license", title: "License Agreement", rows: [
                .code(InspectorCode(symbol: "doc.text", title: firstLine.isEmpty ? "Agreement" : firstLine, subtitle: "Shown before the disk opens",
                                    text: limited, grammar: "plaintext", truncated: limited.count < license.count)),
            ]))
        }

        var page = InspectorPage(header: header, badges: badges, sections: sections, summary: summary(image, contents: contents))
        if let contents, !contents.entries.isEmpty {
            let entries = contents.entries.map { ArchiveEntry(path: $0.path, isDirectory: $0.isDirectory, isSymlink: $0.isSymlink, size: $0.size, modified: $0.modified) }
            let listing = ArchiveListing(format: .zip, container: .zip, entries: entries, archiveSize: image.fileSize, truncated: contents.truncated)
            page.contents = .tree(FileNode.tree(from: listing, showHidden: settings.showHiddenFiles), title: "Files", count: contents.fileCount)
        }
        return page
    }

    // MARK: Sections

    private static func applicationsSection(_ apps: [DiskImage.ContainedApp], contents: DiskImage.Contents) -> InspectorSection? {
        var rows: [InspectorRow]
        if apps.count == 1, let app = apps.first {
            // The header already names the app: here, only what it needs and how it installs.
            rows = app.minimumSystem.map { [.item(.field("Requires", "macOS \($0) or later", help: "LSMinimumSystemVersion"))] } ?? []
        } else {
            rows = apps.map { app in
                .item(InspectorItem(symbol: "app", title: app.name,
                                    subtitle: Format.joined([Format.version(app.version, build: app.build), app.bundleID]),
                                    value: app.minimumSystem.map { "macOS \($0) or later" }, help: app.path))
            }
        }
        if contents.applicationsLink {
            rows.append(.item(InspectorItem(symbol: "arrow.down.app", title: "Install by dragging",
                                            subtitle: "Includes a shortcut to the Applications folder.")))
        }
        return rows.isEmpty ? nil : InspectorSection("apps", title: apps.count == 1 ? "Application" : "Applications", rows: rows)
    }

    private static func imageSection(_ image: DiskImage) -> InspectorSection {
        let format = image.format
        var rows: [InspectorItem] = []
        let code = format.code.isEmpty ? nil : format.code
        rows.append(.field("Format", Format.joined([format.description, code]), help: code.map { "hdiutil format \($0)" }))
        rows.append(.field("Size", Format.bytes(image.fileSize)))
        if let virtual = image.virtualSize, virtual > 0, virtual != image.fileSize {
            rows.append(.field("Disk Size", Format.bytes(virtual), help: "The size of the disk inside the image."))
        }
        if let encryption = image.encryption {
            rows.append(.field("Encryption", encryption.algorithm))
        }
        if let udif = image.udif {
            if udif.trailer.segmentCount > 1 {
                rows.append(.field("Segment", "\(udif.trailer.segmentNumber) of \(udif.trailer.segmentCount)"))
            }
            if let checksum = udif.trailer.masterChecksum ?? udif.trailer.dataChecksum {
                rows.append(.field("Checksum", "\(checksum.name) \(checksum.text)", mono: false))
            }
        }
        let map = image.partitionMap
        if map.scheme != .none { rows.append(.field("Partition Map", map.scheme.rawValue)) }
        var section = InspectorSection("image", title: "Disk Image", rows: .items(rows))
        let partitions = map.partitions.filter { $0.length > 0 }
        // One partition is just the volume below; list them when there's a choice.
        if partitions.count > 1 {
            for partition in partitions.prefix(32) {
                let name = partition.name.isEmpty ? partition.type : partition.name
                section.rows.append(.item(InspectorItem(symbol: partition.fileSystem == nil ? "square.dashed" : "internaldrive",
                                                        title: name,
                                                        subtitle: Format.joined([partition.fileSystem?.rawValue, partition.name.isEmpty ? nil : partition.type]),
                                                        value: Format.bytes(partition.length))))
            }
        }
        return section
    }

    private static func volumeSection(_ contents: DiskImage.Contents) -> InspectorSection {
        var rows: [InspectorItem] = []
        if !contents.volumeName.isEmpty { rows.append(.field("Name", contents.volumeName)) }
        rows.append(.field("File System", contents.fileSystem.rawValue))
        let files = Format.count(contents.fileCount, "file")
        let folders = contents.folderCount > 0 ? Format.count(contents.folderCount, "folder") : nil
        rows.append(.field("Contents", Format.joined([files, folders], separator: ", ")))
        rows.append(.field("Total Size", Format.bytes(contents.totalBytes)))
        if let used = contents.usedBytes, let capacity = contents.capacity, capacity > 0, contents.fileSystem != .iso9660 {
            rows.append(.field("Used", "\(Format.bytes(used)) of \(Format.bytes(capacity))"))
        }
        if contents.backgroundImage != nil {
            rows.append(InspectorItem(symbol: "photo", title: "Custom window background", subtitle: "Finder shows a designed window when the disk opens."))
        }
        if contents.otherVolumes > 0 {
            rows.append(.field("Other Volumes", "\(contents.otherVolumes)"))
        }
        return InspectorSection("volume", title: "Volume",
                                footer: contents.truncated ? "Showing the first \(contents.entries.count.formatted()) items." : nil,
                                rows: .items(rows))
    }

    // MARK: Facts

    private static func formatBadge(_ image: DiskImage) -> InspectorBadge? {
        let format = image.format
        switch image.container {
        case .udif:
            if let compression = format.compression {
                return InspectorBadge("format", symbol: "archivebox", title: "Compressed",
                                      help: "Compressed with \(compression) (\(format.code)). Read-only.")
            }
            return InspectorBadge("format", symbol: "lock.doc", title: "Read-Only", help: "An uncompressed, read-only disk image (\(format.code)).")
        case .sparseImage, .sparseBundle, .asif:
            return InspectorBadge("format", symbol: "square.stack.3d.up", title: "Sparse",
                                  help: "Grows as files are added, up to the size of its disk.")
        case .raw:
            return format.code == "ISO" ? InspectorBadge("format", symbol: "opticaldisc", title: "ISO 9660", help: "A CD or DVD image.") : nil
        case .encrypted:
            return nil
        }
    }

    private static func kindName(for image: DiskImage) -> String {
        switch image.container {
        case .udif: return "Disk Image"
        case .sparseImage: return "Sparse Disk Image"
        case .sparseBundle: return "Sparse Bundle Disk Image"
        case .asif: return "Apple Sparse Image"
        case .encrypted: return "Encrypted Disk Image"
        case .raw: return image.format.code == "ISO" ? "ISO Disk Image" : "Disk Image"
        }
    }

    static func contentType(for image: DiskImage) -> String {
        switch image.container {
        case .sparseImage, .asif: return "com.apple.disk-image-sparse"
        case .sparseBundle: return "com.apple.disk-image-sparse-bundle"
        case .raw: return image.format.code == "ISO" ? "public.iso-image" : "com.apple.disk-image"
        case .udif, .encrypted: return "com.apple.disk-image-udif"
        }
    }

    private static func summary(_ image: DiskImage, contents: DiskImage.Contents?) -> FileSummary {
        var details: [String] = []
        let format = image.format
        details.append(image.container == .encrypted ? "Encrypted" : format.description)
        details.append(Format.bytes(image.fileSize))
        if let contents {
            details.append(Format.count(contents.fileCount, "file"))
            if contents.truncated { details.append("Showing first \(contents.entries.count.formatted())") }
        }
        let modified = (try? image.url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate.map(PreviewFactory.modifiedText)
        return FileSummary(symbol: "externaldrive", title: "Disk Image", details: details, trailing: modified)
    }
}
