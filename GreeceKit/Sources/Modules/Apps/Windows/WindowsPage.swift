import AppKit

/// The inspector page for Windows executables, libraries and drivers.
enum WindowsPage {

    /// "MZ" and a PE header inside the first bytes Quick Look gives modules.
    static func sniff(probe: [UInt8]) -> Bool { PEFile.sniff(probe) }

    static func page(for url: URL, settings: PreviewSettings) throws -> InspectorPage {
        let file = try PEFile(url: url)
        return page(for: file, url: url)
    }

    /// The application's icon, for Finder thumbnails.
    static func icon(for url: URL) -> NSImage? {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped),
              let file = try? PEFile(data: data, resourcesOnly: true) else { return nil }
        return icon(of: file)
    }

    static func icon(of file: PEFile) -> NSImage? {
        guard let ico = file.resources?.iconFile(in: file), let image = NSImage(data: ico), image.isValid,
              !image.representations.isEmpty else { return nil }
        // Prefer the largest image: Explorer's "extra large" icon.
        if let best = image.representations.max(by: { $0.pixelsWide * $0.pixelsHigh < $1.pixelsWide * $1.pixelsHigh }), best.pixelsWide > 0 {
            let largest = NSImage(size: NSSize(width: best.pixelsWide, height: best.pixelsHigh))
            largest.addRepresentation(best)
            return largest
        }
        return image
    }

    // MARK: - Page

    static func page(for file: PEFile, url: URL) -> InspectorPage {
        let version = file.resources?.versionInfo(in: file)
        let manifest = file.resources?.manifest(in: file)
        let insights = PEInsights(file: file, version: version, manifest: manifest)
        let signature = AuthenticodeSignature(file: file)
        let architecture = Self.architecture(file)

        // Header.
        let product = version?["ProductName"].flatMap { $0.contains("Operating System") ? nil : $0 }
        let title = product ?? version?["FileDescription"] ?? url.deletingPathExtension().lastPathComponent
        let shownVersion = version?["ProductVersion"] ?? version?.productVersion ?? version?["FileVersion"] ?? version?.fileVersion
        let header = InspectorHeader(
            icon: icon(of: file).map { .image($0, shape: .asIs) } ?? .symbol(fallbackSymbol(file, insights: insights), .blue),
            title: Format.clean(title, limit: 120),
            subtitle: Format.joined([Format.version(shownVersion, build: nil), version?["CompanyName"]]).nilIfEmpty,
            identifier: version?["OriginalFilename"] ?? version?["InternalName"])

        // Badges.
        var badges: [InspectorBadge] = [InspectorBadge("architecture", symbol: "cpu", title: architecture.badge, help: architecture.help)]
        if let signature, let signer = signature.signer {
            badges.append(InspectorBadge("signer", symbol: "checkmark.seal", title: "Signed", tone: .positive,
                                         help: "Authenticode signed by \(signer.organization ?? signer.commonName). Greece can’t confirm that Windows trusts this certificate."))
        } else {
            badges.append(InspectorBadge("signer", symbol: "xmark.seal", title: "Unsigned", tone: .caution,
                                         help: "Not Authenticode signed. Windows SmartScreen warns before running unsigned downloads."))
        }
        if let installer = insights.installer {
            badges.append(InspectorBadge("installer", symbol: "shippingbox", title: "\(installer) Installer", tone: .accent,
                                         help: "An installer built with \(installer). It unpacks and runs more code than this file shows."))
        } else if let archive = insights.selfExtractingArchive {
            badges.append(InspectorBadge("installer", symbol: "doc.zipper", title: "\(archive) Self-Extractor", tone: .accent,
                                         help: "A program that unpacks a \(archive) archive appended to it."))
        }
        if file.dotNet != nil {
            badges.append(InspectorBadge("dotnet", symbol: "curlybraces", title: ".NET", tone: .accent, help: "A .NET assembly: managed code run by the .NET runtime."))
        }
        if manifest?.requiresAdministrator == true {
            badges.append(InspectorBadge("elevation", symbol: "lock.shield", title: "Requires Administrator", tone: .caution,
                                         help: "Windows asks for administrator permission every time it starts."))
        }
        if let packer = insights.packer {
            badges.append(InspectorBadge("packer", symbol: "archivebox", title: "\(packer) Packed", tone: .caution,
                                         help: "Compressed with \(packer): its real code is only visible once it runs."))
        }

        var sections: [InspectorSection] = []
        var checks: [InspectorCheck] = []
        let (signatureSection, integrityCheck) = signatureSection(signature, file: file)
        sections.append(signatureSection)
        if let integrityCheck { checks.append(integrityCheck) }
        if let section = installerSection(insights, file: file) { sections.append(section) }
        sections.append(securitySection(file))
        if let section = importsSection(file) { sections.append(section) }
        if let section = exportsSection(file) { sections.append(section) }
        if let section = dotNetSection(file) { sections.append(section) }
        if let manifest { sections.append(manifestSection(manifest)) }
        if let version, let section = versionSection(version) { sections.append(section) }
        if let section = sectionsSection(file) { sections.append(section) }
        sections.append(infoSection(file, url: url, insights: insights, architecture: architecture))

        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let summary = FileSummary(symbol: "macwindow", title: kindTitle(file, insights: insights),
                                  details: [architecture.short, Format.version(shownVersion, build: nil), Format.bytes(file.fileSize)].compactMap { $0 },
                                  trailing: modified.map(PreviewFactory.modifiedText))
        return InspectorPage(header: header, badges: badges, sections: sections, contents: nil, summary: summary, checks: checks)
    }

    // MARK: - Signature

    private static func signatureSection(_ signature: AuthenticodeSignature?, file: PEFile) -> (InspectorSection, InspectorCheck?) {
        guard let signature, let signer = signature.signer else {
            let row = InspectorItem(symbol: "xmark.seal", title: "Not signed",
                                    subtitle: "There’s no Authenticode signature, so nothing says who made this file or whether it changed since.",
                                    tone: .caution)
            return (InspectorSection("signature", title: "Signature", rows: [.item(row)]), nil)
        }
        var rows: [InspectorRow] = []
        rows.append(.item(.field("Signed By", signer.organization ?? signer.commonName)))
        if let time = signature.signingTime { rows.append(.item(.field("Signed", Format.dateTime(time)))) }
        if let algorithm = signature.digestAlgorithm {
            let weak = algorithm == .md5 || algorithm == .sha1
            rows.append(.item(.field("Digest", algorithm.rawValue + (signature.nestedSignatures > 0 ? " · dual-signed" : ""),
                                     tone: weak && signature.nestedSignatures == 0 ? .caution : .neutral,
                                     help: weak ? "\(algorithm.rawValue) is no longer considered secure for signatures." : nil)))
        }
        rows.append(.pending(id: "windows.integrity", title: "Checking the file against its signature…"))
        // A timestamped signature outlives its certificate: an expired leaf is expected, not alarming.
        let chain = CertificateRows.chain(signature.chain).enumerated().map { index, row -> InspectorItem in
            var item = row
            let certificate = signature.chain[index]
            if let end = certificate.notAfter, end < Date(), let time = signature.signingTime, time <= end,
               certificate.notBefore.map({ time >= $0 }) ?? true {
                item.tone = .neutral
                item.subtitle = (item.subtitle.map { $0 + " · " } ?? "") + "valid when signed"
                item.details = item.details.map { detail in
                    var detail = detail
                    if detail.title == "Valid Until" { detail.tone = .neutral }
                    return detail
                }
            }
            return item
        }
        rows += .items(chain)
        if let authority = signature.timestampAuthority, var item = CertificateRows.chain([authority]).first {
            item.symbol = "clock"
            item.value = "Timestamp"
            item.tone = .neutral
            item.subtitle = signature.signingTime.map { "Countersigned " + Format.dateTime($0) } ?? item.subtitle
            rows.append(.item(item))
        }

        let check = InspectorCheck(id: "windows.integrity") {
            switch signature.integrity(of: file) {
            case .matches:
                return InspectorCheckResult(rows: [.item(InspectorItem(symbol: "checkmark.shield", title: "Unchanged since signing",
                                                                       subtitle: "The file matches the digest recorded in its signature.", tone: .positive))])
            case .modified:
                return InspectorCheckResult(
                    rows: [.item(InspectorItem(symbol: "exclamationmark.triangle", title: "Modified after signing",
                                               subtitle: "The file no longer matches the digest recorded in its signature. Windows treats it as unsigned.",
                                               tone: .critical))],
                    badges: [InspectorBadge("integrity", symbol: "exclamationmark.triangle", title: "Modified After Signing", tone: .critical,
                                            help: "The file changed after it was signed.")])
            case .notChecked(let reason):
                return InspectorCheckResult(rows: [.item(InspectorItem(symbol: "questionmark.circle", title: "Integrity not checked", subtitle: reason))])
            }
        }
        let section = InspectorSection("signature", title: "Signature",
                                       footer: "Windows checks these certificates against its own trust store. Greece shows who signed the file but can’t confirm that Windows trusts them.",
                                       rows: rows)
        return (section, check)
    }

    // MARK: - Installer

    private static func installerSection(_ insights: PEInsights, file: PEFile) -> InspectorSection? {
        var rows: [InspectorItem] = []
        let payload = file.overlayRange.map { Format.bytes($0.count) }
        if let installer = insights.installer {
            rows.append(InspectorItem(symbol: "shippingbox", tint: .orange, title: "\(installer) installer", subtitle: insights.installerDetail,
                                      value: payload, help: payload.map { "\($0) of installer data follows the program" }))
        }
        if let archive = insights.selfExtractingArchive {
            rows.append(InspectorItem(symbol: "doc.zipper", tint: .brown, title: "\(archive) self-extracting archive",
                                      value: insights.installer == nil ? payload : nil))
        }
        if insights.containsMSI {
            rows.append(InspectorItem(symbol: "shippingbox.fill", tint: .blue, title: "Contains a Windows Installer package",
                                      subtitle: "An .msi database is embedded in the file."))
        }
        guard !rows.isEmpty else { return nil }
        return InspectorSection("installer", title: "Installer",
                                footer: "Installers unpack and run more code than this file shows, usually with administrator rights.",
                                rows: .items(rows))
    }

    // MARK: - Security features

    private static func securitySection(_ file: PEFile) -> InspectorSection {
        let flags = file.dllCharacteristics
        let managed = file.dotNet?.isILOnly == true
        func feature(_ title: String, _ on: Bool, _ raw: String, subtitle: String? = nil) -> InspectorRow {
            .item(InspectorItem(symbol: on ? "checkmark.circle.fill" : "circle", title: title, subtitle: subtitle, value: on ? "On" : "Off",
                                tone: on ? .positive : .neutral, help: raw))
        }
        var rows: [InspectorRow] = []
        let aslr = flags & 0x40 != 0
        rows.append(feature("Randomized memory layout (ASLR)", aslr && !file.hasRelocationsStripped, "IMAGE_DLLCHARACTERISTICS_DYNAMIC_BASE",
                            subtitle: aslr && file.hasRelocationsStripped ? "Requested, but relocations were stripped, so Windows can’t move it." : nil))
        if file.is64Bit { rows.append(feature("High-entropy ASLR", flags & 0x20 != 0, "IMAGE_DLLCHARACTERISTICS_HIGH_ENTROPY_VA")) }
        rows.append(feature("Non-executable data (DEP)", flags & 0x100 != 0, "IMAGE_DLLCHARACTERISTICS_NX_COMPAT"))
        if !managed {
            rows.append(feature("Control Flow Guard", flags & 0x4000 != 0, "IMAGE_DLLCHARACTERISTICS_GUARD_CF"))
            if let config = file.loadConfig { rows.append(feature("Stack buffer checks (/GS)", config.hasSecurityCookie, "Load configuration security cookie")) }
            if file.machine == 0x14C {
                let safe = flags & 0x400 != 0 || (file.loadConfig?.safeExceptionHandlers ?? 0) > 0
                rows.append(feature("Safe exception handlers", safe, flags & 0x400 != 0 ? "IMAGE_DLLCHARACTERISTICS_NO_SEH" : "SafeSEH handler table",
                                    subtitle: flags & 0x400 != 0 ? "Uses no structured exception handlers." : nil))
            }
            rows.append(feature("Shadow stack (CET)", file.debug.isCETCompatible, "IMAGE_DLLCHARACTERISTICS_EX_CET_COMPAT"))
        }
        if flags & 0x80 != 0 { rows.append(feature("Requires a valid signature to load", true, "IMAGE_DLLCHARACTERISTICS_FORCE_INTEGRITY")) }
        if flags & 0x1000 != 0 { rows.append(feature("Runs in an app container", true, "IMAGE_DLLCHARACTERISTICS_APPCONTAINER")) }
        return InspectorSection("security", title: "Security Features",
                                footer: "Protections from the compiler and the Windows loader that make memory-corruption bugs harder to exploit.",
                                rows: rows)
    }

    // MARK: - Imports and exports

    static let systemLibraries: [String: String] = [
        "kernel32.dll": "Core Windows services", "kernelbase.dll": "Core Windows services", "ntdll.dll": "Native Windows API",
        "user32.dll": "Windows and input", "gdi32.dll": "Graphics", "gdiplus.dll": "Graphics (GDI+)",
        "advapi32.dll": "Registry, services and security", "shell32.dll": "Windows shell", "shlwapi.dll": "Shell utilities",
        "ole32.dll": "COM", "oleaut32.dll": "COM automation", "combase.dll": "COM", "comctl32.dll": "Common controls",
        "comdlg32.dll": "Common dialogs", "ws2_32.dll": "Sockets", "wsock32.dll": "Sockets", "wininet.dll": "Internet access",
        "winhttp.dll": "HTTP", "urlmon.dll": "URL downloads", "dnsapi.dll": "DNS", "iphlpapi.dll": "Network configuration",
        "netapi32.dll": "Network management", "mpr.dll": "Network drives", "crypt32.dll": "Certificates and cryptography",
        "bcrypt.dll": "Cryptography", "ncrypt.dll": "Key storage", "wintrust.dll": "Signature verification",
        "secur32.dll": "Authentication", "sspicli.dll": "Authentication", "credui.dll": "Credential prompts",
        "msvcrt.dll": "C runtime", "ucrtbase.dll": "C runtime", "vcruntime140.dll": "Visual C++ runtime",
        "vcruntime140_1.dll": "Visual C++ runtime", "msvcp140.dll": "Visual C++ standard library", "version.dll": "Version information",
        "winmm.dll": "Multimedia", "avrt.dll": "Multimedia scheduling", "dsound.dll": "DirectSound", "xinput1_4.dll": "Game controllers",
        "d3d9.dll": "Direct3D 9", "d3d11.dll": "Direct3D 11", "d3d12.dll": "Direct3D 12", "dxgi.dll": "DirectX graphics",
        "opengl32.dll": "OpenGL", "dwmapi.dll": "Desktop composition", "uxtheme.dll": "Visual styles", "imm32.dll": "Input methods",
        "userenv.dll": "User profiles", "psapi.dll": "Process information", "dbghelp.dll": "Debugging", "rpcrt4.dll": "Remote procedure calls",
        "setupapi.dll": "Device installation", "cfgmgr32.dll": "Device configuration", "hid.dll": "Input devices",
        "wtsapi32.dll": "Remote desktop sessions", "powrprof.dll": "Power management", "msi.dll": "Windows Installer",
        "mscoree.dll": ".NET runtime", "shcore.dll": "Display scaling", "propsys.dll": "Property system", "winspool.drv": "Printing",
        "normaliz.dll": "Unicode normalization", "wldap32.dll": "LDAP directory", "netutils.dll": "Network utilities",
        "ntoskrnl.exe": "Windows kernel", "hal.dll": "Hardware abstraction layer", "fltmgr.sys": "File system filters",
    ]

    static func libraryDescription(_ name: String) -> (description: String?, isSystem: Bool) {
        let lower = name.lowercased()
        if let known = systemLibraries[lower] { return (known, true) }
        if lower.hasPrefix("api-ms-win-") || lower.hasPrefix("ext-ms-win-") {
            return (lower.contains("-crt-") ? "C runtime" : "Windows API set", true)
        }
        return (nil, false)
    }

    private static func importsSection(_ file: PEFile) -> InspectorSection? {
        guard !file.imports.isEmpty else { return nil }
        let rows: [InspectorItem] = file.imports.prefix(500).map { library in
            let (description, isSystem) = libraryDescription(library.name)
            var details = library.functions.prefix(40).map { InspectorItem(title: $0) }
            if library.functionCount > details.count {
                details.append(InspectorItem(title: "and \((library.functionCount - details.count).formatted()) more", tone: .neutral))
            }
            return InspectorItem(symbol: isSystem ? "macwindow" : "puzzlepiece.extension", title: library.name,
                                 subtitle: Format.joined([description, library.isDelayLoaded ? "Loaded on first use" : nil]).nilIfEmpty,
                                 value: Format.count(library.functionCount, "function"),
                                 help: isSystem ? "Part of Windows" : "Ships with the app or must already be installed",
                                 details: details)
        }
        let total = file.imports.reduce(0) { $0 + $1.functionCount }
        let thirdParty = file.imports.filter { !libraryDescription($0.name).isSystem }.count
        return InspectorSection("imports", title: "Imported Libraries",
                                footer: Format.joined([Format.count(total, "function") + " from " + Format.count(file.imports.count, "library", "libraries"),
                                                       thirdParty > 0 ? "\(thirdParty) not part of Windows" : nil]),
                                rows: .items(rows), visibleLimit: 8)
    }

    private static func exportsSection(_ file: PEFile) -> InspectorSection? {
        guard let exports = file.exports, exports.functionCount > 0 || !exports.names.isEmpty else { return nil }
        var rows: [InspectorItem] = []
        if let name = exports.libraryName { rows.append(.field("Library Name", name, mono: true)) }
        rows.append(.field("Exported Functions", exports.functionCount.formatted()))
        if exports.nameCount < exports.functionCount { rows.append(.field("Exported by Ordinal Only", (exports.functionCount - exports.nameCount).formatted())) }
        rows += exports.names.prefix(200).map { InspectorItem(symbol: "function", title: $0) }
        return InspectorSection("exports", title: "Exports", rows: .items(rows), visibleLimit: 12)
    }

    // MARK: - .NET

    private static func dotNetSection(_ file: PEFile) -> InspectorSection? {
        guard let dotNet = file.dotNet else { return nil }
        var rows: [InspectorItem] = []
        if let framework = PEInsights.prettyFramework(dotNet.targetFramework) {
            rows.append(.field("Target Framework", framework, help: dotNet.targetFramework))
        }
        if let metadata = dotNet.metadataVersion { rows.append(.field("Runtime Version", metadata, mono: true)) }
        rows.append(.field("Code", dotNet.isILOnly ? "Managed only" : "Managed and native"))
        if dotNet.requires32Bit { rows.append(.field("32-bit", "Required")) } else if dotNet.prefers32Bit { rows.append(.field("32-bit", "Preferred")) }
        rows.append(.field("Strong-Name Signed", dotNet.isStrongNameSigned ? "Yes" : "No"))
        return InspectorSection("dotnet", title: ".NET", rows: .items(rows))
    }

    // MARK: - Manifest

    private static func manifestSection(_ manifest: PEManifest) -> InspectorSection {
        var rows: [InspectorRow] = []
        if let level = manifest.executionLevel {
            switch level {
            case "requireAdministrator":
                rows.append(.item(InspectorItem(symbol: "lock.shield", title: "Runs as administrator", subtitle: "Windows asks for permission every time it starts.",
                                                tone: .caution, help: "requestedExecutionLevel = requireAdministrator")))
            case "highestAvailable":
                rows.append(.item(InspectorItem(symbol: "person.badge.shield.checkmark", title: "Runs with the highest available rights",
                                                subtitle: "Administrators are asked for permission; other users run it normally.",
                                                help: "requestedExecutionLevel = highestAvailable")))
            default:
                rows.append(.item(InspectorItem(symbol: "person", title: "Runs as the current user", help: "requestedExecutionLevel = \(level)")))
            }
        }
        if manifest.uiAccess {
            rows.append(.item(InspectorItem(symbol: "hand.raised", title: "Can control other apps’ windows", subtitle: "UI Access bypasses window isolation.",
                                            tone: .caution, help: "uiAccess = true")))
        }
        if !manifest.supportedOS.isEmpty { rows.append(.item(.field("Supports", manifest.supportedOS.joined(separator: ", ")))) }
        if let dpi = manifest.dpiAware { rows.append(.item(.field("DPI Awareness", dpi))) }
        if manifest.longPathAware { rows.append(.item(.field("Long Paths", "Supported"))) }
        let lines = manifest.text.split(separator: "\n", omittingEmptySubsequences: false).count
        rows.append(.code(InspectorCode(symbol: "doc.text", title: "Manifest", subtitle: Format.count(lines, "line"),
                                        text: manifest.text, grammar: "xml")))
        return InspectorSection("manifest", title: "Manifest", rows: rows)
    }

    // MARK: - Version info

    static let versionLabels: [(String, String)] = [
        ("CompanyName", "Company"), ("ProductName", "Product"), ("FileDescription", "Description"),
        ("ProductVersion", "Product Version"), ("FileVersion", "File Version"), ("LegalCopyright", "Copyright"),
        ("LegalTrademarks", "Trademarks"), ("OriginalFilename", "Original File Name"), ("InternalName", "Internal Name"),
        ("Comments", "Comments"), ("PrivateBuild", "Private Build"), ("SpecialBuild", "Special Build"),
    ]

    private static func versionSection(_ version: PEVersionInfo) -> InspectorSection? {
        var rows: [InspectorItem] = []
        var used = Set<String>()
        for (key, label) in versionLabels {
            guard let value = version[key] else { continue }
            used.insert(key)
            rows.append(.field(label, value, mono: key == "OriginalFilename" || key == "InternalName", help: key))
        }
        for (key, value) in version.strings where !used.contains(key) { rows.append(.field(key, value)) }
        if version["FileVersion"] == nil, let fixed = version.fileVersion { rows.append(.field("File Version", fixed)) }
        let languages = Set(version.languages)
        if languages.count > 1 {
            rows.append(.field("Languages", languages.count.formatted(),
                               help: languages.sorted().prefix(40).compactMap(languageName).joined(separator: ", ")))
        } else if let language = languages.first, let name = languageName(language) {
            rows.append(.field("Language", name))
        }
        let flags = [version.isDebugBuild ? "Debug" : nil, version.isPrerelease ? "Pre-release" : nil,
                     version.isPrivateBuild ? "Private" : nil, version.isPatched ? "Patched" : nil].compactMap { $0 }
        if !flags.isEmpty { rows.append(.field("Build", flags.joined(separator: ", "), tone: version.isDebugBuild ? .caution : .neutral)) }
        guard !rows.isEmpty else { return nil }
        return InspectorSection("version", title: "Version Info", rows: .items(rows))
    }

    static func languageName(_ code: UInt16) -> String? {
        guard code != 0 else { return "Neutral" }
        let identifier = Locale.identifier(fromWindowsLocaleCode: Int(code))
        return identifier.flatMap { Locale.current.localizedString(forIdentifier: $0) }
    }

    // MARK: - Sections

    private static func sectionsSection(_ file: PEFile) -> InspectorSection? {
        guard !file.sections.isEmpty else { return nil }
        let names: [String: String] = [
            ".text": "Code", ".rdata": "Read-only data", ".data": "Data", ".bss": "Uninitialized data", ".rsrc": "Resources",
            ".reloc": "Relocations", ".pdata": "Exception data", ".idata": "Imports", ".edata": "Exports", ".tls": "Thread-local storage",
            ".CRT": "C runtime data", ".ndata": "Installer data", ".didat": "Delay-load imports", ".gfids": "Control Flow Guard data",
            "UPX0": "UPX (unpacked at launch)", "UPX1": "UPX packed code", ".wixburn": "WiX Burn data", ".itext": "Delphi code",
        ]
        let rows: [InspectorItem] = file.sections.prefix(96).map { section in
            let writableCode = section.isExecutable && section.isWritable
            var kind = names[section.name] ?? (section.isCode || section.isExecutable ? "Code" : section.hasUninitializedData ? "Uninitialized data"
                                                : section.isWritable ? "Data" : "Read-only data")
            if writableCode { kind = "Writable and executable" }
            let packed = (section.entropy ?? 0) > 7.2
            var help = "Virtual size \(Format.bytes(Int(section.virtualSize))) at 0x\(String(section.virtualAddress, radix: 16, uppercase: true))"
            if let entropy = section.entropy { help += String(format: " · Entropy %.2f", entropy) }
            let stored = section.rawSize > 0
            return InspectorItem(title: section.name.isEmpty ? "(unnamed)" : section.name,
                                 subtitle: Format.joined([kind, packed ? "compressed or encrypted" : nil, stored ? nil : "allocated at launch"]),
                                 value: Format.bytes(Int(stored ? section.rawSize : section.virtualSize)),
                                 tone: writableCode ? .caution : .neutral, help: help)
        }
        return InspectorSection("sections", title: "Sections", rows: .items(rows), visibleLimit: 8)
    }

    // MARK: - Info

    private static func infoSection(_ file: PEFile, url: URL, insights: PEInsights, architecture: Architecture) -> InspectorSection {
        var rows: [InspectorItem] = []
        rows.append(.field("Kind", kindDescription(file)))
        rows.append(.field("Architecture", architecture.long))
        rows.append(.field("Subsystem", subsystemName(file.subsystem)))
        if !file.isEFI, let minimum = minimumWindows(file.subsystemVersion) { rows.append(.field("Minimum Windows", minimum)) }
        if !insights.builtWith.isEmpty { rows.append(.field("Built With", insights.builtWith.joined(separator: ", "))) }
        rows.append(buildTime(file))
        rows.append(.field("Linker", file.linkerVersion))
        rows.append(.field("Entry Point", "0x" + String(file.entryPoint, radix: 16, uppercase: true), mono: true))
        rows.append(.field("Image Base", "0x" + String(file.imageBase, radix: 16, uppercase: true), mono: true))
        rows.append(.field("Image Size", Format.bytes(Int(file.imageSize))))
        if let pdb = file.debug.pdbPath {
            let name = pdb.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last.map(String.init) ?? pdb
            rows.append(.field("Debug Symbols", name, mono: true, help: pdb))
            if let guid = file.debug.pdbGUID {
                rows.append(.field("Symbols ID", guid + (file.debug.pdbAge.map { " · \($0)" } ?? ""), mono: true, help: "PDB GUID and age"))
            }
        }
        if let census = file.resources?.census, !census.isEmpty {
            rows.append(.field("Resources", census.map { "\($0.1.formatted()) \($0.0)" }.joined(separator: ", ")))
        }
        if let overlay = file.overlayRange, overlay.count > 0 {
            rows.append(.field("Appended Data", Format.bytes(overlay.count), help: "Data after the last section, where installers keep their payload"))
        }
        rows.append(.field("File Size", Format.bytes(file.fileSize)))
        return InspectorSection("info", title: "Info", rows: .items(rows))
    }

    private static func buildTime(_ file: PEFile) -> InspectorItem {
        if file.timestamp == 0 { return .field("Built", "Not recorded") }
        let date = Date(timeIntervalSince1970: TimeInterval(file.timestamp))
        let plausible = file.timestamp > 631_152_000 && date < Date().addingTimeInterval(86_400 * 2)
        if file.debug.isReproducible || !plausible {
            return .field("Built", "Reproducible build", help: String(format: "Timestamp field 0x%08X is a content hash, not a date", file.timestamp))
        }
        return .field("Built", Format.dateTime(date))
    }

    // MARK: - Names

    struct Architecture {
        let badge: String
        let short: String
        let long: String
        let help: String?
    }

    static func architecture(_ file: PEFile) -> Architecture {
        let hybrid = file.loadConfig?.hasHybridMetadata == true
        switch file.machine {
        case 0x8664 where hybrid: return Architecture(badge: "ARM64EC", short: "ARM64EC", long: "ARM64EC (x64-compatible ARM64)", help: "ARM64 code that interoperates with x64 code on Windows on ARM.")
        case 0x8664: return Architecture(badge: "x64", short: "x64", long: "x64 (64-bit Intel and AMD)", help: "Runs on 64-bit Intel and AMD PCs, and on ARM PCs through emulation.")
        case 0xAA64 where hybrid: return Architecture(badge: "ARM64X", short: "ARM64X", long: "ARM64X (ARM64 and ARM64EC)", help: "Contains both native ARM64 and x64-compatible code.")
        case 0xAA64: return Architecture(badge: "ARM64", short: "ARM64", long: "ARM64", help: "Runs natively on Windows on ARM.")
        case 0xA641: return Architecture(badge: "ARM64EC", short: "ARM64EC", long: "ARM64EC (x64-compatible ARM64)", help: nil)
        case 0xA64E: return Architecture(badge: "ARM64X", short: "ARM64X", long: "ARM64X (ARM64 and ARM64EC)", help: nil)
        case 0x14C: return Architecture(badge: "x86 (32-bit)", short: "x86", long: "x86 (32-bit Intel)", help: "A 32-bit program. 64-bit Windows runs it through WOW64.")
        case 0x1C0, 0x1C2, 0x1C4: return Architecture(badge: "ARM (32-bit)", short: "ARM", long: "ARM (32-bit)", help: nil)
        case 0x200: return Architecture(badge: "Itanium", short: "IA-64", long: "Itanium (IA-64)", help: nil)
        case 0xEBC: return Architecture(badge: "EFI Byte Code", short: "EBC", long: "EFI Byte Code", help: nil)
        case 0x5064: return Architecture(badge: "RISC-V", short: "RISC-V 64", long: "RISC-V (64-bit)", help: nil)
        case 0x5032: return Architecture(badge: "RISC-V", short: "RISC-V 32", long: "RISC-V (32-bit)", help: nil)
        case 0x6264: return Architecture(badge: "LoongArch", short: "LoongArch64", long: "LoongArch (64-bit)", help: nil)
        case 0: return Architecture(badge: "Any CPU", short: "Any CPU", long: "Unspecified", help: nil)
        default:
            let hex = String(format: "0x%04X", file.machine)
            return Architecture(badge: hex, short: hex, long: "Machine type \(hex)", help: nil)
        }
    }

    static func subsystemName(_ value: UInt16) -> String {
        switch value {
        case 1: return "Native (driver or boot program)"
        case 2: return "Windows GUI"
        case 3: return "Console"
        case 5: return "OS/2 console"
        case 7: return "POSIX console"
        case 9: return "Windows CE GUI"
        case 10: return "EFI application"
        case 11: return "EFI boot service driver"
        case 12: return "EFI runtime driver"
        case 13: return "EFI ROM"
        case 14: return "Xbox"
        case 16: return "Windows boot application"
        default: return "Unknown (\(value))"
        }
    }

    static func minimumWindows(_ version: (major: UInt16, minor: UInt16)) -> String? {
        switch (version.major, version.minor) {
        case (3, _): return "Windows NT 3.1"
        case (4, _): return "Windows 95 or NT 4.0"
        case (5, 0): return "Windows 2000"
        case (5, 1): return "Windows XP"
        case (5, 2): return "Windows XP x64 or Server 2003"
        case (6, 0): return "Windows Vista"
        case (6, 1): return "Windows 7"
        case (6, 2): return "Windows 8"
        case (6, 3): return "Windows 8.1"
        case (10, _): return "Windows 10"
        default: return nil
        }
    }

    static func kindDescription(_ file: PEFile) -> String {
        if file.isEFI { return file.subsystem == 10 ? "EFI application" : "EFI driver" }
        if file.isDriver { return "Driver" }
        if file.isDLL { return file.dotNet != nil ? ".NET library" : "Library (DLL)" }
        if file.subsystem == 3 { return "Command-line program" }
        return "Application"
    }

    static func kindTitle(_ file: PEFile, insights: PEInsights) -> String {
        if file.isEFI { return file.subsystem == 10 ? "EFI Application" : "EFI Driver" }
        if file.isDriver { return "Windows Driver" }
        if file.isDLL { return "Windows Library" }
        if insights.installer != nil { return "Windows Installer" }
        if file.subsystem == 3 { return "Windows Command-Line Tool" }
        return "Windows App"
    }

    private static func fallbackSymbol(_ file: PEFile, insights: PEInsights) -> String {
        if file.isEFI || file.isDriver { return "cpu" }
        if file.isDLL { return "puzzlepiece.extension" }
        if insights.installer != nil { return "shippingbox" }
        if file.subsystem == 3 { return "terminal" }
        return "macwindow"
    }
}
