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

        var noun: String {
            switch self {
            case .bundle: return "app"
            case .executable: return "file"
            case .diskImage: return "disk image"
            case .archived: return "app"
            }
        }
    }

    /// - Parameters:
    ///   - url: the code on disk, for Security framework checks (nil inside archives).
    ///   - ticket: a stapled ticket found outside the signature (bundles keep theirs in CodeResources).
    static func build(signature: CodeSignature?, url: URL?, subject: Subject, ticket: NotarizationTicket? = nil,
                      fileCount: Int? = nil, totalSize: UInt64? = nil) -> Output {
        guard let signature else {
            let rows: [InspectorRow] = [.note(InspectorNote(symbol: "xmark.seal", text: "Not code signed. macOS won’t open it unless you make an exception, and nothing vouches for who made it.", tone: .critical))]
            return Output(section: InspectorSection("signature", title: "Signature", rows: rows), badges: [SignerKind.unsignedBadge], checks: [])
        }

        var badges: [InspectorBadge] = []
        var rows: [InspectorRow] = []
        var checks: [InspectorCheck] = []
        var signer = signature.signer
        if signature.isPlatformBinary && signer == .adHoc { signer = .apple }
        badges.append(signer.badge)

        let summaries = signature.certificates.map(CertificateSummary.init(certificate:))
        if let leaf = summaries.first {
            rows.append(.item(.field("Team", teamName(leaf, teamID: signature.teamID))))
        } else if signature.flags.contains(.linkerSigned) {
            rows.append(.item(.field("Signed by", "The linker (no certificate)", help: "Signed automatically by the linker so it can run on Apple silicon. It doesn’t identify a developer.")))
        } else {
            rows.append(.item(.field("Signed by", "No certificate (ad hoc)", help: "An ad hoc signature proves the code is intact, not who made it.")))
        }
        if let identifier = signature.identifier {
            rows.append(.item(.field("Identifier", identifier, mono: true)))
        }

        // Notarization: a stapled ticket answers offline; otherwise Security framework may know.
        let ticket = ticket ?? signature.ticket
        let needsNotarization = signer == .developerID
        if let ticket {
            let matches = signature.cdhashes.contains { ticket.covers($0) } || (signature.cdhash.map(ticket.covers) ?? false)
            let date = ticket.notarizedAt.map { "Notarized " + Format.date($0) } ?? "Notarized"
            if matches || subject == .diskImage {
                rows.append(.item(InspectorItem(title: "Notarization", subtitle: "Apple’s ticket is stapled, so Gatekeeper can check it offline.",
                                                value: date, tone: .positive, valueSymbol: "checkmark.seal.fill")))
                badges.append(InspectorBadge("notarization", symbol: "checkmark.seal.fill", title: "Notarized", tone: .positive,
                                             help: "Apple scanned this \(subject.noun) for malware and stapled a ticket to it."))
            } else {
                rows.append(.item(InspectorItem(title: "Notarization", subtitle: "A ticket is stapled, but it doesn’t list this code. It may have changed after notarization.",
                                                value: "Ticket doesn’t match", tone: .caution, valueSymbol: "exclamationmark.triangle.fill")))
            }
        } else if needsNotarization {
            if let url {
                rows.append(.pending(id: "notarization", title: "Checking notarization…"))
                checks.append(InspectorCheck(id: "notarization") { notarizationCheck(url: url) })
            } else {
                rows.append(.item(notStapled))
            }
        } else if signer == .appStore || signer == .apple {
            rows.append(.item(InspectorItem(title: "Notarization", subtitle: signer == .apple ? "Apple’s own software isn’t notarized." : "App Store apps are reviewed instead of notarized.", value: "Not needed")))
        }

        // Integrity: only for code on disk, after first paint.
        if let url {
            rows.append(.pending(id: "integrity", title: "Checking the signature…"))
            let known: Bool? = fileCount.flatMap { count in totalSize.map { isLarge(count: count, bytes: $0) } }
            checks.append(InspectorCheck(id: "integrity") {
                // Hashing every resource of a multi-gigabyte bundle takes minutes: check only the code then.
                let large = known ?? (subject == .bundle ? measureIsLarge(url) : false)
                return integrityCheck(url: url, subject: subject, skipResources: large)
            })
        }

        if let date = signature.timestamp ?? signature.signingTime {
            rows.append(.item(.field(signature.timestamp != nil ? "Timestamp" : "Signing Time", Format.dateTime(date),
                                     help: signature.timestamp != nil ? "A secure timestamp from Apple proves when it was signed." : "The signing time the developer’s Mac reported.")))
        }
        if signature.hasHardenedRuntime {
            badges.append(InspectorBadge("runtime", symbol: "lock.shield", title: "Hardened Runtime", tone: .positive,
                                         help: "Protects against code injection, library hijacking and memory tampering."))
            rows.append(.item(.field("Hardened Runtime", signature.runtimeVersion.map { "On (SDK \($0))" } ?? "On")))
        } else if subject != .diskImage && subject != .archived && !signature.isPlatformBinary {
            rows.append(.item(.field("Hardened Runtime", "Off", help: "Without the hardened runtime, other code can more easily inject into or debug this process.")))
        }
        if !summaries.isEmpty {
            rows.append(.item(certificateRow(summaries, timestamped: signature.timestamp != nil)))
        }
        if let cdhash = signature.cdhash {
            rows.append(.item(.field("CDHash", cdhash.hexString, mono: true, help: "The hash that identifies exactly this code (\(signature.hashName)).")))
        }
        return Output(section: InspectorSection("signature", title: "Signature", rows: rows), badges: badges, checks: checks)
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
        return InspectorItem(title: "Certificate", value: kind, help: leaf.commonName, details: details)
    }

    static var notStapled: InspectorItem {
        InspectorItem(title: "Notarization", subtitle: "No ticket is stapled. Gatekeeper checks with Apple online the first time it opens.", value: "Not stapled")
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
            rows: [.item(InspectorItem(title: "Notarization", subtitle: "macOS has Apple’s notarization ticket for this code.", value: "Notarized", tone: .positive, valueSymbol: "checkmark.seal.fill"))],
            badges: [InspectorBadge("notarization", symbol: "checkmark.seal.fill", title: "Notarized", tone: .positive, help: "Apple scanned this code for malware and issued a notarization ticket.")])
    }

    static func integrityCheck(url: URL, subject: Subject, skipResources: Bool) -> InspectorCheckResult {
        let started = Date()
        guard let code = staticCode(url) else {
            return InspectorCheckResult(rows: [.item(InspectorItem(title: "Integrity", value: "Couldn’t be checked"))])
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
            let subtitle = skipResources ? "The code is intact. Resources weren’t checked because the \(subject.noun) is very large." : nil
            return InspectorCheckResult(rows: [.item(InspectorItem(title: "Integrity", subtitle: subtitle,
                                                                   value: "Unmodified since signing", tone: .positive, valueSymbol: "checkmark.shield.fill"))])
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
            for (label, list, symbol) in [("Changed", altered, "pencil"), ("Added", added, "plus"), ("Missing", missing, "minus")] {
                for path in list.prefix(20) { details.append(InspectorItem(symbol: symbol, title: relative(path), value: label, mono: false)) }
            }
            let subtitle = changed > 0 ? "\(Format.count(changed, "file")) changed since it was signed." : "Its contents no longer match the signature."
            return InspectorCheckResult(
                rows: [.item(InspectorItem(title: "Integrity", subtitle: subtitle, value: "Modified after signing",
                                           tone: .critical, valueSymbol: "exclamationmark.octagon.fill", details: details))],
                badges: [InspectorBadge("modified", symbol: "exclamationmark.octagon.fill", title: "Modified", tone: .critical,
                                        help: "Files changed after it was signed. macOS may refuse to open it.")])
        }
        let message = (SecCopyErrorMessageString(status, nil) as String?) ?? "Error \(status)"
        if status == errSecCSUnsigned {
            return InspectorCheckResult(rows: [.item(InspectorItem(title: "Integrity", value: "Not signed", tone: .critical, valueSymbol: "xmark.seal.fill"))])
        }
        return InspectorCheckResult(rows: [.item(InspectorItem(title: "Integrity", subtitle: message,
                                                               value: "Signature invalid", tone: .critical, help: "OSStatus \(status)", valueSymbol: "exclamationmark.triangle.fill"))],
                                    badges: [InspectorBadge("modified", symbol: "exclamationmark.octagon.fill", title: "Invalid Signature", tone: .critical, help: message)])
    }
}
