import AppKit

/// Xcode archives (.xcarchive) and debug symbol bundles (.dSYM).
enum ArchivePage {

    static func xcarchive(_ url: URL, modified: String?) throws -> InspectorPage {
        let info = DirectoryBundle(url: url).plist("Info.plist") ?? [:]
        let properties = info["ApplicationProperties"] as? [String: Any] ?? [:]
        let name = Format.clean((info["Name"] as? String) ?? url.deletingPathExtension().lastPathComponent, limit: 200)

        var page: InspectorPage
        var appURL: URL?
        if let path = properties["ApplicationPath"] as? String, !path.contains("..") {
            let candidate = url.appendingPathComponent("Products").appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: candidate.path) { appURL = candidate }
        }
        if let appURL, let facts = BundleFacts(source: DirectoryBundle(url: appURL)) {
            page = BundlePage.page(for: facts, icon: .file(appURL), subject: .bundle, modified: modified)
            page.contents = .tree(FileNode.folder(at: url, showHidden: false), title: BundlePage.contentsTitle, count: nil, members: LocalMembers())
        } else {
            let version = Format.version(properties["CFBundleShortVersionString"] as? String, build: properties["CFBundleVersion"] as? String)
            page = InspectorPage(header: InspectorHeader(icon: .file(url), title: name, subtitle: version, identifier: properties["CFBundleIdentifier"] as? String),
                                 summary: FileSummary(symbol: "archivebox", title: xcodeArchiveTitle, trailing: modified))
            page.contents = .tree(FileNode.folder(at: url, showHidden: false), title: BundlePage.contentsTitle, count: nil, members: LocalMembers())
        }
        page.summary.symbol = "archivebox"
        page.summary.title = xcodeArchiveTitle

        var rows: [InspectorItem] = []
        if let scheme = info["SchemeName"] as? String {
            rows.append(.field(String(localized: "Scheme", bundle: .greeceKit, comment: "Inspector row title: the Xcode scheme an archive was built from"), Format.clean(scheme, limit: 120)))
        }
        if let date = info["CreationDate"] as? Date {
            rows.append(.field(String(localized: "Archived", bundle: .greeceKit, comment: "Inspector row title: when an Xcode archive was made"), Format.dateTime(date)))
        }
        if let identity = properties["SigningIdentity"] as? String { rows.append(.field(String(localized: "Signing Identity", bundle: .greeceKit), Format.clean(identity, limit: 200))) }
        if let team = properties["Team"] as? String { rows.append(.field(SigningSection.teamLabel, team, mono: true)) }
        if let architectures = properties["Architectures"] as? [String] { rows.append(.field(BundlePage.architecturesLabel, architectures.joined(separator: ", "))) }
        if let version = info["ArchiveVersion"] as? Int {
            rows.append(.field(String(localized: "Archive Format", bundle: .greeceKit),
                               String(localized: "Version \(String(version))", bundle: .greeceKit, comment: "Inspector row value: the version of the Xcode archive format")))
        }
        if let comment = info["Comment"] as? String, !comment.isEmpty {
            rows.append(InspectorItem(title: String(localized: "Comment", bundle: .greeceKit, comment: "Inspector row title: a comment written into a file"), subtitle: Format.clean(comment, limit: 600)))
        }
        if let status = (info["Distributions"] as? [[String: Any]])?.last, let method = status["identifier"] as? String ?? status["exportMethod"] as? String {
            rows.append(.field(String(localized: "Last Distributed", bundle: .greeceKit, comment: "Inspector row title: how an Xcode archive was last distributed"), Format.clean(method, limit: 80)))
        }
        if !rows.isEmpty {
            page.sections.insert(InspectorSection("archive", title: String(localized: "Archive", bundle: .greeceKit, comment: "Section title: facts about an Xcode archive (noun)"),
                                                  rows: rows.map(InspectorRow.item)), at: 0)
        }

