import Foundation
import Security
import os

/// The Signature section, badges and background checks for signed code: apps, extensions,
/// frameworks, command-line tools, disk images.
enum SigningSection {
    static let log = Logger(subsystem: "com.scorchy.greece", category: "apps")

    struct Output {
        var section: InspectorSection
        var badges: [InspectorBadge]
        var checks: [InspectorCheck]
    }

    enum Subject {
        case bundle, executable, diskImage, archived

        /// The Notarized badge's tooltip.
        var notarizedHelp: String {
            switch self {
            case .bundle, .archived: return String(localized: "Apple scanned this app for malware and stapled a ticket to it.", bundle: .greeceKit)
            case .executable: return String(localized: "Apple scanned this file for malware and stapled a ticket to it.", bundle: .greeceKit)
            case .diskImage: return String(localized: "Apple scanned this disk image for malware and stapled a ticket to it.", bundle: .greeceKit)
            }
        }

        /// Under "Unmodified since signing" when only the code was checked.
        var resourcesSkipped: String {
            switch self {
            case .bundle, .archived: return String(localized: "The code is intact. Resources weren’t checked because the app is very large.", bundle: .greeceKit)
            case .executable: return String(localized: "The code is intact. Resources weren’t checked because the file is very large.", bundle: .greeceKit)
            case .diskImage: return String(localized: "The code is intact. Resources weren’t checked because the disk image is very large.", bundle: .greeceKit)
            }
        }
    }

    // Labels other inspector pages share.
    static var signatureTitle: String { String(localized: "Signature", bundle: .greeceKit, comment: "Section title: who signed a file and whether the signature holds (noun)") }
    static var teamLabel: String { String(localized: "Team", bundle: .greeceKit, comment: "Inspector row title: the developer team that signed an app") }
    static var notarizationLabel: String { String(localized: "Notarization", bundle: .greeceKit, comment: "Inspector row title: whether Apple notarized the code") }
    static var integrityLabel: String { String(localized: "Integrity", bundle: .greeceKit, comment: "Inspector row title: whether the code changed since it was signed") }
    static var notarizedTitle: String { String(localized: "Notarized", bundle: .greeceKit, comment: "Badge and inspector row value: Apple notarized the code") }
    static var unmodifiedValue: String { String(localized: "Unmodified since signing", bundle: .greeceKit, comment: "Inspector row value for Integrity") }

