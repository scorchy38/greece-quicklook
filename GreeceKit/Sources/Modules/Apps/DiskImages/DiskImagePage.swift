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
            let algorithm = image.encryption?.algorithm ?? "AES"
            badges.append(InspectorBadge("encrypted", symbol: "lock.fill", title: encryptedText, tone: .accent,
                                         help: String(localized: "Encrypted with \(algorithm). Its files can only be read with the password.", bundle: .greeceKit,
                                                      comment: "Badge tooltip. The argument is an encryption algorithm, such as “AES-256”")))
        }
        let licenseTitle = String(localized: "License Agreement", bundle: .greeceKit, comment: "Section title: a software license shown before installing")
        if image.udif?.hasLicenseAgreement == true {
            badges.append(InspectorBadge("license", symbol: "doc.text", title: licenseTitle,
                                         help: String(localized: "Finder shows a license agreement that has to be accepted before the disk opens.", bundle: .greeceKit)))
        }

        var sections: [InspectorSection] = []
        if !apps.isEmpty, let contents, let section = applicationsSection(apps, contents: contents) { sections.append(section) }
        sections.append(imageSection(image))
        if let contents {
            sections.append(volumeSection(contents))
        } else if image.container == .encrypted {
            sections.append(InspectorSection("volume", title: volumeTitle, rows: [
                .note(InspectorNote(symbol: "lock",
                                    text: String(localized: "The files are encrypted. Open the disk image in Finder and enter its password to see them.", bundle: .greeceKit),
                                    tone: .neutral)),
            ]))
        } else if let unreadable = image.partitionMap.partitions.first(where: { $0.fileSystem != nil })?.fileSystem {
            let fileSystem = unreadable.title
            sections.append(InspectorSection("volume", title: volumeTitle, rows: [
                .note(InspectorNote(symbol: "externaldrive.badge.questionmark",
                                    text: String(localized: "Greece can’t list files on \(fileSystem) volumes.", bundle: .greeceKit,
                                                 comment: "The argument is a file system, such as “NTFS”"),
                                    tone: .neutral)),
            ]))
        }
        if let license = image.udif?.licenseText {
            let limited = license.count > 200_000 ? String(license.prefix(200_000)) : license
            // The agreement's own first line ("Software License Agreement for …") names it best.
            let firstLine = license.split(separator: "\n").first.map { Format.clean(String($0), limit: 80) } ?? ""
            sections.append(InspectorSection("license", title: licenseTitle, rows: [
                .code(InspectorCode(symbol: "doc.text",
                                    title: firstLine.isEmpty ? String(localized: "Agreement", bundle: .greeceKit, comment: "A license agreement without a title") : firstLine,
                                    subtitle: String(localized: "Shown before the disk opens", bundle: .greeceKit, comment: "Under a disk image’s license agreement"),
                                    text: limited, grammar: "plaintext", truncated: limited.count < license.count)),
            ]))
        }

        var page = InspectorPage(header: header, badges: badges, sections: sections, summary: summary(image, contents: contents))
        if let contents, !contents.entries.isEmpty {
            let entries = contents.entries.map { ArchiveEntry(path: $0.path, isDirectory: $0.isDirectory, isSymlink: $0.isSymlink, size: $0.size, modified: $0.modified) }
            let listing = ArchiveListing(format: .zip, container: .zip, entries: entries, archiveSize: image.fileSize, truncated: contents.truncated)
            page.contents = .tree(FileNode.tree(from: listing, showHidden: settings.showHiddenFiles),
                                  title: String(localized: "Files", bundle: .greeceKit, comment: "Tab title: the files inside the app, package or disk image being previewed"), count: contents.fileCount,
                                  members: DiskImageMembers(url: image.url))
        }
        return page
    }

    private static var volumeTitle: String {
        String(localized: "Volume", bundle: .greeceKit, comment: "Section title: the disk inside a disk image")
    }

    private static var encryptedText: String {
        String(localized: "Encrypted", bundle: .greeceKit, comment: "A disk image that needs a password to open")
    }

    // MARK: Sections

    private static func applicationsSection(_ apps: [DiskImage.ContainedApp], contents: DiskImage.Contents) -> InspectorSection? {
        var rows: [InspectorRow]
        if apps.count == 1, let app = apps.first {
            // The header already names the app: here, only what it needs and how it installs.
            rows = app.minimumSystem.map { version in
                [.item(.field(String(localized: "Requires", bundle: .greeceKit, comment: "Inspector row title; its value is the oldest system version the app runs on"),
                              minimumSystemText(version), help: "LSMinimumSystemVersion"))]
            } ?? []
        } else {
            rows = apps.map { app in
                .item(InspectorItem(symbol: "app", title: app.name,
                                    subtitle: Format.joined([Format.version(app.version, build: app.build), app.bundleID]),
                                    value: app.minimumSystem.map(minimumSystemText), help: app.path))
            }
        }
        if contents.applicationsLink {
            rows.append(.item(InspectorItem(symbol: "arrow.down.app", title: String(localized: "Install by dragging", bundle: .greeceKit),
                                            subtitle: String(localized: "Includes a shortcut to the Applications folder.", bundle: .greeceKit))))
        }
        let title = apps.count == 1 ? String(localized: "Application", bundle: .greeceKit, comment: "Section title: the one app inside a disk image")
                                    : String(localized: "Applications", bundle: .greeceKit, comment: "Section title: the apps inside a disk image")
        return rows.isEmpty ? nil : InspectorSection("apps", title: title, rows: rows)
    }

    /// "macOS 12.0 or later".
    private static func minimumSystemText(_ version: String) -> String {
        String(localized: "macOS \(version) or later", bundle: .greeceKit, comment: "The oldest macOS a package or app runs on. The argument is a version, such as “12.0”")
    }

    private static func imageSection(_ image: DiskImage) -> InspectorSection {
        let format = image.format
        var rows: [InspectorItem] = []
        let code = format.code.isEmpty ? nil : format.code
        rows.append(.field(String(localized: "Format", bundle: .greeceKit, comment: "Inspector row title: a disk image’s format"), Format.joined([format.description, code]),
                           help: code.map { code in
                               String(localized: "hdiutil format \(code)", bundle: .greeceKit,
                                      comment: "Tooltip. hdiutil is a command-line tool: keep its name. The argument is a format code, such as “UDZO”")
                           }))
        rows.append(.field(String(localized: "Size", bundle: .greeceKit, comment: "Inspector row title"), Format.bytes(image.fileSize)))
        if let virtual = image.virtualSize, virtual > 0, virtual != image.fileSize {
            rows.append(.field(String(localized: "Disk Size", bundle: .greeceKit, comment: "Inspector row title: the size of the disk inside a disk image"), Format.bytes(virtual),
                               help: String(localized: "The size of the disk inside the image.", bundle: .greeceKit)))
        }
        if let encryption = image.encryption {
            rows.append(.field(String(localized: "Encryption", bundle: .greeceKit, comment: "Inspector row title; its value is an algorithm, such as “AES-256”"), encryption.algorithm))
        }
        if let udif = image.udif {
            if udif.trailer.segmentCount > 1 {
                let number = String(udif.trailer.segmentNumber), count = String(udif.trailer.segmentCount)
                rows.append(.field(String(localized: "Segment", bundle: .greeceKit, comment: "Inspector row title: which part of a multi-part disk image this file is"),
                                   String(localized: "\(number) of \(count)", bundle: .greeceKit,
                                          comment: "A part out of a whole: “2 of 3” segments, or “4 GB of 10 GB” used. The arguments are numbers or sizes")))
            }
            if let checksum = udif.trailer.masterChecksum ?? udif.trailer.dataChecksum {
                rows.append(.field(String(localized: "Checksum", bundle: .greeceKit, comment: "Inspector row title"), "\(checksum.name) \(checksum.text)", mono: false))
            }
        }
        let map = image.partitionMap
        if map.scheme != .none {
            rows.append(.field(String(localized: "Partition Map", bundle: .greeceKit, comment: "Inspector row title; its value is a partition scheme"), map.scheme.title))
        }
        var section = InspectorSection("image", title: diskImageTitle, rows: .items(rows))
        let partitions = map.partitions.filter { $0.length > 0 }
        // One partition is just the volume below; list them when there's a choice.
        if partitions.count > 1 {
            for partition in partitions.prefix(32) {
                let name = partition.name.isEmpty ? partition.type : partition.name
                section.rows.append(.item(InspectorItem(symbol: partition.fileSystem == nil ? "square.dashed" : "internaldrive",
                                                        title: name,
                                                        subtitle: Format.joined([partition.fileSystem?.title, partition.name.isEmpty ? nil : partition.type]),
                                                        value: Format.bytes(partition.length))))
            }
        }
        return section
    }

    private static var diskImageTitle: String {
        String(localized: "Disk Image", bundle: .greeceKit, comment: "A kind of file; also a section title")
    }

    private static func volumeSection(_ contents: DiskImage.Contents) -> InspectorSection {
        var rows: [InspectorItem] = []
        if !contents.volumeName.isEmpty { rows.append(.field(String(localized: "Name", bundle: .greeceKit, comment: "Inspector row title: a volume’s name"), contents.volumeName)) }
        rows.append(.field(String(localized: "File System", bundle: .greeceKit, comment: "Inspector row title; its value is a file system, such as “APFS”"), contents.fileSystem.title))
        let files = String(localized: "\(contents.fileCount) files", bundle: .greeceKit, comment: "The argument is a count")
        let folders = contents.folderCount > 0 ? String(localized: "\(contents.folderCount) folders", bundle: .greeceKit, comment: "The argument is a count") : nil
        rows.append(.field(String(localized: "Contents", bundle: .greeceKit, comment: "Inspector row title; its value counts files and folders"),
                           Format.joined([files, folders], separator: ", ")))
        rows.append(.field(String(localized: "Total Size", bundle: .greeceKit, comment: "Inspector row title: the size of all files on a volume"), Format.bytes(contents.totalBytes)))
        if let used = contents.usedBytes, let capacity = contents.capacity, capacity > 0, contents.fileSystem != .iso9660 {
            let usedText = Format.bytes(used), capacityText = Format.bytes(capacity)
            rows.append(.field(String(localized: "Used", bundle: .greeceKit, comment: "Inspector row title: space used on a volume"),
                               String(localized: "\(usedText) of \(capacityText)", bundle: .greeceKit,
                                      comment: "A part out of a whole: “2 of 3” segments, or “4 GB of 10 GB” used. The arguments are numbers or sizes")))
        }
        if contents.backgroundImage != nil {
            rows.append(InspectorItem(symbol: "photo", title: String(localized: "Custom window background", bundle: .greeceKit),
                                      subtitle: String(localized: "Finder shows a designed window when the disk opens.", bundle: .greeceKit)))
        }
        if contents.otherVolumes > 0 {
            rows.append(.field(String(localized: "Other Volumes", bundle: .greeceKit, comment: "Inspector row title; its value is a count"), "\(contents.otherVolumes)"))
        }
        return InspectorSection("volume", title: volumeTitle,
                                footer: contents.truncated ? String(localized: "Showing the first \(contents.entries.count) items.", bundle: .greeceKit,
                                                                    comment: "Section footer: a listing that was cut short. The argument is a count") : nil,
                                rows: .items(rows))
    }

    // MARK: Facts

    private static func formatBadge(_ image: DiskImage) -> InspectorBadge? {
        let format = image.format
        let code = format.code
        switch image.container {
        case .udif:
            if let compression = format.compression {
                return InspectorBadge("format", symbol: "archivebox", title: String(localized: "Compressed", bundle: .greeceKit, comment: "Badge on a disk image"),
                                      help: String(localized: "Compressed with \(compression) (\(code)). Read-only.", bundle: .greeceKit,
                                                   comment: "Badge tooltip. The arguments are a compression method, such as “zlib”, and a format code, such as “UDZO”"))
            }
            return InspectorBadge("format", symbol: "lock.doc", title: String(localized: "Read-Only", bundle: .greeceKit, comment: "Badge on a disk image"),
                                  help: String(localized: "An uncompressed, read-only disk image (\(code)).", bundle: .greeceKit,
                                               comment: "Badge tooltip. The argument is a format code, such as “UDRO”"))
        case .sparseImage, .sparseBundle, .asif:
            return InspectorBadge("format", symbol: "square.stack.3d.up", title: String(localized: "Sparse", bundle: .greeceKit, comment: "Badge: a disk image that grows as files are added"),
                                  help: String(localized: "Grows as files are added, up to the size of its disk.", bundle: .greeceKit))
        case .raw:
            return code == "ISO" ? InspectorBadge("format", symbol: "opticaldisc", title: "ISO 9660",
                                                  help: String(localized: "A CD or DVD image.", bundle: .greeceKit)) : nil
        case .encrypted:
            return nil
        }
    }

    private static func kindName(for image: DiskImage) -> String {
        switch image.container {
        case .udif: return diskImageTitle
        case .sparseImage: return String(localized: "Sparse Disk Image", bundle: .greeceKit, comment: "A kind of file")
        case .sparseBundle: return String(localized: "Sparse Bundle Disk Image", bundle: .greeceKit, comment: "A kind of file")
        case .asif: return String(localized: "Apple Sparse Image", bundle: .greeceKit, comment: "A kind of file")
        case .encrypted: return String(localized: "Encrypted Disk Image", bundle: .greeceKit, comment: "A kind of file")
        case .raw: return image.format.code == "ISO" ? String(localized: "ISO Disk Image", bundle: .greeceKit, comment: "A kind of file") : diskImageTitle
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
        details.append(image.container == .encrypted ? encryptedText : format.description)
        details.append(Format.bytes(image.fileSize))
        if let contents {
            details.append(String(localized: "\(contents.fileCount) files", bundle: .greeceKit, comment: "The argument is a count"))
            if contents.truncated {
                details.append(String(localized: "Showing first \(contents.entries.count)", bundle: .greeceKit,
                                      comment: "Info bar detail: a listing that was cut short. The argument is how many items are shown"))
            }
        }
        let modified = (try? image.url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate.map(PreviewFactory.modifiedText)
        return FileSummary(symbol: "externaldrive", title: diskImageTitle, details: details, trailing: modified)
    }
}