        let symbols = dsyms(in: url.appendingPathComponent("dSYMs"))
        if !symbols.isEmpty {
            let symbolRows = symbols.map { symbol -> InspectorRow in
                .item(InspectorItem(symbol: "ladybug", title: symbol.name, subtitle: symbol.uuids.map { "\($0.architecture) \($0.uuid)" }.first,
                                    value: symbol.uuids.count > 1 ? uuidCount(symbol.uuids.count) : nil,
                                    help: symbol.uuids.map { "\($0.architecture): \($0.uuid)" }.joined(separator: "\n"),
                                    details: symbol.uuids.map { .field($0.architecture, $0.uuid, mono: true) }))
            }
            page.sections.insert(InspectorSection("dsyms", title: debugSymbolsTitle,
                                                  footer: String(localized: "Crash reports are matched to these UUIDs.", bundle: .greeceKit), rows: symbolRows, visibleLimit: 6),
                                 at: rows.isEmpty ? 0 : 1)
        }
        return page
    }

    static var xcodeArchiveTitle: String { String(localized: "Xcode Archive", bundle: .greeceKit, comment: "Info bar title: a kind of file") }

    static var debugSymbolsTitle: String {
        String(localized: "Debug Symbols", bundle: .greeceKit, comment: "Info bar title, section title and kind of file: a .dSYM bundle or Mach-O debug symbols file")
    }

    /// "2 UUIDs".
    static func uuidCount(_ count: Int) -> String {
        String(localized: "\(count) UUIDs", bundle: .greeceKit, comment: "How many build UUIDs a debug symbols file covers")
    }

    struct SymbolFile {
        var name: String
        var uuids: [(architecture: String, uuid: String)]
        var size: UInt64
    }

    static func dsyms(in directory: URL) -> [SymbolFile] {
        let children = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return children.filter { $0.pathExtension.lowercased() == "dsym" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            .prefix(200).flatMap { symbolFiles(in: $0) }
    }

    /// Each DWARF binary inside a dSYM, with its per-architecture UUIDs.
    static func symbolFiles(in dsym: URL) -> [SymbolFile] {
        let dwarf = dsym.appendingPathComponent("Contents/Resources/DWARF")
        let files = ((try? FileManager.default.contentsOfDirectory(at: dwarf, includingPropertiesForKeys: [.fileSizeKey])) ?? []).sorted { $0.lastPathComponent < $1.lastPathComponent }
        return files.prefix(32).compactMap { file in
            guard let bytes = try? FileBytes(url: file), let macho = try? MachOFile.parse(bytes) else { return nil }
            let uuids = macho.slices.compactMap { slice in slice.uuid.map { (slice.architecture, $0.uuidString) } }
            return SymbolFile(name: dsym.lastPathComponent, uuids: uuids, size: bytes.size)
        }
    }

    static func dsym(_ url: URL, modified: String?) throws -> InspectorPage {
        let info = DirectoryBundle(url: url).plist("Contents/Info.plist") ?? [:]
        let files = symbolFiles(in: url)
        guard !files.isEmpty || !info.isEmpty else { throw PreviewError.unsupported }
        let version = Format.version(info["CFBundleShortVersionString"] as? String, build: info["CFBundleVersion"] as? String)
        var identifier = info["CFBundleIdentifier"] as? String
        if let value = identifier, value.hasPrefix("com.apple.xcode.dsym.") { identifier = String(value.dropFirst("com.apple.xcode.dsym.".count)) }
        let total = files.reduce(0) { $0 + $1.size }
        var page = InspectorPage(
            header: InspectorHeader(icon: .symbol("ladybug.fill", .orange), title: url.lastPathComponent, subtitle: Format.joined([debugSymbolsTitle, version]), identifier: identifier),
            summary: FileSummary(symbol: "ladybug", title: debugSymbolsTitle,
                                 details: [uuidCount(files.flatMap(\.uuids).count), Format.bytes(total)], trailing: modified))
        var rows: [InspectorRow] = []
        let dwarf = url.appendingPathComponent("Contents/Resources/DWARF")
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: dwarf.path)) ?? []).sorted()
        for (index, file) in files.enumerated() {
            for entry in file.uuids {
                rows.append(.item(InspectorItem(symbol: "cpu", title: entry.architecture, subtitle: index < names.count && files.count > 1 ? names[index] : nil,
                                                value: entry.uuid, mono: true)))
            }
        }
        if !rows.isEmpty {
            page.sections.append(InspectorSection("uuids", title: "UUIDs",
                                                  footer: String(localized: "Crash reports from builds with these UUIDs can be symbolicated with this file.", bundle: .greeceKit), rows: rows))
        }
        var details: [InspectorItem] = []
        if !names.isEmpty {
            details.append(.field(String(localized: "Binary", bundle: .greeceKit, comment: "Inspector row title: the program file(s) a debug symbols bundle describes"), names.joined(separator: ", ")))
        }
        details.append(.field(BundlePage.sizeLabel, Format.bytes(total)))
        page.sections.append(InspectorSection("info", title: BundlePage.infoTitle, rows: details.map(InspectorRow.item)))
        page.contents = .tree(FileNode.folder(at: url, showHidden: false), title: BundlePage.contentsTitle, count: nil, members: LocalMembers())
        return page
    }
}