    /// - Parameters:
    ///   - url: the code on disk, for Security framework checks (nil inside archives).
    ///   - ticket: a stapled ticket found outside the signature (bundles keep theirs in CodeResources).
    ///   - showsRuntime: false leaves out the Hardened Runtime row (iOS apps don't use it).
    static func build(signature: CodeSignature?, url: URL?, subject: Subject, ticket: NotarizationTicket? = nil,
                      fileCount: Int? = nil, totalSize: UInt64? = nil, showsRuntime: Bool = true) -> Output {
        guard let signature else {
            let text = subject == .archived
                ? String(localized: "Not code signed. An iPhone or iPad won’t install it until it’s signed.", bundle: .greeceKit)
                : String(localized: "Not code signed. macOS won’t open it unless you make an exception, and nothing vouches for who made it.", bundle: .greeceKit)
            let rows: [InspectorRow] = [.note(InspectorNote(symbol: "xmark.seal", text: text, tone: .critical))]
            return Output(section: InspectorSection("signature", title: signatureTitle, rows: rows), badges: [SignerKind.unsignedBadge], checks: [])
        }

        var badges: [InspectorBadge] = []
        var rows: [InspectorRow] = []
        var checks: [InspectorCheck] = []
        var signer = signature.signer
        if signature.isPlatformBinary && signer == .adHoc { signer = .apple }
        badges.append(signer.badge)

        let summaries = signature.certificates.map(CertificateSummary.init(certificate:))
        let signedBy = String(localized: "Signed by", bundle: .greeceKit, comment: "Inspector row title: who or what signed the code")
        if let leaf = summaries.first {
            rows.append(.item(.field(teamLabel, teamName(leaf, teamID: signature.teamID))))
        } else if signature.flags.contains(.linkerSigned) {
            rows.append(.item(.field(signedBy, String(localized: "The linker (no certificate)", bundle: .greeceKit),
                                     help: String(localized: "Signed automatically by the linker so it can run on Apple silicon. It doesn’t identify a developer.", bundle: .greeceKit))))
        } else {
            rows.append(.item(.field(signedBy, String(localized: "No certificate (ad hoc)", bundle: .greeceKit),
                                     help: String(localized: "An ad hoc signature proves the code is intact, not who made it.", bundle: .greeceKit))))
        }
        if let identifier = signature.identifier {
            rows.append(.item(.field(String(localized: "Identifier", bundle: .greeceKit, comment: "Inspector row title: the code signing identifier"), identifier, mono: true)))
        }

        // Notarization: a stapled ticket answers offline; otherwise Security framework may know.
        let ticket = ticket ?? signature.ticket
        let needsNotarization = signer == .developerID
        if let ticket {
            let matches = signature.cdhashes.contains { ticket.covers($0) } || (signature.cdhash.map(ticket.covers) ?? false)
            let date = ticket.notarizedAt.map {
                String(localized: "Notarized \(Format.date($0))", bundle: .greeceKit, comment: "Inspector row value. The argument is a date, such as “Mar 4, 2025”")
            } ?? notarizedTitle
            if matches || subject == .diskImage {
                rows.append(.item(InspectorItem(title: notarizationLabel, subtitle: String(localized: "Apple’s ticket is stapled, so Gatekeeper can check it offline.", bundle: .greeceKit),
                                                value: date, tone: .positive, valueSymbol: "checkmark.seal.fill")))
                badges.append(InspectorBadge("notarization", symbol: "checkmark.seal.fill", title: notarizedTitle, tone: .positive,
                                             help: subject.notarizedHelp))
            } else {
                rows.append(.item(InspectorItem(title: notarizationLabel,
                                                subtitle: String(localized: "A ticket is stapled, but it doesn’t list this code. It may have changed after notarization.", bundle: .greeceKit),
                                                value: String(localized: "Ticket doesn’t match", bundle: .greeceKit), tone: .caution, valueSymbol: "exclamationmark.triangle.fill")))
            }
        } else if needsNotarization {
            if let url {
                rows.append(.pending(id: "notarization", title: String(localized: "Checking notarization…", bundle: .greeceKit)))
                checks.append(InspectorCheck(id: "notarization") { notarizationCheck(url: url) })
            } else {
                rows.append(.item(notStapled))
            }
        } else if signer == .appStore || signer == .apple {
            let reason = signer == .apple ? String(localized: "Apple’s own software isn’t notarized.", bundle: .greeceKit)
                : String(localized: "App Store apps are reviewed instead of notarized.", bundle: .greeceKit)
            rows.append(.item(InspectorItem(title: notarizationLabel, subtitle: reason,
                                            value: String(localized: "Not needed", bundle: .greeceKit, comment: "Inspector row value: notarization isn’t needed"))))
        }

        // Integrity: only for code on disk, after first paint.
        if let url {
            rows.append(.pending(id: "integrity", title: String(localized: "Checking the signature…", bundle: .greeceKit)))
            let known: Bool? = fileCount.flatMap { count in totalSize.map { isLarge(count: count, bytes: $0) } }
            checks.append(InspectorCheck(id: "integrity") {
                // Hashing every resource of a multi-gigabyte bundle takes minutes: check only the code then.
                let large = known ?? (subject == .bundle ? measureIsLarge(url) : false)
                return integrityCheck(url: url, subject: subject, skipResources: large)
            })
        }

        if let date = signature.timestamp ?? signature.signingTime {
            let title = signature.timestamp != nil
                ? String(localized: "Timestamp", bundle: .greeceKit, comment: "Inspector row title: when Apple’s timestamp service says the code was signed")
                : String(localized: "Signing Time", bundle: .greeceKit)
            let help = signature.timestamp != nil
                ? String(localized: "A secure timestamp from Apple proves when it was signed.", bundle: .greeceKit)
                : String(localized: "The signing time the developer’s Mac reported.", bundle: .greeceKit)
            rows.append(.item(.field(title, Format.dateTime(date), help: help)))
        }
        let runtime = String(localized: "Hardened Runtime", bundle: .greeceKit, comment: "Badge and inspector row title: Apple’s code-signing protection")
        if signature.hasHardenedRuntime {
            badges.append(InspectorBadge("runtime", symbol: "lock.shield", title: runtime, tone: .positive,
                                         help: String(localized: "Protects against code injection, library hijacking and memory tampering.", bundle: .greeceKit)))
            if showsRuntime {
                let on = signature.runtimeVersion.map {
                    String(localized: "On (SDK \($0))", bundle: .greeceKit, comment: "Inspector row value for Hardened Runtime. The argument is an SDK version, such as “14.0”")
                } ?? String(localized: "On", bundle: .greeceKit, comment: "Inspector row value: a protection is turned on")
                rows.append(.item(.field(runtime, on)))
            }
        } else if showsRuntime && subject != .diskImage && subject != .archived && !signature.isPlatformBinary {
            rows.append(.item(.field(runtime, String(localized: "Off", bundle: .greeceKit, comment: "Inspector row value: a protection is turned off"),
                                     help: String(localized: "Without the hardened runtime, other code can more easily inject into or debug this process.", bundle: .greeceKit))))
        }
        if !summaries.isEmpty {
            rows.append(.item(certificateRow(summaries, timestamped: signature.timestamp != nil)))
        }
        if let cdhash = signature.cdhash {
            rows.append(.item(.field("CDHash", cdhash.hexString, mono: true,
                                     help: String(localized: "The hash that identifies exactly this code (\(signature.hashName)).", bundle: .greeceKit,
                                                  comment: "Tooltip. The argument is a hash algorithm, such as “SHA-256”"))))
        }
        return Output(section: InspectorSection("signature", title: signatureTitle, rows: rows), badges: badges, checks: checks)
    }

