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
            let name = signer.organization ?? signer.commonName
            badges.append(InspectorBadge("signer", symbol: "checkmark.seal", title: String(localized: "Signed", bundle: .greeceKit, comment: "Badge"), tone: .positive,
                                         help: String(localized: "Authenticode signed by \(name). Greece can’t confirm that Windows trusts this certificate.", bundle: .greeceKit,
                                                      comment: "Badge tooltip. The argument is the signer’s organization or name")))
        } else {
            badges.append(InspectorBadge("signer", symbol: "xmark.seal", title: String(localized: "Unsigned", bundle: .greeceKit, comment: "Badge"), tone: .caution,
                                         help: String(localized: "Not Authenticode signed. Windows SmartScreen warns before running unsigned downloads.", bundle: .greeceKit)))
        }
        if let installer = insights.installer {
            badges.append(InspectorBadge("installer", symbol: "shippingbox",
                                         title: String(localized: "\(installer) Installer", bundle: .greeceKit,
                                                       comment: "Badge. The argument names an installer toolkit, such as “NSIS” or “Inno Setup”"),
                                         tone: .accent,
                                         help: String(localized: "An installer built with \(installer). It unpacks and runs more code than this file shows.", bundle: .greeceKit,
                                                      comment: "Badge tooltip. The argument names an installer toolkit, such as “NSIS”")))
        } else if let archive = insights.selfExtractingArchive {
            badges.append(InspectorBadge("installer", symbol: "doc.zipper",
                                         title: String(localized: "\(archive) Self-Extractor", bundle: .greeceKit,
                                                       comment: "Badge. The argument names an archive format, such as “7-Zip” or “ZIP”"),
                                         tone: .accent,
                                         help: String(localized: "A program that unpacks a \(archive) archive appended to it.", bundle: .greeceKit,
                                                      comment: "Badge tooltip. The argument names an archive format, such as “7-Zip”")))
        }
        if file.dotNet != nil {
            badges.append(InspectorBadge("dotnet", symbol: "curlybraces", title: ".NET", tone: .accent,
                                         help: String(localized: "A .NET assembly: managed code run by the .NET runtime.", bundle: .greeceKit)))
        }
        if manifest?.requiresAdministrator == true {
            badges.append(InspectorBadge("elevation", symbol: "lock.shield", title: String(localized: "Requires Administrator", bundle: .greeceKit, comment: "Badge on a Windows program"),
                                         tone: .caution,
                                         help: String(localized: "Windows asks for administrator permission every time it starts.", bundle: .greeceKit)))
        }
        if let packer = insights.packer {
            badges.append(InspectorBadge("packer", symbol: "archivebox",
                                         title: String(localized: "\(packer) Packed", bundle: .greeceKit, comment: "Badge. The argument names an executable packer, such as “UPX”"),
                                         tone: .caution,
                                         help: String(localized: "Compressed with \(packer): its real code is only visible once it runs.", bundle: .greeceKit,
                                                      comment: "Badge tooltip. The argument names an executable packer, such as “UPX”")))
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
        let title = String(localized: "Signature", bundle: .greeceKit, comment: "Section title")
        guard let signature, let signer = signature.signer else {
            let row = InspectorItem(symbol: "xmark.seal", title: String(localized: "Not signed", bundle: .greeceKit),
                                    subtitle: String(localized: "There’s no Authenticode signature, so nothing says who made this file or whether it changed since.", bundle: .greeceKit),
                                    tone: .caution)
            return (InspectorSection("signature", title: title, rows: [.item(row)]), nil)
        }
        var rows: [InspectorRow] = []
        rows.append(.item(.field(String(localized: "Signed By", bundle: .greeceKit, comment: "Inspector row title; its value is who signed the file"),
                                 signer.organization ?? signer.commonName)))
        if let time = signature.signingTime {
            rows.append(.item(.field(String(localized: "Signed [date]", defaultValue: "Signed", bundle: .greeceKit,
                                            comment: "Inspector row title; its value is the date and time the file was signed"),
                                     Format.dateTime(time))))
        }
        if let algorithm = signature.digestAlgorithm {
            let weak = algorithm == .md5 || algorithm == .sha1
            let dualSigned = signature.nestedSignatures > 0
                ? String(localized: "dual-signed", bundle: .greeceKit, comment: "After a digest algorithm, such as “SHA-256 · dual-signed”: the file carries a second signature") : nil
            rows.append(.item(.field(String(localized: "Digest", bundle: .greeceKit, comment: "Inspector row title; its value is a hash algorithm, such as SHA-256"),
                                     Format.joined([algorithm.rawValue, dualSigned]),
                                     tone: weak && signature.nestedSignatures == 0 ? .caution : .neutral,
                                     help: weak ? String(localized: "\(algorithm.rawValue) is no longer considered secure for signatures.", bundle: .greeceKit,
                                                         comment: "Tooltip. The argument is a hash algorithm, such as “SHA-1”") : nil)))
        }
        rows.append(.pending(id: "windows.integrity", title: String(localized: "Checking the file against its signature…", bundle: .greeceKit)))
        // A timestamped signature outlives its certificate: an expired leaf is expected, not alarming.
        let chain = CertificateRows.chain(signature.chain).enumerated().map { index, row -> InspectorItem in
            var item = row
            let certificate = signature.chain[index]
            if let end = certificate.notAfter, end < Date(), let time = signature.signingTime, time <= end,
               certificate.notBefore.map({ time >= $0 }) ?? true {
                item.tone = .neutral
                item.subtitle = Format.joined([item.subtitle,
                                               String(localized: "valid when signed", bundle: .greeceKit,
                                                      comment: "After a certificate’s expiry, such as “Expired 2 years ago · valid when signed”")])
                item.details = item.details.map { detail in
                    var detail = detail
                    // Only the expiry date is marked critical among a certificate's details.
                    if detail.tone == .critical { detail.tone = .neutral }
                    return detail
                }
            }
            return item
        }
        rows += .items(chain)
        if let authority = signature.timestampAuthority, var item = CertificateRows.chain([authority]).first {
            item.symbol = "clock"
            item.value = String(localized: "Timestamp", bundle: .greeceKit, comment: "Role of a certificate: the service that timestamped the signature")
            item.tone = .neutral
            item.subtitle = signature.signingTime.map { time in
                let date = Format.dateTime(time)
                return String(localized: "Countersigned \(date)", bundle: .greeceKit, comment: "The argument is a date and time")
            } ?? item.subtitle
            rows.append(.item(item))
        }

        let check = InspectorCheck(id: "windows.integrity") {
            switch signature.integrity(of: file) {
            case .matches:
                return InspectorCheckResult(rows: [.item(InspectorItem(symbol: "checkmark.shield", title: String(localized: "Unchanged since signing", bundle: .greeceKit),
                                                                       subtitle: String(localized: "The file matches the digest recorded in its signature.", bundle: .greeceKit),
                                                                       tone: .positive))])
            case .modified:
                return InspectorCheckResult(
                    rows: [.item(InspectorItem(symbol: "exclamationmark.triangle", title: String(localized: "Modified after signing", bundle: .greeceKit),
                                               subtitle: String(localized: "The file no longer matches the digest recorded in its signature. Windows treats it as unsigned.", bundle: .greeceKit),
                                               tone: .critical))],
                    badges: [InspectorBadge("integrity", symbol: "exclamationmark.triangle",
                                            title: String(localized: "Modified After Signing", bundle: .greeceKit, comment: "Badge"), tone: .critical,
                                            help: String(localized: "The file changed after it was signed.", bundle: .greeceKit))])
            case .notChecked(let reason):
                return InspectorCheckResult(rows: [.item(InspectorItem(symbol: "questionmark.circle", title: String(localized: "Integrity not checked", bundle: .greeceKit),
                                                                       subtitle: reason))])
            }
        }
        let section = InspectorSection("signature", title: title,
                                       footer: String(localized: "Windows checks these certificates against its own trust store. Greece shows who signed the file but can’t confirm that Windows trusts them.", bundle: .greeceKit),
                                       rows: rows)
        return (section, check)
    }

    // MARK: - Installer

    private static func installerSection(_ insights: PEInsights, file: PEFile) -> InspectorSection? {
        var rows: [InspectorItem] = []
        let payload = file.overlayRange.map { Format.bytes($0.count) }
        if let installer = insights.installer {
            rows.append(InspectorItem(symbol: "shippingbox", tint: .orange,
                                      title: String(localized: "\(installer) installer", bundle: .greeceKit,
                                                    comment: "Inspector row title. The argument names an installer toolkit, such as “NSIS” or “Inno Setup”"),
                                      subtitle: insights.installerDetail, value: payload,
                                      help: payload.map { size in
                                          String(localized: "\(size) of installer data follows the program", bundle: .greeceKit, comment: "Tooltip. The argument is a size, such as “12 MB”")
                                      }))
        }
        if let archive = insights.selfExtractingArchive {
            rows.append(InspectorItem(symbol: "doc.zipper", tint: .brown,
                                      title: String(localized: "\(archive) self-extracting archive", bundle: .greeceKit,
                                                    comment: "Inspector row title. The argument names an archive format, such as “7-Zip” or “ZIP”"),
                                      value: insights.installer == nil ? payload : nil))
        }
        if insights.containsMSI {
            rows.append(InspectorItem(symbol: "shippingbox.fill", tint: .blue, title: String(localized: "Contains a Windows Installer package", bundle: .greeceKit),
                                      subtitle: String(localized: "An .msi database is embedded in the file.", bundle: .greeceKit)))
        }
        guard !rows.isEmpty else { return nil }
        return InspectorSection("installer", title: String(localized: "Installer", bundle: .greeceKit, comment: "Section title on a Windows program’s page: the installer it contains"),
                                footer: String(localized: "Installers unpack and run more code than this file shows, usually with administrator rights.", bundle: .greeceKit),
                                rows: .items(rows))
    }

    // MARK: - Security features

    private static func securitySection(_ file: PEFile) -> InspectorSection {
        let flags = file.dllCharacteristics
        let managed = file.dotNet?.isILOnly == true
        let on = String(localized: "On", bundle: .greeceKit, comment: "The state of a setting or feature")
        let off = String(localized: "Off", bundle: .greeceKit, comment: "The state of a setting or feature")
        func feature(_ title: String, _ enabled: Bool, _ raw: String, subtitle: String? = nil) -> InspectorRow {
            .item(InspectorItem(symbol: enabled ? "checkmark.circle.fill" : "circle", title: title, subtitle: subtitle, value: enabled ? on : off,
                                tone: enabled ? .positive : .neutral, help: raw))
        }
        var rows: [InspectorRow] = []
        let aslr = flags & 0x40 != 0
        rows.append(feature(String(localized: "Randomized memory layout (ASLR)", bundle: .greeceKit), aslr && !file.hasRelocationsStripped, "IMAGE_DLLCHARACTERISTICS_DYNAMIC_BASE",
                            subtitle: aslr && file.hasRelocationsStripped
                                ? String(localized: "Requested, but relocations were stripped, so Windows can’t move it.", bundle: .greeceKit) : nil))
        if file.is64Bit {
            rows.append(feature(String(localized: "High-entropy ASLR", bundle: .greeceKit), flags & 0x20 != 0, "IMAGE_DLLCHARACTERISTICS_HIGH_ENTROPY_VA"))
        }
        rows.append(feature(String(localized: "Non-executable data (DEP)", bundle: .greeceKit), flags & 0x100 != 0, "IMAGE_DLLCHARACTERISTICS_NX_COMPAT"))
        if !managed {
            rows.append(feature(String(localized: "Control Flow Guard", bundle: .greeceKit, comment: "A Windows security feature"), flags & 0x4000 != 0, "IMAGE_DLLCHARACTERISTICS_GUARD_CF"))
            if let config = file.loadConfig {
                rows.append(feature(String(localized: "Stack buffer checks (/GS)", bundle: .greeceKit), config.hasSecurityCookie,
                                    String(localized: "Load configuration security cookie", bundle: .greeceKit, comment: "Tooltip: the technical detail behind a Windows security feature")))
            }
            if file.machine == 0x14C {
                let safe = flags & 0x400 != 0 || (file.loadConfig?.safeExceptionHandlers ?? 0) > 0
                rows.append(feature(String(localized: "Safe exception handlers", bundle: .greeceKit), safe,
                                    flags & 0x400 != 0 ? "IMAGE_DLLCHARACTERISTICS_NO_SEH"
                                                       : String(localized: "SafeSEH handler table", bundle: .greeceKit, comment: "Tooltip: the technical detail behind a Windows security feature"),
                                    subtitle: flags & 0x400 != 0 ? String(localized: "Uses no structured exception handlers.", bundle: .greeceKit) : nil))
            }
            rows.append(feature(String(localized: "Shadow stack (CET)", bundle: .greeceKit), file.debug.isCETCompatible, "IMAGE_DLLCHARACTERISTICS_EX_CET_COMPAT"))
        }
        if flags & 0x80 != 0 {
            rows.append(feature(String(localized: "Requires a valid signature to load", bundle: .greeceKit), true, "IMAGE_DLLCHARACTERISTICS_FORCE_INTEGRITY"))
        }
        if flags & 0x1000 != 0 {
            rows.append(feature(String(localized: "Runs in an app container", bundle: .greeceKit), true, "IMAGE_DLLCHARACTERISTICS_APPCONTAINER"))
        }
        return InspectorSection("security", title: String(localized: "Security Features", bundle: .greeceKit, comment: "Section title"),
                                footer: String(localized: "Protections from the compiler and the Windows loader that make memory-corruption bugs harder to exploit.", bundle: .greeceKit),
                                rows: rows)
    }

    // MARK: - Imports and exports

    static let systemLibraries: [String: String] = {
        let coreServices = String(localized: "Core Windows services", bundle: .greeceKit, comment: "What a Windows system library provides")
        let com = "COM"
        let sockets = String(localized: "Sockets", bundle: .greeceKit, comment: "What a Windows system library provides: network sockets")
        let cRuntime = String(localized: "C runtime", bundle: .greeceKit, comment: "What a Windows system library provides")
        let visualCRuntime = String(localized: "Visual C++ runtime", bundle: .greeceKit, comment: "What a Windows system library provides")
        let authentication = String(localized: "Authentication", bundle: .greeceKit, comment: "What a Windows system library provides")
        let graphics = String(localized: "Graphics", bundle: .greeceKit, comment: "What a Windows system library provides")
        return [
            "kernel32.dll": coreServices, "kernelbase.dll": coreServices,
            "ntdll.dll": String(localized: "Native Windows API", bundle: .greeceKit),
            "user32.dll": String(localized: "Windows and input", bundle: .greeceKit, comment: "What a Windows system library provides: windows on screen and keyboard/mouse input"),
            "gdi32.dll": graphics, "gdiplus.dll": String(localized: "Graphics (GDI+)", bundle: .greeceKit),
            "advapi32.dll": String(localized: "Registry, services and security", bundle: .greeceKit),
            "shell32.dll": String(localized: "Windows shell", bundle: .greeceKit),
            "shlwapi.dll": String(localized: "Shell utilities", bundle: .greeceKit),
            "ole32.dll": com, "oleaut32.dll": String(localized: "COM automation", bundle: .greeceKit), "combase.dll": com,
            "comctl32.dll": String(localized: "Common controls", bundle: .greeceKit, comment: "What a Windows system library provides: standard buttons, lists and so on"),
            "comdlg32.dll": String(localized: "Common dialogs", bundle: .greeceKit, comment: "What a Windows system library provides: standard Open, Save and Print dialogs"),
            "ws2_32.dll": sockets, "wsock32.dll": sockets,
            "wininet.dll": String(localized: "Internet access", bundle: .greeceKit),
            "winhttp.dll": "HTTP",
            "urlmon.dll": String(localized: "URL downloads", bundle: .greeceKit),
            "dnsapi.dll": "DNS",
            "iphlpapi.dll": String(localized: "Network configuration", bundle: .greeceKit),
            "netapi32.dll": String(localized: "Network management", bundle: .greeceKit),
            "mpr.dll": String(localized: "Network drives", bundle: .greeceKit),
            "crypt32.dll": String(localized: "Certificates and cryptography", bundle: .greeceKit),
            "bcrypt.dll": String(localized: "Cryptography", bundle: .greeceKit),
            "ncrypt.dll": String(localized: "Key storage", bundle: .greeceKit, comment: "What a Windows system library provides: storage for cryptographic keys"),
            "wintrust.dll": String(localized: "Signature verification", bundle: .greeceKit),
            "secur32.dll": authentication, "sspicli.dll": authentication,
            "credui.dll": String(localized: "Credential prompts", bundle: .greeceKit),
            "msvcrt.dll": cRuntime, "ucrtbase.dll": cRuntime,
            "vcruntime140.dll": visualCRuntime, "vcruntime140_1.dll": visualCRuntime,
            "msvcp140.dll": String(localized: "Visual C++ standard library", bundle: .greeceKit),
            "version.dll": String(localized: "Version information", bundle: .greeceKit),
            "winmm.dll": String(localized: "Multimedia", bundle: .greeceKit),
            "avrt.dll": String(localized: "Multimedia scheduling", bundle: .greeceKit),
            "dsound.dll": "DirectSound",
            "xinput1_4.dll": String(localized: "Game controllers", bundle: .greeceKit),
            "d3d9.dll": "Direct3D 9", "d3d11.dll": "Direct3D 11", "d3d12.dll": "Direct3D 12",
            "dxgi.dll": String(localized: "DirectX graphics", bundle: .greeceKit),
            "opengl32.dll": "OpenGL",
            "dwmapi.dll": String(localized: "Desktop composition", bundle: .greeceKit),
            "uxtheme.dll": String(localized: "Visual styles", bundle: .greeceKit),
            "imm32.dll": String(localized: "Input methods", bundle: .greeceKit, comment: "What a Windows system library provides: ways to type other scripts, such as Chinese"),
            "userenv.dll": String(localized: "User profiles", bundle: .greeceKit),
            "psapi.dll": String(localized: "Process information", bundle: .greeceKit),
            "dbghelp.dll": String(localized: "Debugging", bundle: .greeceKit),
            "rpcrt4.dll": String(localized: "Remote procedure calls", bundle: .greeceKit),
            "setupapi.dll": String(localized: "Device installation", bundle: .greeceKit),
            "cfgmgr32.dll": String(localized: "Device configuration", bundle: .greeceKit),
            "hid.dll": String(localized: "Input devices", bundle: .greeceKit),
            "wtsapi32.dll": String(localized: "Remote desktop sessions", bundle: .greeceKit),
            "powrprof.dll": String(localized: "Power management", bundle: .greeceKit),
            "msi.dll": "Windows Installer",
            "mscoree.dll": String(localized: ".NET runtime", bundle: .greeceKit),
            "shcore.dll": String(localized: "Display scaling", bundle: .greeceKit),
            "propsys.dll": String(localized: "Property system", bundle: .greeceKit, comment: "What a Windows system library provides: file properties and metadata"),
            "winspool.drv": String(localized: "Printing", bundle: .greeceKit),
            "normaliz.dll": String(localized: "Unicode normalization", bundle: .greeceKit),
            "wldap32.dll": String(localized: "LDAP directory", bundle: .greeceKit),
            "netutils.dll": String(localized: "Network utilities", bundle: .greeceKit),
            "ntoskrnl.exe": String(localized: "Windows kernel", bundle: .greeceKit),
            "hal.dll": String(localized: "Hardware abstraction layer", bundle: .greeceKit),
            "fltmgr.sys": String(localized: "File system filters", bundle: .greeceKit),
        ]
    }()

    static func libraryDescription(_ name: String) -> (description: String?, isSystem: Bool) {
        let lower = name.lowercased()
        if let known = systemLibraries[lower] { return (known, true) }
        if lower.hasPrefix("api-ms-win-") || lower.hasPrefix("ext-ms-win-") {
            return (lower.contains("-crt-") ? String(localized: "C runtime", bundle: .greeceKit, comment: "What a Windows system library provides")
                                            : String(localized: "Windows API set", bundle: .greeceKit, comment: "What a Windows system library provides"), true)
        }
        return (nil, false)
    }

    private static func importsSection(_ file: PEFile) -> InspectorSection? {
        guard !file.imports.isEmpty else { return nil }
        let rows: [InspectorItem] = file.imports.prefix(500).map { library in
            let (description, isSystem) = libraryDescription(library.name)
            var details = library.functions.prefix(40).map { InspectorItem(title: $0) }
            if library.functionCount > details.count {
                let rest = library.functionCount - details.count
                details.append(InspectorItem(title: String(localized: "and \(rest) more", bundle: .greeceKit,
                                                           comment: "Last row of a list of imported functions. The argument is how many more aren’t shown"),
                                             tone: .neutral))
            }
            return InspectorItem(symbol: isSystem ? "macwindow" : "puzzlepiece.extension", title: library.name,
                                 subtitle: Format.joined([description, library.isDelayLoaded ? String(localized: "Loaded on first use", bundle: .greeceKit,
                                                                                                         comment: "A library a Windows program loads only when it needs it") : nil]).nilIfEmpty,
                                 value: String(localized: "\(library.functionCount) functions", bundle: .greeceKit, comment: "Functions a program uses from a library. The argument is a count"),
                                 help: isSystem ? String(localized: "Part of Windows", bundle: .greeceKit, comment: "Tooltip on a library")
                                                : String(localized: "Ships with the app or must already be installed", bundle: .greeceKit, comment: "Tooltip on a library"),
                                 details: details)
        }
        let total = file.imports.reduce(0) { $0 + $1.functionCount }
        let libraries = file.imports.count
        let thirdParty = file.imports.filter { !libraryDescription($0.name).isSystem }.count
        // Separate facts, so each count takes its own plural form.
        let footer = Format.joined([
            String(localized: "\(libraries) libraries", bundle: .greeceKit, comment: "Section footer: how many libraries a program imports"),
            String(localized: "\(total) imported functions", bundle: .greeceKit, comment: "Section footer: how many functions a program imports from those libraries"),
            thirdParty > 0 ? String(localized: "\(thirdParty) not part of Windows", bundle: .greeceKit,
                                    comment: "Section footer: how many of the imported libraries don’t come with Windows. The argument is a count") : nil,
        ])
        return InspectorSection("imports", title: String(localized: "Imported Libraries", bundle: .greeceKit, comment: "Section title"),
                                footer: footer, rows: .items(rows), visibleLimit: 8)
    }

    private static func exportsSection(_ file: PEFile) -> InspectorSection? {
        guard let exports = file.exports, exports.functionCount > 0 || !exports.names.isEmpty else { return nil }
        var rows: [InspectorItem] = []
        if let name = exports.libraryName { rows.append(.field(String(localized: "Library Name", bundle: .greeceKit, comment: "Inspector row title"), name, mono: true)) }
        rows.append(.field(String(localized: "Exported Functions", bundle: .greeceKit, comment: "Inspector row title; its value is a count"), exports.functionCount.formatted()))
        if exports.nameCount < exports.functionCount {
            rows.append(.field(String(localized: "Exported by Ordinal Only", bundle: .greeceKit, comment: "Inspector row title; its value is a count of functions exported by number, without a name"),
                               (exports.functionCount - exports.nameCount).formatted()))
        }
        rows += exports.names.prefix(200).map { InspectorItem(symbol: "function", title: $0) }
        return InspectorSection("exports", title: String(localized: "Exports", bundle: .greeceKit, comment: "Section title: the functions a library offers to other programs"),
                                rows: .items(rows), visibleLimit: 12)
    }

    // MARK: - .NET

    private static func dotNetSection(_ file: PEFile) -> InspectorSection? {
        guard let dotNet = file.dotNet else { return nil }
        var rows: [InspectorItem] = []
        if let framework = PEInsights.prettyFramework(dotNet.targetFramework) {
            rows.append(.field(String(localized: "Target Framework", bundle: .greeceKit, comment: "Inspector row title; its value is a .NET version"), framework, help: dotNet.targetFramework))
        }
        if let metadata = dotNet.metadataVersion {
            rows.append(.field(String(localized: "Runtime Version", bundle: .greeceKit, comment: "Inspector row title"), metadata, mono: true))
        }
        rows.append(.field(String(localized: "Code", bundle: .greeceKit, comment: "Inspector row title: what kind of code a .NET program contains"),
                           dotNet.isILOnly ? String(localized: "Managed only", bundle: .greeceKit, comment: "A .NET program that contains only managed code")
                                           : String(localized: "Managed and native", bundle: .greeceKit, comment: "A .NET program that also contains native code")))
        let bitness = String(localized: "32-bit", bundle: .greeceKit, comment: "Inspector row title: whether a .NET program runs as a 32-bit process")
        if dotNet.requires32Bit {
            rows.append(.field(bitness, String(localized: "Required", bundle: .greeceKit, comment: "A hardware feature or setting that is needed")))
        } else if dotNet.prefers32Bit {
            rows.append(.field(bitness, String(localized: "Preferred", bundle: .greeceKit, comment: "A setting a program asks for but can do without")))
        }
        rows.append(.field(String(localized: "Strong-Name Signed", bundle: .greeceKit, comment: "Inspector row title on a .NET assembly"),
                           dotNet.isStrongNameSigned ? String(localized: "Yes", bundle: .greeceKit) : String(localized: "No", bundle: .greeceKit)))
        return InspectorSection("dotnet", title: ".NET", rows: .items(rows))
    }

    // MARK: - Manifest

    private static func manifestSection(_ manifest: PEManifest) -> InspectorSection {
        var rows: [InspectorRow] = []
        if let level = manifest.executionLevel {
            switch level {
            case "requireAdministrator":
                rows.append(.item(InspectorItem(symbol: "lock.shield", title: String(localized: "Runs as administrator", bundle: .greeceKit),
                                                subtitle: String(localized: "Windows asks for permission every time it starts.", bundle: .greeceKit),
                                                tone: .caution, help: "requestedExecutionLevel = requireAdministrator")))
            case "highestAvailable":
                rows.append(.item(InspectorItem(symbol: "person.badge.shield.checkmark", title: String(localized: "Runs with the highest available rights", bundle: .greeceKit),
                                                subtitle: String(localized: "Administrators are asked for permission; other users run it normally.", bundle: .greeceKit),
                                                help: "requestedExecutionLevel = highestAvailable")))
            default:
                rows.append(.item(InspectorItem(symbol: "person", title: String(localized: "Runs as the current user", bundle: .greeceKit),
                                                help: "requestedExecutionLevel = \(level)")))
            }
        }
        if manifest.uiAccess {
            rows.append(.item(InspectorItem(symbol: "hand.raised", title: String(localized: "Can control other apps’ windows", bundle: .greeceKit),
                                            subtitle: String(localized: "UI Access bypasses window isolation.", bundle: .greeceKit),
                                            tone: .caution, help: "uiAccess = true")))
        }
        if !manifest.supportedOS.isEmpty {
            rows.append(.item(.field(String(localized: "Supports", bundle: .greeceKit, comment: "Inspector row title; its value lists Windows versions"),
                                     manifest.supportedOS.joined(separator: ", "))))
        }
        if let dpi = manifest.dpiAware { rows.append(.item(.field(String(localized: "DPI Awareness", bundle: .greeceKit, comment: "Inspector row title"), dpi))) }
        if manifest.longPathAware {
            rows.append(.item(.field(String(localized: "Long Paths", bundle: .greeceKit, comment: "Inspector row title: file paths longer than 260 characters"),
                                     String(localized: "Supported", bundle: .greeceKit))))
        }
        let lines = manifest.text.split(separator: "\n", omittingEmptySubsequences: false).count
        let manifestTitle = String(localized: "Manifest", bundle: .greeceKit, comment: "A Windows program’s application manifest")
        rows.append(.code(InspectorCode(symbol: "doc.text", title: manifestTitle,
                                        subtitle: String(localized: "\(lines) lines", bundle: .greeceKit, comment: "Length of a script or document. The argument is a count"),
                                        text: manifest.text, grammar: "xml")))
        return InspectorSection("manifest", title: manifestTitle, rows: rows)
    }

    // MARK: - Version info

    static let versionLabels: [(String, String)] = [
        ("CompanyName", String(localized: "Company", bundle: .greeceKit, comment: "Inspector row title in a Windows program’s version info")),
        ("ProductName", String(localized: "Product", bundle: .greeceKit, comment: "Inspector row title in a Windows program’s version info")),
        ("FileDescription", String(localized: "Description", bundle: .greeceKit, comment: "Inspector row title in a Windows program’s version info")),
        ("ProductVersion", String(localized: "Product Version", bundle: .greeceKit)),
        ("FileVersion", String(localized: "File Version", bundle: .greeceKit)),
        ("LegalCopyright", String(localized: "Copyright", bundle: .greeceKit, comment: "Inspector row title in a Windows program’s version info")),
        ("LegalTrademarks", String(localized: "Trademarks", bundle: .greeceKit, comment: "Inspector row title in a Windows program’s version info")),
        ("OriginalFilename", String(localized: "Original File Name", bundle: .greeceKit)),
        ("InternalName", String(localized: "Internal Name", bundle: .greeceKit)),
        ("Comments", String(localized: "Comments", bundle: .greeceKit, comment: "Inspector row title in a Windows program’s version info")),
        ("PrivateBuild", String(localized: "Private Build", bundle: .greeceKit)),
        ("SpecialBuild", String(localized: "Special Build", bundle: .greeceKit)),
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
        if version["FileVersion"] == nil, let fixed = version.fileVersion { rows.append(.field(String(localized: "File Version", bundle: .greeceKit), fixed)) }
        let languages = Set(version.languages)
        if languages.count > 1 {
            rows.append(.field(String(localized: "Languages", bundle: .greeceKit, comment: "Inspector row title; its value is a count"), languages.count.formatted(),
                               help: languages.sorted().prefix(40).compactMap(languageName).joined(separator: ", ")))
        } else if let language = languages.first, let name = languageName(language) {
            rows.append(.field(String(localized: "Language", bundle: .greeceKit, comment: "Inspector row title"), name))
        }
        let flags = [version.isDebugBuild ? String(localized: "Debug", bundle: .greeceKit, comment: "Windows build flag: a debug build") : nil,
                     version.isPrerelease ? String(localized: "Pre-release", bundle: .greeceKit, comment: "Windows build flag") : nil,
                     version.isPrivateBuild ? String(localized: "Private", bundle: .greeceKit, comment: "Windows build flag: a private build, not a public release") : nil,
                     version.isPatched ? String(localized: "Patched", bundle: .greeceKit, comment: "Windows build flag: a modified build") : nil].compactMap { $0 }
        if !flags.isEmpty {
            rows.append(.field(String(localized: "Build", bundle: .greeceKit, comment: "Inspector row title; its value lists build flags, such as “Debug, Pre-release”"),
                               flags.joined(separator: ", "), tone: version.isDebugBuild ? .caution : .neutral))
        }
        guard !rows.isEmpty else { return nil }
        return InspectorSection("version", title: String(localized: "Version Info", bundle: .greeceKit, comment: "Section title: a Windows program’s version resource"), rows: .items(rows))
    }

    static func languageName(_ code: UInt16) -> String? {
        guard code != 0 else { return String(localized: "Neutral", bundle: .greeceKit, comment: "The language of a Windows program’s version info: not tied to a language") }
        let identifier = Locale.identifier(fromWindowsLocaleCode: Int(code))
        return identifier.flatMap { Locale.current.localizedString(forIdentifier: $0) }
    }

    // MARK: - Sections

    private static func sectionsSection(_ file: PEFile) -> InspectorSection? {
        guard !file.sections.isEmpty else { return nil }
        let code = String(localized: "Code", bundle: .greeceKit, comment: "What a section of a program holds: its compiled code")
        let data = String(localized: "Data", bundle: .greeceKit, comment: "What a section of a program holds")
        let readOnlyData = String(localized: "Read-only data", bundle: .greeceKit, comment: "What a section of a program holds")
        let uninitializedData = String(localized: "Uninitialized data", bundle: .greeceKit, comment: "What a section of a program holds")
        let names: [String: String] = [
            ".text": code, ".rdata": readOnlyData, ".data": data, ".bss": uninitializedData,
            ".rsrc": String(localized: "Resources", bundle: .greeceKit, comment: "What a section of a program holds: icons, dialogs, strings and so on"),
            ".reloc": String(localized: "Relocations", bundle: .greeceKit, comment: "What a section of a program holds"),
            ".pdata": String(localized: "Exception data", bundle: .greeceKit, comment: "What a section of a program holds"),
            ".idata": String(localized: "Imports", bundle: .greeceKit, comment: "What a section of a program holds: the functions it uses from libraries"),
            ".edata": String(localized: "Exports", bundle: .greeceKit, comment: "Section title: the functions a library offers to other programs"),
            ".tls": String(localized: "Thread-local storage", bundle: .greeceKit),
            ".CRT": String(localized: "C runtime data", bundle: .greeceKit),
            ".ndata": String(localized: "Installer data", bundle: .greeceKit),
            ".didat": String(localized: "Delay-load imports", bundle: .greeceKit),
            ".gfids": String(localized: "Control Flow Guard data", bundle: .greeceKit),
            "UPX0": String(localized: "UPX (unpacked at launch)", bundle: .greeceKit),
            "UPX1": String(localized: "UPX packed code", bundle: .greeceKit),
            ".wixburn": String(localized: "WiX Burn data", bundle: .greeceKit),
            ".itext": String(localized: "Delphi code", bundle: .greeceKit),
        ]
        let rows: [InspectorItem] = file.sections.prefix(96).map { section in
            let writableCode = section.isExecutable && section.isWritable
            var kind = names[section.name] ?? (section.isCode || section.isExecutable ? code : section.hasUninitializedData ? uninitializedData
                                                : section.isWritable ? data : readOnlyData)
            if writableCode { kind = String(localized: "Writable and executable", bundle: .greeceKit, comment: "A section of a program that can be both changed and run") }
            let packed = (section.entropy ?? 0) > 7.2
            let size = Format.bytes(Int(section.virtualSize))
            let address = "0x" + String(section.virtualAddress, radix: 16, uppercase: true)
            let entropy = section.entropy.map { value in
                let text = value.formatted(.number.precision(.fractionLength(2)))
                return String(localized: "Entropy \(text)", bundle: .greeceKit, comment: "Tooltip on a program section. The argument is a number from 0 to 8, such as “6.42”")
            }
            let help = Format.joined([
                String(localized: "Virtual size \(size) at \(address)", bundle: .greeceKit,
                       comment: "Tooltip on a program section. The arguments are a size, such as “12 KB”, and a memory address, such as “0x1000”"),
                entropy,
            ])
            let stored = section.rawSize > 0
            return InspectorItem(title: section.name.isEmpty ? String(localized: "(unnamed)", bundle: .greeceKit, comment: "A program section without a name") : section.name,
                                 subtitle: Format.joined([kind,
                                                          packed ? String(localized: "compressed or encrypted", bundle: .greeceKit, comment: "After the kind of a program section, such as “Code · compressed or encrypted”") : nil,
                                                          stored ? nil : String(localized: "allocated at launch", bundle: .greeceKit, comment: "After the kind of a program section, such as “Data · allocated at launch”")]),
                                 value: Format.bytes(Int(stored ? section.rawSize : section.virtualSize)),
                                 tone: writableCode ? .caution : .neutral, help: help)
        }
        return InspectorSection("sections", title: String(localized: "Sections", bundle: .greeceKit, comment: "Section title: the parts of a Windows program file"),
                                rows: .items(rows), visibleLimit: 8)
    }

    // MARK: - Info

    private static func infoSection(_ file: PEFile, url: URL, insights: PEInsights, architecture: Architecture) -> InspectorSection {
        var rows: [InspectorItem] = []
        rows.append(.field(String(localized: "Kind", bundle: .greeceKit, comment: "Inspector row title: the kind of file"), kindDescription(file)))
        rows.append(.field(String(localized: "Architecture", bundle: .greeceKit, comment: "Inspector row title: a processor architecture"), architecture.long))
        rows.append(.field(String(localized: "Subsystem", bundle: .greeceKit, comment: "Inspector row title: the Windows subsystem a program runs in, such as console or GUI"),
                           subsystemName(file.subsystem)))
        if !file.isEFI, let minimum = minimumWindows(file.subsystemVersion) {
            rows.append(.field(String(localized: "Minimum Windows", bundle: .greeceKit, comment: "Inspector row title; its value is a Windows version"), minimum))
        }
        if !insights.builtWith.isEmpty {
            rows.append(.field(String(localized: "Built With", bundle: .greeceKit, comment: "Inspector row title; its value lists toolkits and languages"),
                               insights.builtWith.joined(separator: ", ")))
        }
        rows.append(buildTime(file))
        rows.append(.field(String(localized: "Linker", bundle: .greeceKit, comment: "Inspector row title; its value is the linker’s version"), file.linkerVersion))
        rows.append(.field(String(localized: "Entry Point", bundle: .greeceKit, comment: "Inspector row title; its value is a memory address"),
                           "0x" + String(file.entryPoint, radix: 16, uppercase: true), mono: true))
        rows.append(.field(String(localized: "Image Base", bundle: .greeceKit, comment: "Inspector row title; its value is the memory address a program prefers to load at"),
                           "0x" + String(file.imageBase, radix: 16, uppercase: true), mono: true))
        rows.append(.field(String(localized: "Image Size", bundle: .greeceKit, comment: "Inspector row title: how much memory a program takes once loaded"),
                           Format.bytes(Int(file.imageSize))))
        if let pdb = file.debug.pdbPath {
            let name = pdb.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last.map(String.init) ?? pdb
            rows.append(.field(String(localized: "Debug Symbols", bundle: .greeceKit, comment: "Inspector row title; its value is a .pdb file name"), name, mono: true, help: pdb))
            if let guid = file.debug.pdbGUID {
                rows.append(.field(String(localized: "Symbols ID", bundle: .greeceKit, comment: "Inspector row title: the identifier that matches a program to its debug symbols"),
                                   guid + (file.debug.pdbAge.map { " · \($0)" } ?? ""), mono: true,
                                   help: String(localized: "PDB GUID and age", bundle: .greeceKit, comment: "Tooltip: the technical name of the value")))
            }
        }
        if let census = file.resources?.census, !census.isEmpty {
            rows.append(.field(String(localized: "Resources", bundle: .greeceKit, comment: "Inspector row title; its value lists counts, such as “8 icons, 3 dialogs”"),
                               census.joined(separator: ", ")))
        }
        if let overlay = file.overlayRange, overlay.count > 0 {
            rows.append(.field(String(localized: "Appended Data", bundle: .greeceKit, comment: "Inspector row title; its value is a size"), Format.bytes(overlay.count),
                               help: String(localized: "Data after the last section, where installers keep their payload", bundle: .greeceKit)))
        }
        rows.append(.field(String(localized: "File Size", bundle: .greeceKit, comment: "Inspector row title"), Format.bytes(file.fileSize)))
        return InspectorSection("info", title: String(localized: "Info", bundle: .greeceKit, comment: "Section title"), rows: .items(rows))
    }

    private static func buildTime(_ file: PEFile) -> InspectorItem {
        let built = String(localized: "Built", bundle: .greeceKit, comment: "Inspector row title; its value is the date and time a program was built")
        if file.timestamp == 0 { return .field(built, String(localized: "Not recorded", bundle: .greeceKit, comment: "A Windows program’s build date isn’t in the file")) }
        let date = Date(timeIntervalSince1970: TimeInterval(file.timestamp))
        let plausible = file.timestamp > 631_152_000 && date < Date().addingTimeInterval(86_400 * 2)
        if file.debug.isReproducible || !plausible {
            let field = String(format: "0x%08X", file.timestamp)
            return .field(built, String(localized: "Reproducible build", bundle: .greeceKit, comment: "Instead of a build date: the program was built so its bytes don’t depend on when"),
                          help: String(localized: "Timestamp field \(field) is a content hash, not a date", bundle: .greeceKit,
                                       comment: "Tooltip. The argument is a hexadecimal number, such as “0x5F3A2B1C”"))
        }
        return .field(built, Format.dateTime(date))
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
        let arm64EC = String(localized: "ARM64EC (x64-compatible ARM64)", bundle: .greeceKit, comment: "A Windows processor architecture")
        let arm64X = String(localized: "ARM64X (ARM64 and ARM64EC)", bundle: .greeceKit, comment: "A Windows processor architecture")
        switch file.machine {
        case 0x8664 where hybrid:
            return Architecture(badge: "ARM64EC", short: "ARM64EC", long: arm64EC,
                                help: String(localized: "ARM64 code that interoperates with x64 code on Windows on ARM.", bundle: .greeceKit))
        case 0x8664:
            return Architecture(badge: "x64", short: "x64", long: String(localized: "x64 (64-bit Intel and AMD)", bundle: .greeceKit, comment: "A Windows processor architecture"),
                                help: String(localized: "Runs on 64-bit Intel and AMD PCs, and on ARM PCs through emulation.", bundle: .greeceKit))
        case 0xAA64 where hybrid:
            return Architecture(badge: "ARM64X", short: "ARM64X", long: arm64X,
                                help: String(localized: "Contains both native ARM64 and x64-compatible code.", bundle: .greeceKit))
        case 0xAA64:
            return Architecture(badge: "ARM64", short: "ARM64", long: "ARM64", help: String(localized: "Runs natively on Windows on ARM.", bundle: .greeceKit))
        case 0xA641: return Architecture(badge: "ARM64EC", short: "ARM64EC", long: arm64EC, help: nil)
        case 0xA64E: return Architecture(badge: "ARM64X", short: "ARM64X", long: arm64X, help: nil)
        case 0x14C:
            return Architecture(badge: String(localized: "x86 (32-bit)", bundle: .greeceKit, comment: "Badge: a processor architecture"), short: "x86",
                                long: String(localized: "x86 (32-bit Intel)", bundle: .greeceKit, comment: "A Windows processor architecture"),
                                help: String(localized: "A 32-bit program. 64-bit Windows runs it through WOW64.", bundle: .greeceKit))
        case 0x1C0, 0x1C2, 0x1C4:
            let arm = String(localized: "ARM (32-bit)", bundle: .greeceKit, comment: "A processor architecture")
            return Architecture(badge: arm, short: "ARM", long: arm, help: nil)
        case 0x200: return Architecture(badge: "Itanium", short: "IA-64", long: "Itanium (IA-64)", help: nil)
        case 0xEBC: return Architecture(badge: "EFI Byte Code", short: "EBC", long: "EFI Byte Code", help: nil)
        case 0x5064:
            return Architecture(badge: "RISC-V", short: "RISC-V 64", long: String(localized: "RISC-V (64-bit)", bundle: .greeceKit, comment: "A processor architecture"), help: nil)
        case 0x5032:
            return Architecture(badge: "RISC-V", short: "RISC-V 32", long: String(localized: "RISC-V (32-bit)", bundle: .greeceKit, comment: "A processor architecture"), help: nil)
        case 0x6264:
            return Architecture(badge: "LoongArch", short: "LoongArch64", long: String(localized: "LoongArch (64-bit)", bundle: .greeceKit, comment: "A processor architecture"), help: nil)
        case 0:
            let any = String(localized: "Any CPU", bundle: .greeceKit, comment: "A .NET program that runs on any processor architecture")
            return Architecture(badge: any, short: any, long: String(localized: "Unspecified", bundle: .greeceKit, comment: "A program’s processor architecture isn’t set"), help: nil)
        default:
            let hex = String(format: "0x%04X", file.machine)
            return Architecture(badge: hex, short: hex,
                                long: String(localized: "Machine type \(hex)", bundle: .greeceKit, comment: "An unknown processor architecture. The argument is a hexadecimal code, such as “0x01F0”"),
                                help: nil)
        }
    }

    static func subsystemName(_ value: UInt16) -> String {
        switch value {
        case 1: return String(localized: "Native (driver or boot program)", bundle: .greeceKit, comment: "A Windows subsystem")
        case 2: return String(localized: "Windows GUI", bundle: .greeceKit, comment: "A Windows subsystem: programs with windows")
        case 3: return String(localized: "Console", bundle: .greeceKit, comment: "A Windows subsystem: command-line programs")
        case 5: return String(localized: "OS/2 console", bundle: .greeceKit, comment: "A Windows subsystem")
        case 7: return String(localized: "POSIX console", bundle: .greeceKit, comment: "A Windows subsystem")
        case 9: return String(localized: "Windows CE GUI", bundle: .greeceKit, comment: "A Windows subsystem")
        case 10: return String(localized: "EFI application", bundle: .greeceKit, comment: "A kind of program that runs before the operating system starts")
        case 11: return String(localized: "EFI boot service driver", bundle: .greeceKit, comment: "A Windows subsystem")
        case 12: return String(localized: "EFI runtime driver", bundle: .greeceKit, comment: "A Windows subsystem")
        case 13: return "EFI ROM"
        case 14: return "Xbox"
        case 16: return String(localized: "Windows boot application", bundle: .greeceKit, comment: "A Windows subsystem")
        default:
            let number = String(value)
            return String(localized: "Unknown (\(number))", bundle: .greeceKit, comment: "An unknown Windows subsystem. The argument is its number")
        }
    }

    static func minimumWindows(_ version: (major: UInt16, minor: UInt16)) -> String? {
        switch (version.major, version.minor) {
        case (3, _): return "Windows NT 3.1"
        case (4, _): return String(localized: "Windows 95 or NT 4.0", bundle: .greeceKit, comment: "The oldest Windows version a program runs on")
        case (5, 0): return "Windows 2000"
        case (5, 1): return "Windows XP"
        case (5, 2): return String(localized: "Windows XP x64 or Server 2003", bundle: .greeceKit, comment: "The oldest Windows version a program runs on")
        case (6, 0): return "Windows Vista"
        case (6, 1): return "Windows 7"
        case (6, 2): return "Windows 8"
        case (6, 3): return "Windows 8.1"
        case (10, _): return "Windows 10"
        default: return nil
        }
    }

    static func kindDescription(_ file: PEFile) -> String {
        if file.isEFI {
            return file.subsystem == 10 ? String(localized: "EFI application", bundle: .greeceKit, comment: "A kind of program that runs before the operating system starts")
                                        : String(localized: "EFI driver", bundle: .greeceKit, comment: "A kind of Windows file")
        }
        if file.isDriver { return String(localized: "Driver", bundle: .greeceKit, comment: "A kind of Windows file") }
        if file.isDLL {
            return file.dotNet != nil ? String(localized: ".NET library", bundle: .greeceKit, comment: "A kind of Windows file")
                                      : String(localized: "Library (DLL)", bundle: .greeceKit, comment: "A kind of Windows file")
        }
        if file.subsystem == 3 { return String(localized: "Command-line program", bundle: .greeceKit, comment: "A kind of Windows file") }
        return String(localized: "Application", bundle: .greeceKit, comment: "A kind of file: a program with windows")
    }

    static func kindTitle(_ file: PEFile, insights: PEInsights) -> String {
        if file.isEFI {
            return file.subsystem == 10 ? String(localized: "EFI Application", bundle: .greeceKit, comment: "Info bar title")
                                        : String(localized: "EFI Driver", bundle: .greeceKit, comment: "Info bar title")
        }
        if file.isDriver { return String(localized: "Windows Driver", bundle: .greeceKit, comment: "Info bar title") }
        if file.isDLL { return String(localized: "Windows Library", bundle: .greeceKit, comment: "Info bar title") }
        if insights.installer != nil { return String(localized: "Windows Installer", bundle: .greeceKit, comment: "Info bar title: a Windows program that installs another program") }
        if file.subsystem == 3 { return String(localized: "Windows Command-Line Tool", bundle: .greeceKit, comment: "Info bar title") }
        return String(localized: "Windows App", bundle: .greeceKit, comment: "Info bar title")
    }

    private static func fallbackSymbol(_ file: PEFile, insights: PEInsights) -> String {
        if file.isEFI || file.isDriver { return "cpu" }
        if file.isDLL { return "puzzlepiece.extension" }
        if insights.installer != nil { return "shippingbox" }
        if file.subsystem == 3 { return "terminal" }
        return "macwindow"
    }
}
