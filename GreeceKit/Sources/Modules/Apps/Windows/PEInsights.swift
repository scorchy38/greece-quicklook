import Foundation

/// What a PE file is made with and what it carries: installer frameworks, self-extracting
/// archives, packers and toolchains, from bounded scans of known markers.
struct PEInsights {
    /// "NSIS", "Inno Setup"…
    var installer: String?
    /// The installer's own words, e.g. "Nullsoft Install System v3.0".
    var installerDetail: String?
    /// The overlay or a resource holds a Windows Installer (.msi) database.
    var containsMSI = false
    /// "7-Zip", "WinRAR", "ZIP" self-extracting archives.
    var selfExtractingArchive: String?
    /// "UPX".
    var packer: String?
    /// "Visual C++ 2015 or later", "Qt 6", "Go"…
    var builtWith: [String] = []

    static let headScan = 4 << 20
    static let overlayScan = 64 * 1024

    init(file: PEFile, version: PEVersionInfo?, manifest: PEManifest?) {
        let data = file.data
        let head = data.prefix(Self.headScan)
        let overlay = file.overlayRange.map { data.subdata(in: $0.lowerBound..<min($0.upperBound, $0.lowerBound + Self.overlayScan)) } ?? Data()
        let tail = data.suffix(4096)
        let sectionNames = Set(file.sections.map(\.name))
        let versionText = (version?.strings.map(\.value) ?? []).joined(separator: "\n")
        let manifestName = manifest?.assemblyName ?? ""
        let manifestDescription = manifest?.assemblyDescription ?? ""

        func contains(_ blob: Data, _ marker: String, wide: Bool = false) -> Bool {
            if blob.firstRange(of: Array(marker.utf8)) != nil { return true }
            guard wide else { return false }
            return blob.firstRange(of: marker.utf8.flatMap { [$0, 0] }) != nil
        }

        // Installer frameworks.
        // NSIS's first header: flags, 0xDEADBEEF, "NullsoftInst", on a 512-byte boundary of the overlay.
        let nsisHeader = overlay.firstRange(of: Array("NullsoftInst".utf8))
        if nsisHeader.map({ $0 >= 4 && BinaryReader(overlay).u32(at: $0 - 4) == 0xDEAD_BEEF }) == true
            || manifestName.hasPrefix("Nullsoft") || (sectionNames.contains(".ndata") && contains(head, "Nullsoft")) {
            installer = "NSIS"
            installerDetail = manifestDescription.contains("Nullsoft") ? manifestDescription : "Nullsoft Install System"
        } else if manifestName.contains("Inno.Setup") || versionText.contains("Inno Setup") || contains(overlay, "Inno Setup Setup Data")
                    || contains(head, "Inno Setup Setup Data") {
            installer = "Inno Setup"
            installerDetail = manifestDescription.contains("Inno") ? manifestDescription : nil
        } else if sectionNames.contains(".wixburn") {
            installer = "WiX Burn"
            installerDetail = "WiX Toolset bootstrapper"
        } else if versionText.contains("InstallShield") || contains(head, "InstallShield", wide: true) {
            installer = "InstallShield"
        } else if versionText.contains("Advanced Installer") || contains(head, "Advanced Installer", wide: true) {
            installer = "Advanced Installer"
        } else if contains(head, "SquirrelSetup") || contains(head, "Squirrel.Windows") || contains(head, "Squirrel", wide: true) && file.resources?.entries.contains(where: { $0.type == .name("DATA") }) == true {
            installer = "Squirrel"
        } else if contains(head, "Setup Factory") {
            installer = "Setup Factory"
        }

        // Archives and databases appended to the executable.
        let olePrefix: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]
        if overlay.firstRange(of: olePrefix) != nil { containsMSI = true }
        if overlay.starts(with: [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]) || overlay.firstRange(of: [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C], limit: 8192) != nil && contains(overlay, ";!@Install@!") {
            selfExtractingArchive = "7-Zip"
        } else if overlay.firstRange(of: Array("Rar!\u{1A}\u{07}".utf8), limit: 8192) != nil {
            selfExtractingArchive = "WinRAR"
        } else if overlay.starts(with: [0x50, 0x4B, 0x03, 0x04]) && installer == nil {
            selfExtractingArchive = "ZIP"
        }
        if sectionNames.contains("UPX0") || sectionNames.contains("UPX1") { packer = "UPX" }

        // Toolchains and frameworks.
        let imports = Set(file.imports.map { $0.name.lowercased() })
        var built: [String] = []
        if let dotNet = file.dotNet { built.append(Self.prettyFramework(dotNet.targetFramework) ?? ".NET") }
        let runtimes: [(String, String)] = [
            ("vcruntime140.dll", "Visual C++ 2015 or later"), ("msvcp140.dll", "Visual C++ 2015 or later"),
            ("msvcr120.dll", "Visual C++ 2013"), ("msvcr110.dll", "Visual C++ 2012"), ("msvcr100.dll", "Visual C++ 2010"),
            ("msvcr90.dll", "Visual C++ 2008"), ("msvcr80.dll", "Visual C++ 2005"), ("msvcr71.dll", "Visual C++ 2003"),
        ]
        if let runtime = runtimes.first(where: { imports.contains($0.0) }) { built.append(runtime.1) }
        if imports.contains(where: { $0.hasPrefix("qt6") }) { built.append("Qt 6") } else if imports.contains(where: { $0.hasPrefix("qt5") }) { built.append("Qt 5") }
        if contains(head, "Go build ID: \"") || contains(head, "\u{FF} Go buildinf:") { built.append("Go") }
        if contains(head, "/rustc/") || contains(head, "\\rustc\\") { built.append("Rust") }
        if sectionNames.contains(".itext") || (sectionNames.contains("CODE") && sectionNames.contains("DATA")) || contains(head, "Embarcadero Delphi") {
            built.append("Delphi")
        }
        if tail.firstRange(of: Array("MEI\u{0C}\u{0B}\u{0A}\u{0B}\u{0E}".utf8)) != nil { built.append("PyInstaller") }
        if imports.contains("libgcc_s_seh-1.dll") || imports.contains("libstdc++-6.dll") || contains(head, "Mingw-w64 runtime failure") { built.append("MinGW") }
        if contains(head, "electron.asar") || versionText.contains("Electron") { built.append("Electron") }
        if imports.contains("python3.dll") || imports.contains(where: { $0.hasPrefix("python3") && $0.hasSuffix(".dll") }) { built.append("Python") }
        var seen = Set<String>()
        builtWith = built.filter { seen.insert($0).inserted }
    }

    /// ".NETCoreApp,Version=v8.0" → ".NET 8.0".
    static func prettyFramework(_ raw: String?) -> String? {
        guard let raw, let range = raw.range(of: ",Version=v") else { return nil }
        let version = String(raw[range.upperBound...].prefix { $0.isNumber || $0 == "." })
        switch raw[..<range.lowerBound] {
        case ".NETCoreApp":
            let major = Int(version.split(separator: ".").first ?? "") ?? 0
            return major >= 5 ? ".NET \(version)" : ".NET Core \(version)"
        case ".NETFramework": return ".NET Framework \(version)"
        case ".NETStandard": return ".NET Standard \(version)"
        default: return nil
        }
    }
}
