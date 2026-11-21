import AppKit

/// Apps, installers and binaries: bundles, Mach-O and PE executables, installer packages, disk
/// images, iOS and Android apps, provisioning and configuration profiles, torrents. Each becomes a
/// native inspector page: what it is, who signed it, what it may do and what it carries.
enum AppsModule: PreviewModule {
    static let id = "apps"

    enum Kind: Equatable {
        case bundle, xcarchive, dsym
        case machO
        case windows
        case installerPackage
        case ipa, android
        case provisioningProfile, configurationProfile
        case torrent
    }

    /// Package extensions previewed as bundles. Finder already shows their icons, so no thumbnails.
    static let bundleExtensions: Set<String> = [
        "app", "appex", "framework", "bundle", "plugin", "kext", "systemextension", "xpc", "qlgenerator",
        "saver", "prefpane", "mdimporter", "dext", "driver",
    ]

    static func kind(of file: FileInfo) -> Kind? {
        if file.isDirectory {
            if file.ext == "xcarchive" { return .xcarchive }
            if InstallerPackagePage.sniff(probe: [], ext: file.ext, isDirectory: true) { return .installerPackage }
            if file.ext == "dsym" { return .dsym }
            return bundleExtensions.contains(file.ext) ? .bundle : nil
        }
        let bytes = file.probe.bytes
        if file.ext != "class", MachOFile.magic(of: bytes) != nil { return .machO }
        if WindowsPage.sniff(probe: bytes) { return .windows }
        if InstallerPackagePage.sniff(probe: bytes, ext: file.ext, isDirectory: false) { return .installerPackage }
        if AndroidPage.sniff(probe: bytes, ext: file.ext) { return .android }
        let zip = bytes.count >= 4 && bytes[0] == 0x50 && bytes[1] == 0x4B && bytes[2] == 0x03 && bytes[3] == 0x04
        switch file.ext {
        case "ipa": return zip ? .ipa : nil
        case "mobileprovision", "provisionprofile": return SignedContainer.looksSigned(bytes) ? .provisioningProfile : nil
        case "mobileconfig":
            if SignedContainer.looksSigned(bytes) { return .configurationProfile }
            return file.probe.isText && file.probe.text.contains("<plist") ? .configurationProfile : nil
        case "torrent": return bytes.first == UInt8(ascii: "d") ? .torrent : nil
        default: return nil
        }
    }

    static func claims(_ file: FileInfo) -> Bool { kind(of: file) != nil }

    static let preferredSize = NSSize(width: 720, height: 860)

    static func prepare(_ file: FileInfo, settings: PreviewSettings) throws -> PreparedPreview {
        let started = Date()
        let page = try makePage(file)
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        SigningSection.log.info("Prepared \(page.summary.title, privacy: .public) in \(elapsed, privacy: .public) ms")
        return .native(page.summary, preferredSize) { settings in
            InspectorView(page: page, settings: settings)
        }
    }

    static func makePage(_ file: FileInfo) throws -> InspectorPage {
        guard let kind = kind(of: file) else { throw PreviewError.unsupported }
        let modified = file.modifiedText
        switch kind {
        case .bundle:
            guard let facts = BundleFacts(source: DirectoryBundle(url: file.url)) else { throw PreviewError.unsupported }
            return BundlePage.page(for: facts, icon: .file(file.url), subject: .bundle, modified: modified)
        case .xcarchive:
            return try ArchivePage.xcarchive(file.url, modified: modified)
        case .dsym:
            return try ArchivePage.dsym(file.url, modified: modified)
        case .machO:
            return try MachOPage.page(for: file.url, modified: modified)
        case .windows:
            return try WindowsPage.page(for: file.url, settings: .default)
        case .installerPackage:
            return try InstallerPackagePage.page(for: file.url, settings: .default)
        case .ipa:
            return try IPAPage.page(for: file.url, modified: modified)
        case .android:
            return try AndroidPage.page(for: file.url, settings: .default)
        case .provisioningProfile:
            return try ProfilePage.provisioningPage(for: file.url, modified: modified)
        case .configurationProfile:
            return try ProfilePage.configurationPage(for: file.url, modified: modified)
        case .torrent:
            return try TorrentPage.page(for: file.url, modified: modified)
        }
    }

    static func thumbnail(_ file: FileInfo, size: CGSize, settings: PreviewSettings) -> ThumbnailPage? {
        switch kind(of: file) {
        case .ipa:
            guard let icon = IPAPage.icon(for: file.url) else { return nil }
            return AppThumbnails.appIcon(icon, shape: .iOS, size: size, badge: "IPA")
        case .android:
            guard let icon = AndroidPage.icon(for: file.url) else { return nil }
            return AppThumbnails.appIcon(icon, shape: .asIs, size: size, badge: file.ext.uppercased())
        case .windows:
            guard let icon = WindowsPage.icon(for: file.url) else { return nil }
            return AppThumbnails.appIcon(icon, shape: .asIs, size: size, badge: file.ext.isEmpty ? "EXE" : file.ext.uppercased())
        case .provisioningProfile:
            return AppThumbnails.profileCard(for: file.url, size: size)
        case .configurationProfile:
            return AppThumbnails.configurationCard(for: file.url, size: size)
        case .torrent:
            return AppThumbnails.torrentCard(for: file.url, size: size)
        default:
            return nil
        }
    }
}
