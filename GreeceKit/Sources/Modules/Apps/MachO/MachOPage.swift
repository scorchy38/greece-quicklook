import AppKit

/// Command-line tools, dynamic libraries, plug-in bundles, object files and debug symbols.
enum MachOPage {

    static func page(for url: URL, modified: String?) throws -> InspectorPage {
        let bytes = try FileBytes(url: url)
        let file = try MachOFile.parse(bytes)
        let signature = CodeSignature.read(from: bytes, macho: file)
        guard let slice = file.preferredSlice else { throw PreviewError.unsupported }

        let embeddedInfo = infoPlist(in: slice, source: bytes)
        let kind = kindTitle(file, slice: slice)
        let version = Format.version((embeddedInfo?["CFBundleShortVersionString"] as? String) ?? slice.installVersion.flatMap { $0 == "0.0" || $0 == "1.0" ? nil : $0 },
                                     build: embeddedInfo?["CFBundleVersion"] as? String)
        let identifier = (embeddedInfo?["CFBundleIdentifier"] as? String) ?? signature?.identifier ?? slice.installName
        let symbol = slice.fileType == 6 ? "shippingbox.fill" : slice.fileType == 10 ? "ladybug.fill" : slice.fileType == 8 ? "puzzlepiece.extension.fill" : slice.fileType == 1 ? "doc.fill" : "terminal.fill"
        let tint: InspectorTint = slice.fileType == 6 ? .brown : slice.fileType == 10 ? .orange : slice.fileType == 8 ? .indigo : .gray

        var page = InspectorPage(
            header: InspectorHeader(icon: .symbol(symbol, tint), title: url.lastPathComponent, subtitle: Format.joined([kind, version]),
                                    identifier: identifier.map { Format.clean($0, limit: 300) }),
            summary: FileSummary(symbol: "terminal", title: kind, details: [file.architectures.joined(separator: ", "), Format.bytes(bytes.size)], trailing: modified))

        let platform = slice.builds.first?.platform
        if platform == nil || platform == .macOS || platform == .macCatalyst || platform == .driverKit {
            page.badges.append(ArchitectureSupport(file.slices).badge)
        } else if let platform {
            page.badges.append(InspectorBadge("platform", symbol: "iphone", title: platform.name, tone: .accent,
                                              help: String(localized: "Built for \(platform.name), not macOS.", bundle: .greeceKit, comment: "Tooltip. The argument is a platform, such as “iOS”")))
        }
        if slice.fileType != 1 && slice.fileType != 10 {
            let signing = SigningSection.build(signature: signature, url: url, subject: .executable)
            page.badges += signing.badges
            page.sections.append(signing.section)
            page.checks += signing.checks
        }
        if let entitlements = signature?.entitlements, !entitlements.isEmpty,
           let section = ProfilePage.capabilitiesSection(entitlements) {
            var section = section
            section.footer = BundlePage.entitlementsFooter
            if entitlements["com.apple.security.app-sandbox"] as? Bool == true {
                page.badges.append(InspectorBadge("sandbox", symbol: "shield.lefthalf.filled", title: String(localized: "Sandboxed", bundle: .greeceKit, comment: "Badge on an app’s inspector page"), tone: .positive))
            }
            page.sections.append(section)
        }

        page.sections.append(architectures(file, source: bytes))
        if !slice.libraries.isEmpty { page.sections.append(LibrarySection.build(slice.libraries, id: "libraries", title: LibrarySection.linkedLibrariesTitle)) }
        if !slice.rpaths.isEmpty {
            page.sections.append(InspectorSection("rpaths", title: String(localized: "Search Paths", bundle: .greeceKit, comment: "Section title: where a program looks for libraries"),
                                                  footer: String(localized: "Where it looks for @rpath libraries.", bundle: .greeceKit),
                                                  rows: slice.rpaths.map { .item(InspectorItem(symbol: "folder", title: Format.clean($0), mono: true)) }, visibleLimit: 6))
        }
        page.sections.append(info(file, slice: slice, embeddedInfo: embeddedInfo, size: bytes.size))
        return page
    }

    static func kindTitle(_ file: MachOFile, slice: MachOFile.Slice) -> String {
        switch slice.fileType {
        case 2:
            return slice.builds.first?.platform == .driverKit
                ? String(localized: "Driver", bundle: .greeceKit, comment: "A kind of Mach-O file: a device driver")
                : String(localized: "Command-Line Tool", bundle: .greeceKit)
        default: return file.fileTypeName
        }
    }

    static func infoPlist(in slice: MachOFile.Slice, source: RandomAccessBytes) -> [String: Any]? {
        guard let section = slice.section("__TEXT", "__info_plist"), section.size > 0, section.size < 1 << 20,
              let data = source.read(slice.offset + UInt64(section.offset), Int(section.size)) else { return nil }
        let trimmed = data.prefix { $0 != 0 }
        return try? PropertyListSerialization.propertyList(from: Data(trimmed), options: [], format: nil) as? [String: Any]
    }

