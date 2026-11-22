import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The native inspector: a header with the icon, status badges, and grouped sections in the style
/// of System Settings. Optionally a second tab lists the files inside.
final class InspectorView: NSView, PreviewSettingsAware {
    private let model: InspectorModel

    init(page: InspectorPage, settings: PreviewSettings) {
        model = InspectorModel(page: page, settings: settings)
        super.init(frame: .zero)
        let hosting = NSHostingView(rootView: InspectorRoot(model: model))
        hosting.sizingOptions = []
        hosting.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.topAnchor.constraint(equalTo: topAnchor),
            hosting.bottomAnchor.constraint(equalTo: bottomAnchor),
            hosting.leadingAnchor.constraint(equalTo: leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        model.runChecks()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func apply(_ settings: PreviewSettings) { model.settings = settings }
}

@MainActor
final class InspectorModel: ObservableObject {
    @Published var page: InspectorPage
    @Published var settings: PreviewSettings
    @Published var showsFiles = false
    @Published var expandedSections: Set<String> = []
    let tree: FileNode?

    init(page: InspectorPage, settings: PreviewSettings) {
        self.page = page
        self.settings = settings
        if case .tree(let node, _, _)? = page.contents { tree = node } else { tree = nil }
    }

    func runChecks() {
        for check in page.checks {
            let id = check.id
            let run = check.run
            Task.detached(priority: .userInitiated) { [weak self] in
                let result = run()
                await self?.apply(result, to: id)
            }
        }
    }

    func apply(_ result: InspectorCheckResult, to id: String) {
        for index in page.sections.indices {
            let rows = page.sections[index].rows
            if let position = rows.firstIndex(where: { if case .pending(let pending, _) = $0 { return pending == id } else { return false } }) {
                page.sections[index].rows.replaceSubrange(position...position, with: result.rows)
            }
        }
        page.sections.removeAll { $0.rows.isEmpty }
        page.badges.removeAll { result.removeBadges.contains($0.id) }
        for badge in result.badges {
            if let existing = page.badges.firstIndex(where: { $0.id == badge.id }) {
                page.badges[existing] = badge
            } else {
                page.badges.append(badge)
            }
        }
    }
}

// MARK: - Layout

private struct InspectorRoot: View {
    @ObservedObject var model: InspectorModel

    var body: some View {
        VStack(spacing: 0) {
            if case .tree(_, let title, let count)? = model.page.contents, model.tree != nil {
                Picker("", selection: $model.showsFiles) {
                    Text("Info").tag(false)
                    Text(count.map { "\(title) (\($0.formatted()))" } ?? title).tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                Divider()
            }
            if model.showsFiles, let tree = model.tree {
                FileTreeRepresentable(root: tree, settings: model.settings)
            } else {
                InspectorForm(model: model)
            }
        }
    }
}

private struct InspectorForm: View {
    @ObservedObject var model: InspectorModel

    var body: some View {
        Form {
            Section {
            } header: {
                InspectorHeaderView(header: model.page.header, badges: model.page.badges)
            }
            ForEach(Array(model.page.sections.enumerated()), id: \.offset) { _, section in
                SectionView(section: section, model: model)
            }
        }
        .formStyle(.grouped)
    }
}

private struct SectionView: View {
    let section: InspectorSection
    @ObservedObject var model: InspectorModel

    var body: some View {
        let expanded = model.expandedSections.contains(section.id)
        let limit = section.visibleLimit.map { $0 < section.rows.count - 1 ? $0 : section.rows.count } ?? section.rows.count
        let visible = expanded ? section.rows : Array(section.rows.prefix(limit))
        Section {
            ForEach(Array(visible.enumerated()), id: \.offset) { _, row in
                RowView(row: row, settings: model.settings)
            }
            if !expanded && limit < section.rows.count {
                Button {
                    model.expandedSections.insert(section.id)
                } label: {
                    Text("Show All \(section.rows.count.formatted())")
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                .buttonStyle(.link)
            }
        } header: {
            // Explicit, so every section reads the same (Form styles the first header differently).
            if let title = section.title {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
            }
        } footer: {
            if let footer = section.footer {
                Text(footer)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

// MARK: - Header

private struct InspectorHeaderView: View {
    let header: InspectorHeader
    let badges: [InspectorBadge]

    var body: some View {
        VStack(spacing: 0) {
            IconView(icon: header.icon, size: 104)
                .padding(.bottom, 12)
            Text(header.title)
                .font(.system(size: 22, weight: .semibold))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .textSelection(.enabled)
            if let subtitle = header.subtitle {
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .padding(.top, 3)
                    .textSelection(.enabled)
            }
            if let identifier = header.identifier {
                Text(identifier)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.top, 2)
                    .textSelection(.enabled)
            }
            if !badges.isEmpty {
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(badges, id: \.id) { BadgeView(badge: $0) }
                }
                .padding(.top, 14)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .textCase(nil)
        .foregroundStyle(.primary)
    }
}

private struct BadgeView: View {
    let badge: InspectorBadge

    var body: some View {
        let color = badge.tone.color
        Label {
            Text(badge.title)
        } icon: {
            Image(systemName: badge.symbol)
                .imageScale(.small)
        }
        .labelStyle(BadgeLabelStyle())
        .font(.system(size: 11.5, weight: .medium))
        .foregroundStyle(badge.tone == .neutral ? AnyShapeStyle(.secondary) : AnyShapeStyle(color))
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule(style: .continuous).fill(color.opacity(badge.tone == .neutral ? 0.10 : 0.13)))
        .help(badge.help ?? badge.title)
    }
}

private struct BadgeLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon
            configuration.title
        }
    }
}

struct IconView: View {
    let icon: InspectorIcon
    let size: CGFloat

    var body: some View {
        switch icon {
        case .file(let url):
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        case .contentType(let identifier):
            Image(nsImage: NSWorkspace.shared.icon(for: UTType(identifier) ?? .data))
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        case .image(let image, let shape):
            switch shape.resolved(for: image) {
            case .asIs:
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size, height: size)
            case .iOS, .rounded:
                // Finder's app icons sit inside a grid with some margin; match that optical size.
                let inner = size * 0.82
                let radius = inner * (shape == .iOS ? 0.2237 : 0.18)
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: inner, height: inner)
                    .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.18), radius: size * 0.03, y: size * 0.015)
                    .frame(width: size, height: size)
            }
        case .symbol(let name, let tint):
            let inner = size * 0.8
            RoundedRectangle(cornerRadius: inner * 0.2237, style: .continuous)
                .fill(tint.color.gradient)
                .frame(width: inner, height: inner)
                .overlay(Image(systemName: name).font(.system(size: inner * 0.46, weight: .medium)).foregroundStyle(.white))
                .shadow(color: .black.opacity(0.15), radius: size * 0.03, y: size * 0.015)
                .frame(width: size, height: size)
        }
    }
}

