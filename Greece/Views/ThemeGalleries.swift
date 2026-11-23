import SwiftUI
import AppKit
import GreeceKit

// MARK: - Code themes

/// Every code theme as a card of real highlighted code, drawn natively from its palette.
/// Grouped into pairs (light and dark), light-only and dark-only, and searchable.
struct CodeThemeGallery: View {
    @Binding var selection: String
    @State private var query = ""

    private var groups: [(title: String, themes: [CodeTheme])] {
        let order: [(String, CodeTheme.Variants)] = [
            (String(localized: "Light and Dark", comment: "Group of code themes that have both variants"), .pair),
            (String(localized: "Light", comment: "Code theme variant or group"), .light),
            (String(localized: "Dark", comment: "Code theme variant or group"), .dark),
        ]
        return order.compactMap { title, variants in
            let themes = CodeTheme.group(variants).filter { query.isEmpty || $0.matches(query) }
            return themes.isEmpty ? nil : (title, themes)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("\(CodeTheme.all.count) themes", comment: "How many code themes there are")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                SearchField(text: $query, prompt: String(localized: "Search Themes", comment: "Search field placeholder"))
                    .frame(width: 190)
            }
            if groups.isEmpty {
                Text("No themes match “\(query)”", comment: "Theme search; the argument is what was typed")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            }
            ForEach(groups, id: \.title) { group in
                VStack(alignment: .leading, spacing: 8) {
                    Text(group.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 138, maximum: 190), spacing: 14, alignment: .top)],
                              alignment: .leading, spacing: 14) {
                        ForEach(group.themes) { theme in
                            CodeThemeCard(theme: theme, selected: theme.id == selection) { selection = theme.id }
                        }
                    }
                }
            }
        }
        .padding(.vertical, 6)
    }
}

private struct CodeThemeCard: View {
    let theme: CodeTheme
    let selected: Bool
    let choose: () -> Void
    @State private var hovering = false

    private var subtitle: String {
        switch theme.variants {
        case .pair:
            if let light = theme.lightName, let dark = theme.darkName { return "\(light) · \(dark)" }
            return String(localized: "Light · Dark", comment: "A code theme with both variants")
        case .light: return String(localized: "Light", comment: "Code theme variant or group")
        case .dark: return String(localized: "Dark", comment: "Code theme variant or group")
        }
    }

    var body: some View {
        Button(action: choose) {
            VStack(alignment: .leading, spacing: 6) {
                swatch
                    .frame(height: 74)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(Color.primary.opacity(hovering ? 0.28 : 0.14), lineWidth: 0.5)
                    }
                    .padding(3)
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2.5)
                    }
                    .overlay(alignment: .topTrailing) {
                        if selected {
                            Image(systemName: "checkmark.circle.fill")
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, Color.accentColor)
                                .font(.system(size: 15, weight: .semibold))
                                .background(Circle().fill(.white).padding(2))
                                .offset(x: 4, y: -4)
                        }
                    }
                VStack(alignment: .leading, spacing: 1) {
                    Text(theme.name)
                        .font(.callout.weight(selected ? .semibold : .regular))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)
                .padding(.horizontal, 3)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(theme.name)
        .accessibilityLabel([theme.name, subtitle].joined(separator: ", "))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private var swatch: some View {
        if theme.variants == .pair {
            // Like System Settings' Auto appearance: light above the diagonal, dark below.
            ZStack {
                CodeSwatch(theme: theme, palette: theme.light)
                CodeSwatch(theme: theme, palette: theme.dark)
                    .mask(Diagonal())
            }
        } else {
            CodeSwatch(theme: theme, palette: theme.light)
        }
    }
}

/// The lower-right half of a rectangle.
private struct Diagonal: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.0))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.closeSubpath()
        }
    }
}

/// A few lines of Swift, highlighted with a palette.
struct CodeSwatch: View {
    let theme: CodeTheme
    let palette: CodeTheme.Palette

    enum Token { case plain, comment, keyword, string, number, function, type, attribute, variable, builtIn, meta }

    static let lines: [[(String, Token)]] = [
        [("// Ferries at dawn", .comment)],
        [("@MainActor ", .meta), ("struct", .keyword), (" ", .plain), ("Ferry", .type), (" {", .plain)],
        [("  ", .plain), ("let", .keyword), (" name = ", .plain), ("\"Naxos\"", .string)],
        [("  ", .plain), ("var", .keyword), (" knots = ", .plain), ("21.5", .number)],
        [("  ", .plain), ("func", .keyword), (" ", .plain), ("depart", .function), ("(at: ", .plain), ("Date", .type), (")", .plain)],
        [("    ", .plain), ("print", .builtIn), ("(", .plain), ("self", .variable), (".name)", .plain)],
    ]