    static func architectures(_ file: MachOFile, source: RandomAccessBytes) -> InspectorSection {
        let rows = file.slices.map { slice -> InspectorRow in
            var details: [InspectorItem] = []
            for build in slice.builds {
                let minimum = String(localized: "\(build.minimum) or later", bundle: .greeceKit, comment: "The oldest system version a binary runs on, such as “14.0 or later”")
                details.append(.field(build.platform.name, minimum + (build.sdk.map { " · SDK \($0)" } ?? "")))
            }
            if let uuid = slice.uuid { details.append(.field("UUID", uuid.uuidString, mono: true)) }
            if slice.isEncrypted {
                details.append(.field(String(localized: "Encryption", bundle: .greeceKit, comment: "Inspector row title"), String(localized: "FairPlay encrypted", bundle: .greeceKit)))
            }
            if let source = slice.sourceVersion { details.append(.field(String(localized: "Source Version", bundle: .greeceKit, comment: "Inspector row title: a binary’s LC_SOURCE_VERSION"), source)) }
            for tool in slice.toolVersions { details.append(.field(tool.tool, tool.version)) }
            if slice.truncated {
                details.append(InspectorItem(title: String(localized: "Load commands", bundle: .greeceKit, comment: "Inspector row title: a Mach-O binary’s load commands"),
                                             value: String(localized: "Partly unreadable", bundle: .greeceKit), tone: .caution))
            }
            let minimum = slice.builds.first.map { "\($0.platform.name) \($0.minimum)" }
            return .item(InspectorItem(symbol: "cpu", title: slice.architecture, subtitle: minimum.map { String(localized: "Requires \($0) or later", bundle: .greeceKit, comment: "Inspector row subtitle. The argument is a system and version, such as “macOS 14.0”") },
                                       value: Format.bytes(slice.size), help: slice.uuid?.uuidString, details: details))
        }
        return InspectorSection("architectures", title: BundlePage.architecturesLabel, rows: rows)
    }

    static func info(_ file: MachOFile, slice: MachOFile.Slice, embeddedInfo: [String: Any]?, size: UInt64) -> InspectorSection {
        var rows: [InspectorItem] = [.field(BundlePage.kindLabel, kindTitle(file, slice: slice))]
        if let name = embeddedInfo?["CFBundleName"] as? String {
            rows.append(.field(String(localized: "Name", bundle: .greeceKit, comment: "Inspector row title: a program’s name"), Format.clean(name, limit: 120)))
        }
        if let installName = slice.installName {
            rows.append(.field(String(localized: "Install Name", bundle: .greeceKit, comment: "Inspector row title: a dynamic library’s install name"), Format.clean(installName), mono: true))
        }
        if let copyright = embeddedInfo?["NSHumanReadableCopyright"] as? String { rows.append(.field(BundlePage.copyrightLabel, Format.clean(copyright, limit: 200))) }
        var language: [String] = []
        if slice.hasSection(named: "__swift5_types") || slice.libraries.contains(where: { $0.name == "libswiftCore" }) { language.append("Swift") }
        if slice.hasSection(named: "__objc_classlist") { language.append("Objective-C") }
        if slice.hasSection(named: "__go_buildinfo") || slice.hasSection(named: "__gopclntab") { language.append("Go") }
        if slice.libraries.contains(where: { $0.name == "libc++" }) { language.append("C++") }
        if !language.isEmpty {
            rows.append(.field(String(localized: "Languages [programming]", defaultValue: "Languages", bundle: .greeceKit,
                                                comment: "Inspector row title: the programming languages a binary was written in"), language.joined(separator: ", ")))
        }
        if slice.fileType == 2 {
            rows.append(.field(String(localized: "Position Independent", bundle: .greeceKit, comment: "Inspector row title: whether an executable is position-independent (PIE)"),
                               slice.flags & 0x200000 != 0 ? String(localized: "Yes", bundle: .greeceKit) : String(localized: "No", bundle: .greeceKit)))
        }
        if slice.segments.contains(where: { $0.name == "__RESTRICT" }) {
            rows.append(InspectorItem(title: String(localized: "Restricted", bundle: .greeceKit, comment: "Inspector row title: a binary with a __RESTRICT segment"),
                                      value: String(localized: "Ignores DYLD environment variables", bundle: .greeceKit),
                                      help: String(localized: "Has a __RESTRICT segment.", bundle: .greeceKit)))
        }
        rows.append(.field(BundlePage.sizeLabel, Format.bytes(size)))
        return InspectorSection("info", title: BundlePage.infoTitle, rows: rows.map(InspectorRow.item))
    }
}