    /// "Raycast Technologies Inc (SY64MV22J9)", from the leaf certificate.
    static func teamName(_ leaf: CertificateSummary, teamID: String?) -> String {
        var name = leaf.organization
        if name == nil, let colon = leaf.commonName.firstIndex(of: ":") {
            var rest = leaf.commonName[leaf.commonName.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if let team = teamID, rest.hasSuffix("(\(team))") { rest = String(rest.dropLast(team.count + 2)).trimmingCharacters(in: .whitespaces) }
            name = rest
        }
        let display = name ?? leaf.commonName
        guard let team = teamID, !team.isEmpty, !display.contains(team) else { return display }
        return "\(display) (\(team))"
    }

    /// One row for the whole chain: the certificate's kind, expanding to each certificate.
    static func certificateRow(_ chain: [CertificateSummary], timestamped: Bool) -> InspectorItem {
        let leaf = chain[0]
        let kind = leaf.commonName.split(separator: ":").first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? leaf.commonName
        let details = CertificateRows.chain(chain).map { item -> InspectorItem in
            var item = item
            // Expired signing certificates don't invalidate timestamped signatures.
            if item.tone == .critical { item.tone = timestamped ? .neutral : .caution }
            return item
        }
        return InspectorItem(title: String(localized: "Certificate", bundle: .greeceKit, comment: "Inspector row title: the certificate that signed the code"),
                             value: kind, help: leaf.commonName, details: details)
    }

    static var notStapled: InspectorItem {
        InspectorItem(title: notarizationLabel, subtitle: String(localized: "No ticket is stapled. Gatekeeper checks with Apple online the first time it opens.", bundle: .greeceKit),
                      value: String(localized: "Not stapled", bundle: .greeceKit, comment: "Inspector row value: no notarization ticket is attached"))
    }

    static func isLarge(count: Int, bytes: UInt64) -> Bool { bytes > 2_000_000_000 || count > 60_000 }

    /// A bounded walk: large if it passes either limit, or if it can't be measured within a second and a half.
    static func measureIsLarge(_ url: URL) -> Bool {
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }) else { return true }
        let deadline = Date().addingTimeInterval(1.5)
        var count = 0
        var bytes: UInt64 = 0
        while let item = enumerator.nextObject() as? URL {
            guard let values = try? item.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            count += 1
            bytes = bytes.saturatingAdd(UInt64(values.fileSize ?? 0))
            if isLarge(count: count, bytes: bytes) { return true }
            if count % 512 == 0, Date() > deadline { return true }
        }
        return false
    }

    // MARK: - Security framework checks

    private static let noNetwork = SecCSFlags(rawValue: 1 << 29)   // kSecCSNoNetworkAccess

    static func staticCode(_ url: URL) -> SecStaticCode? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess else { return nil }
        return code
    }

    static func notarizationCheck(url: URL) -> InspectorCheckResult {
        guard let code = staticCode(url) else { return InspectorCheckResult(rows: [.item(notStapled)]) }
        var requirement: SecRequirement?
        SecRequirementCreateWithString("notarized" as CFString, [], &requirement)
        var error: Unmanaged<CFError>?
        let flags = SecCSFlags(rawValue: kSecCSDoNotValidateResources).union(noNetwork)
        let status = SecStaticCodeCheckValidityWithErrors(code, flags, requirement, &error)
        error?.release()
        log.info("Notarization requirement check: \(status, privacy: .public)")
        guard status == errSecSuccess else { return InspectorCheckResult(rows: [.item(notStapled)]) }
        return InspectorCheckResult(
            rows: [.item(InspectorItem(title: notarizationLabel, subtitle: String(localized: "macOS has Apple’s notarization ticket for this code.", bundle: .greeceKit),
                                       value: notarizedTitle, tone: .positive, valueSymbol: "checkmark.seal.fill"))],
            badges: [InspectorBadge("notarization", symbol: "checkmark.seal.fill", title: notarizedTitle, tone: .positive,
                                    help: String(localized: "Apple scanned this code for malware and issued a notarization ticket.", bundle: .greeceKit))])
    }

    static func integrityCheck(url: URL, subject: Subject, skipResources: Bool) -> InspectorCheckResult {
        let started = Date()
        guard let code = staticCode(url) else {
            return InspectorCheckResult(rows: [.item(InspectorItem(title: integrityLabel, value: String(localized: "Couldn’t be checked", bundle: .greeceKit, comment: "Inspector row value for Integrity")))])
        }
        var flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate).union(noNetwork)
        if subject == .bundle && !skipResources { flags.insert(SecCSFlags(rawValue: kSecCSCheckNestedCode)) }
        if skipResources { flags.insert(SecCSFlags(rawValue: kSecCSDoNotValidateResources)) }
        var unmanaged: Unmanaged<CFError>?
        let status = SecStaticCodeCheckValidityWithErrors(code, flags, nil, &unmanaged)
        let error = unmanaged?.takeRetainedValue()
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        log.info("Integrity check: \(status, privacy: .public) in \(elapsed, privacy: .public) ms")

        if status == errSecSuccess {
            let subtitle = skipResources ? subject.resourcesSkipped : nil
            return InspectorCheckResult(rows: [.item(InspectorItem(title: integrityLabel, subtitle: subtitle,
                                                                   value: unmodifiedValue, tone: .positive, valueSymbol: "checkmark.shield.fill"))])
        }

        let info = (error.map { CFErrorCopyUserInfo($0) as? [String: Any] } ?? nil) ?? [:]
        func paths(_ key: CFString) -> [String] {
            ((info[key as String] as? [Any]) ?? []).compactMap { ($0 as? URL)?.path ?? ($0 as? String) }
        }
        let added = paths(kSecCFErrorResourceAdded), altered = paths(kSecCFErrorResourceAltered), missing = paths(kSecCFErrorResourceMissing)
        let changed = added.count + altered.count + missing.count
        let base = url.path
        func relative(_ path: String) -> String { path.hasPrefix(base + "/") ? String(path.dropFirst(base.count + 1)) : path }

        let modified = changed > 0 || [errSecCSSignatureFailed, -67054 /* bad resource */, -67061, -67030 /* nested code modified */].contains(status)
        if modified {
            var details: [InspectorItem] = []
            let kinds = [
                (String(localized: "Changed", bundle: .greeceKit, comment: "Inspector row value: a file changed after the code was signed"), altered, "pencil"),
                (String(localized: "Added", bundle: .greeceKit, comment: "Inspector row value: a file added after the code was signed"), added, "plus"),
                (String(localized: "Missing", bundle: .greeceKit, comment: "Inspector row value: a signed file is missing"), missing, "minus"),
            ]
            for (label, list, symbol) in kinds {
                for path in list.prefix(20) { details.append(InspectorItem(symbol: symbol, title: relative(path), value: label, mono: false)) }
            }
            let subtitle = changed > 0
                ? String(localized: "\(changed) files changed since it was signed.", bundle: .greeceKit, comment: "Inspector row subtitle for Integrity. The argument is how many files changed")
                : String(localized: "Its contents no longer match the signature.", bundle: .greeceKit)
            return InspectorCheckResult(
                rows: [.item(InspectorItem(title: integrityLabel, subtitle: subtitle, value: String(localized: "Modified after signing", bundle: .greeceKit),
                                           tone: .critical, valueSymbol: "exclamationmark.octagon.fill", details: details))],
                badges: [InspectorBadge("modified", symbol: "exclamationmark.octagon.fill", title: String(localized: "Modified", bundle: .greeceKit, comment: "Badge: files changed after the code was signed"), tone: .critical,
                                        help: String(localized: "Files changed after it was signed. macOS may refuse to open it.", bundle: .greeceKit))])
        }
        let message = (SecCopyErrorMessageString(status, nil) as String?)
            ?? String(localized: "Error \(String(status))", bundle: .greeceKit, comment: "A signature check failed. The argument is an OSStatus code, such as “-67061”")
        // Strict validation rejects older signature formats (iOS apps' resource envelopes, for one)
        // that macOS still accepts. Nothing changed, so check again the way Gatekeeper does.
        if status != errSecCSUnsigned {
            var relaxed = flags
            relaxed.remove(SecCSFlags(rawValue: kSecCSStrictValidate))
            if SecStaticCodeCheckValidityWithErrors(code, relaxed, nil, nil) == errSecSuccess {
                log.info("Integrity check passed without strict validation (\(status, privacy: .public))")
                let subtitle = String(localized: "Signed in an older format that strict checks reject (\(message)).", bundle: .greeceKit,
                                      comment: "Inspector row subtitle for Integrity. The argument is the Security framework’s error message")
                return InspectorCheckResult(rows: [.item(InspectorItem(title: integrityLabel, subtitle: subtitle,
                                                                       value: unmodifiedValue, tone: .positive, valueSymbol: "checkmark.shield.fill"))])
            }
            // An obsolete resource seal (iOS apps on the Mac): the resources can't be checked, the code can.
            if status == -67013 {
                relaxed.insert(SecCSFlags(rawValue: kSecCSDoNotValidateResources))
                relaxed.remove(SecCSFlags(rawValue: kSecCSCheckNestedCode))
                if SecStaticCodeCheckValidityWithErrors(code, relaxed, nil, nil) == errSecSuccess {
                    return InspectorCheckResult(rows: [.item(InspectorItem(title: integrityLabel,
                                                                           subtitle: String(localized: "Its resources use an older seal that macOS can’t check, so only the code was verified.", bundle: .greeceKit),
                                                                           value: String(localized: "Code unmodified", bundle: .greeceKit, comment: "Inspector row value for Integrity"),
                                                                           tone: .positive, valueSymbol: "checkmark.shield.fill"))])
                }
            }
        }
        if status == errSecCSUnsigned {
            return InspectorCheckResult(rows: [.item(InspectorItem(title: integrityLabel, value: String(localized: "Not signed", bundle: .greeceKit, comment: "Inspector row value: the code has no signature"),
                                                                   tone: .critical, valueSymbol: "xmark.seal.fill"))])
        }
        return InspectorCheckResult(rows: [.item(InspectorItem(title: integrityLabel, subtitle: message,
                                                               value: String(localized: "Signature invalid", bundle: .greeceKit, comment: "Inspector row value for Integrity"),
                                                               tone: .critical, help: "OSStatus \(status)", valueSymbol: "exclamationmark.triangle.fill"))],
                                    badges: [InspectorBadge("modified", symbol: "exclamationmark.octagon.fill",
                                                            title: String(localized: "Invalid Signature", bundle: .greeceKit, comment: "Badge"), tone: .critical, help: message)])
    }
}