    private func color(_ token: Token) -> Color {
        let hex: String
        switch token {
        case .plain: hex = palette.foreground
        case .comment: hex = palette.comment
        case .keyword: hex = palette.keyword
        case .string: hex = palette.string
        case .number: hex = palette.number
        case .function: hex = palette.function
        case .type: hex = palette.type
        case .attribute: hex = palette.attribute
        case .variable: hex = palette.variable
        case .builtIn: hex = palette.builtIn
        case .meta: hex = palette.meta
        }
        return Color(hex: hex)
    }

    private func line(_ tokens: [(String, Token)]) -> Text {
        tokens.reduce(Text(verbatim: "")) { result, token in
            var piece = Text(token.0).foregroundColor(color(token.1))
            if token.1 == .keyword && theme.boldKeywords { piece = piece.fontWeight(.bold) }
            if token.1 == .comment && theme.italicComments { piece = piece.italic() }
            return result + piece
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1.5) {
            ForEach(Self.lines.indices, id: \.self) { index in
                line(Self.lines[index])
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .font(.system(size: 8.5, design: .monospaced))
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(hex: palette.background))
        .clipped()
        .accessibilityHidden(true)
    }
}

// MARK: - Reading themes

/// Every Markdown reading theme as a miniature page in its own type and colours.
struct ReadingThemeGallery: View {
    @Binding var selection: String
    let dark: Bool
    let choose: (ReadingTheme) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 116, maximum: 150), spacing: 16, alignment: .top)],
                  alignment: .leading, spacing: 16) {
            ForEach(ReadingTheme.all) { theme in
                ReadingThemeCard(theme: theme, dark: dark, selected: theme.id == selection) { choose(theme) }
            }
        }
        .padding(.vertical, 6)
    }
}