// MARK: - Rows

private struct RowView: View {
    let row: InspectorRow
    let settings: PreviewSettings

    var body: some View {
        switch row {
        case .item(let item):
            if item.details.isEmpty {
                ItemView(item: item)
            } else {
                DisclosureGroup {
                    ForEach(Array(item.details.enumerated()), id: \.offset) { _, detail in
                        RowView(row: .item(detail), settings: settings)
                    }
                } label: {
                    ItemView(item: item)
                }
            }
        case .code(let code):
            CodeView(code: code, settings: settings)
        case .sizes(let sizes):
            SizesView(sizes: sizes)
        case .note(let note):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: note.symbol ?? note.tone.symbol)
                    .foregroundStyle(note.tone == .neutral ? AnyShapeStyle(.secondary) : AnyShapeStyle(note.tone.color))
                Text(note.text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        case .pending(_, let title):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(title).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
    }
}

private struct ItemView: View {
    let item: InspectorItem

    var body: some View {
        HStack(alignment: item.subtitle == nil ? .center : .top, spacing: 10) {
            if let symbol = item.symbol {
                if let tint = item.tint {
                    TileView(symbol: symbol, tint: tint)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 13))
                        .foregroundStyle(item.tone == .neutral ? AnyShapeStyle(.secondary) : AnyShapeStyle(item.tone.color))
                        .frame(width: 22)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(item.mono && item.value == nil ? .system(size: 12, design: .monospaced) : .body)
                    .lineLimit(2)
                    .truncationMode(.middle)
                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 12)
            if item.value == nil, item.tone == .caution || item.tone == .critical {
                // Worth a second look: a quiet marker rather than a coloured title.
                Image(systemName: item.tone == .critical ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(item.tone.color)
            }
            if let symbol = item.valueSymbol {
                Image(systemName: symbol)
                    .font(.system(size: 12))
                    .foregroundStyle(item.tone == .neutral ? AnyShapeStyle(.secondary) : AnyShapeStyle(item.tone.color))
            }
            if let value = item.value {
                Text(value)
                    .font(item.mono ? .system(size: 12, design: .monospaced) : .body)
                    .foregroundStyle(item.tone == .neutral ? AnyShapeStyle(.secondary) : AnyShapeStyle(item.tone.color))
                    .multilineTextAlignment(.trailing)
                    .lineLimit(item.mono ? 3 : 2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
        .help(item.help ?? "")
    }
}

private struct TileView: View {
    let symbol: String
    let tint: InspectorTint

    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(tint.color.gradient)
            .frame(width: 24, height: 24)
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white)
            )
    }
}

private struct CodeView: View {
    let code: InspectorCode
    let settings: PreviewSettings
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        DisclosureGroup {
            highlighted
                .font(.system(size: 11.5, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(nsColor: .textBackgroundColor).opacity(colorScheme == .dark ? 0.35 : 0.9)))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))
            if code.truncated {
                Text("Showing the beginning only.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } label: {
            ItemView(item: InspectorItem(symbol: code.symbol, title: code.title, subtitle: code.subtitle, tone: code.tone))
        }
    }

