import Foundation

/// A disk image's own signature and notarization (UDIF keeps its code signature after the data,
/// located by the trailer), added to the page the disk image reader builds.
enum DiskImageSigning {
    static func add(to page: inout InspectorPage, image: DiskImage) {
        guard image.container == .udif else { return }
        var signature: CodeSignature?
        if let range = image.codeSignatureRange, let bytes = try? FileBytes(url: image.url),
           let data = bytes.read(range.offset, Int(range.length)) {
            signature = CodeSignature(data: data)
        }
        let section: InspectorSection
        if let signature {
            let output = SigningSection.build(signature: signature, url: image.url, subject: .diskImage)
            page.badges += output.badges
            page.checks += output.checks
            section = output.section
        } else {
            // Unsigned disk images are common and harmless: the apps inside carry their own signatures.
            section = InspectorSection("signature", title: "Signature", rows: [
                .item(InspectorItem(title: "Disk Image", subtitle: "Most disk images aren’t signed. The apps inside carry their own signatures.",
                                    value: "Not signed")),
            ])
        }
        let position = page.sections.firstIndex { $0.id == "apps" }.map { $0 + 1 } ?? 0
        page.sections.insert(section, at: min(position, page.sections.count))
    }
}