private struct ReadingThemeCard: View {
    let theme: ReadingTheme
    let dark: Bool
    let selected: Bool
    let choose: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: choose) {
            VStack(spacing: 7) {
                MiniPage(theme: theme, palette: theme.palette(dark: dark))
                    .aspectRatio(0.8, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color.primary.opacity(hovering ? 0.28 : 0.14), lineWidth: 0.5)
                    }
                    .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
                    .padding(3)
                    .overlay {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2.5)
                    }
                    .overlay(alignment: .topTrailing) {
                        if selected {
                            Image(systemName: "checkmark.circle.fill")
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, Color.accentColor)
                                .font(.system(size: 15, weight: .semibold))
                                .background(Circle().fill(.white).padding(2))
                                .offset(x: 4, y: -4)
                        }
                    }
                VStack(spacing: 1) {
                    Text(theme.name)
                        .font(.callout.weight(selected ? .semibold : .regular))
                    Text(theme.summary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2, reservesSpace: true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(theme.summary)
        .accessibilityLabel(Text("\(theme.name) reading theme. \(theme.summary)",
                                 comment: "VoiceOver; the arguments are a theme’s name and its one-line description"))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A page of a Markdown document, a few centimetres tall.
private struct MiniPage: View {
    let theme: ReadingTheme
    let palette: ReadingTheme.Palette

    private func font(_ face: ReadingTheme.Face, _ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        switch face {
        case .system: return .system(size: size, weight: weight)
        case .serif: return .system(size: size, weight: weight, design: .serif)
        case .rounded: return .system(size: size, weight: weight, design: .rounded)
        case .mono: return .system(size: size * 0.9, weight: weight, design: .monospaced)
        case .family(let name): return .custom(name, size: size).weight(weight)
        }
    }

    private var centered: Bool { ["newsprint", "academic", "paper", "whitey"].contains(theme.id) }
    private var accent: Color { theme.isNative ? .accentColor : Color(hex: palette.accent) }

    /// Capitals follow the app's language (Greek drops its accents, Turkish dots its İ).
    private func capitals(_ text: String) -> String {
        text.uppercased(with: Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en"))
    }

    var body: some View {
        let text = Color(hex: palette.text)
        let title = String(localized: "The Cyclades", comment: "Theme thumbnail: title of a tiny sample document about Greek islands")
        let heading = String(localized: "Getting there", comment: "Theme thumbnail: a section heading in the sample document")
        let link = Text("ferry", comment: "Theme thumbnail: the linked word in the sample sentence")
            .foregroundColor(accent).underline(["newsprint", "paper", "notes", "graphite", "story"].contains(theme.id))
        VStack(alignment: centered ? .center : .leading, spacing: 4) {
            Text(verbatim: theme.id == "terminal" ? "# " + capitals(title) : title)
                .font(font(theme.headingFace, 12.5, theme.id == "academic" || theme.id == "paper" ? .regular : .bold))
                .foregroundColor(Color(hex: palette.heading))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if theme.id == "newsprint" || theme.id == "academic" || theme.id == "github" {
                Rectangle().fill(Color(hex: palette.heading).opacity(theme.id == "github" ? 0.15 : 0.6)).frame(height: 0.75)
            }
            Text("A ring of islands in the Aegean, reached by \(link) from Piraeus each morning.",
                 comment: "Theme thumbnail: the sample sentence; the argument is the linked word “ferry”")
                .foregroundColor(text)
                .font(font(theme.bodyFace, 6.4))
                .lineSpacing(1.2)
                .multilineTextAlignment(centered ? .center : .leading)
                .frame(maxWidth: .infinity, alignment: centered ? .center : .leading)
            if theme.id == "docs" {
                Rectangle().fill(text.opacity(0.15)).frame(height: 0.75).padding(.top, 2)
            }
            Text(verbatim: theme.id == "academic" ? "1  " + heading : theme.id == "terminal" ? "## " + heading
                 : theme.id == "newsprint" ? capitals(heading) : heading)
                .font(font(theme.headingFace, theme.id == "newsprint" ? 6.5 : 8, theme.id == "paper" ? .semibold : .bold))
                .tracking(theme.id == "newsprint" ? 0.8 : 0)
                .foregroundColor(Color(hex: palette.heading))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 2)
            HStack(spacing: 4) {
                Rectangle()
                    .fill(theme.id == "graphite" || theme.id == "nord" ? accent : Color(hex: palette.tertiary))
                    .frame(width: 1.5)
                Text("The slow boats have better decks.", comment: "Theme thumbnail: a quotation in the sample document")
                    .font(font(theme.bodyFace, 6.2).italic())
                    .foregroundColor(Color(hex: palette.secondary))
                    .lineLimit(2)
            }
            .fixedSize(horizontal: false, vertical: true)
            RoundedRectangle(cornerRadius: theme.id == "terminal" ? 0 : 2.5, style: .continuous)
                .fill(text.opacity(0.07))
                .frame(height: 13)
                .overlay(alignment: .leading) {
                    HStack(spacing: 2.5) {
                        Capsule().fill(accent.opacity(0.85)).frame(width: 12, height: 2.4)
                        Capsule().fill(text.opacity(0.5)).frame(width: 22, height: 2.4)
                        Capsule().fill(text.opacity(0.3)).frame(width: 9, height: 2.4)
                    }
                    .padding(.leading, 5)
                }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9)
        .padding(.top, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(theme.isNative ? Color(nsColor: .textBackgroundColor) : Color(hex: palette.page))
        .accessibilityHidden(true)
    }
}

// MARK: - Diagram themes

/// A small flowchart in a diagram theme's colours: box, arrow, box, note.
struct DiagramSwatch: View {
    let palette: DiagramTheme.Palette
    var card = true

    var body: some View {
        let line = Color(hex: palette.line)
        HStack(spacing: 0) {
            node(palette.node)
            arrow(line)
            node(palette.secondary)
            arrow(line)
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Color(hex: palette.note))
                .overlay(RoundedRectangle(cornerRadius: 2, style: .continuous).strokeBorder(line.opacity(0.5), lineWidth: 0.75))
                .frame(width: 15, height: 12)
        }
        .padding(.horizontal, 7)
        .frame(width: 92, height: 26)
        .background(card ? Color(hex: palette.background) : Color.primary.opacity(0.04),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
        .accessibilityHidden(true)
    }

    private func node(_ fill: String) -> some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(Color(hex: fill))
            .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(Color(hex: palette.border), lineWidth: 1))
            .frame(width: 20, height: 13)
    }

    private func arrow(_ color: Color) -> some View {
        Rectangle().fill(color).frame(width: 8, height: 1)
    }
}

extension DiagramTheme {
    /// The palette Settings shows for the current appearance.
    func swatch(dark: Bool, settings: PreviewSettings) -> DiagramTheme.Palette {
        let pair = palettes(code: settings.codeTheme, reading: settings.markdownTheme)
        return dark ? pair.dark : pair.light
    }

    var paintsCard: Bool {
        switch style {
        case .palette(_, _, let card): return card
        case .builtIn: return false
        case .matchCode, .matchReading: return true
        }
    }
}

// MARK: - Search field

/// AppKit's search field: the standard look, clear button and keyboard behaviour.
struct SearchField: NSViewRepresentable {
    @Binding var text: String
    var prompt: String

    /// Takes focus only when someone clicks or tabs into it, never as the window's first key view.
    final class Field: NSSearchField {
        override func becomeFirstResponder() -> Bool {
            guard let event = NSApp.currentEvent, [.leftMouseDown, .keyDown].contains(event.type) else { return false }
            return super.becomeFirstResponder()
        }
    }

    func makeNSView(context: Context) -> NSSearchField {
        let field = Field()
        field.placeholderString = prompt
        field.controlSize = .regular
        field.sendsSearchStringImmediately = true
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        if field.stringValue != text { field.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}