    private var highlighted: Text {
        let theme = settings.codeTheme
        let palette = colorScheme == .dark ? theme.dark : theme.light
        let effective = CodeTheme(id: theme.id, name: theme.name, light: palette, dark: palette, boldKeywords: theme.boldKeywords)
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular),
            .foregroundColor: NSColor(hex: palette.foreground),
        ]
        guard let attributed = Highlighter.shared.attributed(code.text, grammar: code.grammar, base: base, theme: effective) else {
            return Text(code.text)
        }
        var result = AttributedString()
        attributed.enumerateAttributes(in: NSRange(location: 0, length: attributed.length)) { attributes, range, _ in
            var piece = AttributedString(attributed.attributedSubstring(from: range).string)
            if let color = attributes[.foregroundColor] as? NSColor { piece.foregroundColor = Color(nsColor: color) }
            if let font = attributes[.font] as? NSFont, font.fontDescriptor.symbolicTraits.contains(.bold) {
                piece.font = .system(size: 11.5, weight: .semibold, design: .monospaced)
            }
            result += piece
        }
        return Text(result)
    }
}

private struct SizesView: View {
    let sizes: InspectorSizes

    var body: some View {
        let total = max(sizes.total, sizes.segments.reduce(0) { $0 + $1.bytes }, 1)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Total")
                Spacer()
                Text(Format.bytes(sizes.total)).foregroundStyle(.secondary).monospacedDigit()
            }
            GeometryReader { proxy in
                HStack(spacing: 1.5) {
                    ForEach(Array(sizes.segments.enumerated()), id: \.offset) { _, segment in
                        Rectangle()
                            .fill(segment.tint.color.gradient)
                            .frame(width: max(2, proxy.size.width * CGFloat(Double(segment.bytes) / Double(total)) - 1.5))
                    }
                    Spacer(minLength: 0)
                }
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(.quaternary))
            }
            .frame(height: 14)
            FlowLayout(spacing: 14, lineSpacing: 6, alignment: .leading) {
                ForEach(Array(sizes.segments.enumerated()), id: \.offset) { _, segment in
                    HStack(spacing: 5) {
                        Circle().fill(segment.tint.color).frame(width: 8, height: 8)
                        Text(segment.title)
                        Text(Format.bytes(segment.bytes)).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .font(.system(size: 11.5))
                    .help(segment.detail ?? segment.title)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

private struct FileTreeRepresentable: NSViewRepresentable {
    let root: FileNode
    let settings: PreviewSettings

    func makeNSView(context: Context) -> FileTreeView {
        FileTreeView(root: root, settings: settings, showsKind: false)
    }

    func updateNSView(_ view: FileTreeView, context: Context) {}
}

// MARK: - Flow layout

/// Wraps its children onto as many lines as needed, centring each line (badges) or not (legends).
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6
    var alignment: HorizontalAlignment = .center

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let lines = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = lines.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(max(0, lines.count - 1))
        let width = lines.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for line in arrange(width: bounds.width, subviews: subviews) {
            var x = alignment == .center ? bounds.minX + (bounds.width - line.width) / 2 : bounds.minX
            for index in line.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (line.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += line.height + lineSpacing
        }
    }

    private struct Line { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Line] {
        var lines: [Line] = []
        var current = Line()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width && !current.indices.isEmpty {
                lines.append(current)
                current = Line()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { lines.append(current) }
        return lines
    }
}

// MARK: - Colours

extension InspectorTint {
    var color: Color { Color(nsColor: nsColor) }

    var nsColor: NSColor {
        switch self {
        case .blue: return .systemBlue
        case .green: return .systemGreen
        case .orange: return .systemOrange
        case .red: return .systemRed
        case .purple: return .systemPurple
        case .pink: return .systemPink
        case .teal: return .systemTeal
        case .indigo: return .systemIndigo
        case .yellow: return .systemYellow
        case .gray: return .systemGray
        case .brown: return .systemBrown
        case .mint: return .systemMint
        case .cyan: return .systemCyan
        }
    }
}

extension InspectorTone {
    var color: Color {
        switch self {
        case .neutral: return .secondary
        case .positive: return Color(nsColor: .systemGreen)
        case .accent: return .accentColor
        case .caution: return Color(nsColor: .systemOrange)
        case .critical: return Color(nsColor: .systemRed)
        }
    }

    var symbol: String {
        switch self {
        case .neutral, .accent: return "info.circle"
        case .positive: return "checkmark.circle"
        case .caution: return "exclamationmark.triangle"
        case .critical: return "xmark.octagon"
        }
    }
}
