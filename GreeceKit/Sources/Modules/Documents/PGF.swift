import AppKit

/// Interprets the PGF that matplotlib writes (`savefig("figure.pgf")`): paths, colours, line
/// widths, dashes, opacity, clipping, reusable marker objects, text and embedded images. The
/// result draws as SVG (for pages) or straight into Core Graphics (for thumbnails).
struct PGFPicture {
    struct Style {
        var fill: (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat)?
        var stroke: (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat)?
        var lineWidth: CGFloat = 0.4
        var dash: [CGFloat] = []
        var dashPhase: CGFloat = 0
        var cap: CGLineCap = .butt
        var join: CGLineJoin = .miter
        var evenOdd = false
    }

    struct Run {
        var text: String
        var script = 0          // 1 superscript, -1 subscript
        var italic = false
    }

    struct Text {
        var origin: CGPoint
        var rotation: CGFloat     // degrees, counter-clockwise
        var horizontal: Int       // -1 left, 0 centre, 1 right
        var vertical: Int         // 1 top, 0 centre, -1 bottom, -2 baseline
        var size: CGFloat
        var color: (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat)
        var sans: Bool
        var bold: Bool
        var runs: [Run]
    }

    indirect enum Node {
        case group(clip: CGPath?, children: [Node])
        case path(CGPath, Style)
        case text(Text)
        case image(Data, CGRect)
    }

    var bounds: CGRect
    var root: [Node]
    var pathCount = 0
    var textCount = 0

    var isEmpty: Bool { pathCount == 0 && textCount == 0 }
}

enum PGF {
    static let commandLimit = 600_000
    static let elementLimit = 400_000

    /// Parses matplotlib-style PGF. `image` loads raster images it references (relative names).
    static func parse(_ source: String, image: @escaping (String) -> Data? = { _ in nil }) -> PGFPicture? {
        var interpreter = Interpreter(chars: Array(source.unicodeScalars), image: image)
        interpreter.run()
        guard let bounds = interpreter.bounds ?? interpreter.extent, bounds.width > 0, bounds.height > 0 else { return nil }
        var picture = PGFPicture(bounds: bounds, root: interpreter.finish())
        picture.pathCount = interpreter.paths
        picture.textCount = interpreter.texts
        return picture.isEmpty ? nil : picture
    }

    // MARK: - Interpreter

    private struct State {
        var fill: (r: CGFloat, g: CGFloat, b: CGFloat) = (0, 0, 0)
        var stroke: (r: CGFloat, g: CGFloat, b: CGFloat) = (0, 0, 0)
        var fillOpacity: CGFloat = 1
        var strokeOpacity: CGFloat = 1
        var lineWidth: CGFloat = 0.4
        var dash: [CGFloat] = []
        var dashPhase: CGFloat = 0
        var cap: CGLineCap = .butt
        var join: CGLineJoin = .miter
        var transform = CGAffineTransform.identity
        var evenOdd = false
    }

    private final class GroupBox {
        var clip: CGPath?
        var children: [PGFPicture.Node] = []
        let isScope: Bool
        init(clip: CGPath?, isScope: Bool) { self.clip = clip; self.isScope = isScope }
    }

    private struct Interpreter {
        let chars: [Unicode.Scalar]
        let image: (String) -> Data?
        var i = 0
        var state = State()
        var stateStack: [State] = []
        var groups: [GroupBox] = [GroupBox(clip: nil, isScope: true)]
        var path = CGMutablePath()
        var colors: [String: (CGFloat, CGFloat, CGFloat)] = [:]
        var objects: [String: String] = [:]
        var bounds: CGRect?
        var extent: CGRect?
        var commands = 0
        var paths = 0
        var texts = 0
        var elements = 0
        var objectDepth = 0
        let deadline = Date().addingTimeInterval(2)
        var stopped = false

        init(chars: [Unicode.Scalar], image: @escaping (String) -> Data?) {
            self.chars = chars
            self.image = image
        }

        mutating func finish() -> [PGFPicture.Node] {
            while groups.count > 1 { closeGroup() }
            return groups[0].children
        }

        mutating func run() {
            while i < chars.count, !stopped {
                let c = chars[i]
                if c == "%" { while i < chars.count, chars[i] != "\n" { i += 1 }; continue }
                if c != "\\" { i += 1; continue }
                i += 1
                let name = readName()
                commands += 1
                if commands > commandLimit || (commands & 4095 == 0 && Date() > deadline) { stopped = true; return }
                command(name)
            }
        }

        // MARK: Reading

        mutating func readName() -> String {
            var name = ""
            while i < chars.count, CharacterSet.letters.contains(chars[i]) || chars[i] == "@" { name.unicodeScalars.append(chars[i]); i += 1 }
            if name.isEmpty, i < chars.count { name.unicodeScalars.append(chars[i]); i += 1 }
            return name
        }

        mutating func skipSpace() { while i < chars.count, chars[i] == " " || chars[i] == "\n" || chars[i] == "\t" || chars[i] == "\r" { i += 1 } }

        mutating func group() -> String {
            skipSpace()
            guard i < chars.count, chars[i] == "{" else { return "" }
            var depth = 0
            var out = String.UnicodeScalarView()
            while i < chars.count {
                let c = chars[i]
                if c == "\\" && i + 1 < chars.count { out.append(c); out.append(chars[i + 1]); i += 2; continue }
                if c == "{" { depth += 1; if depth == 1 { i += 1; continue } }
                if c == "}" { depth -= 1; if depth == 0 { i += 1; break } }
                out.append(c)
                i += 1
            }
            return String(out)
        }

        mutating func optional() -> String? {
            skipSpace()
            guard i < chars.count, chars[i] == "[" else { return nil }
            i += 1
            var out = String.UnicodeScalarView()
            var depth = 0
            while i < chars.count {
                let c = chars[i]
                if c == "{" { depth += 1 } else if c == "}" { depth -= 1 } else if c == "]" && depth == 0 { i += 1; break }
                out.append(c)
                i += 1
            }
            return String(out)
        }

        // MARK: Commands

        mutating func command(_ name: String) {
            switch name {
            case "begin":
                let env = group()
                if env == "pgfscope" { pushScope() }
            case "end":
                let env = group()
                if env == "pgfscope" { popScope() }
            case "pgfpathmoveto":
                if let p = point(group()) { path.move(to: p.applying(state.transform)); note(p.applying(state.transform)) }
            case "pgfpathlineto":
                if let p = point(group()), allowElement() { path.addLine(to: p.applying(state.transform)); note(p.applying(state.transform)) }
            case "pgfpathcurveto":
                let a = point(group()), b = point(group()), c = point(group())
                if let a, let b, let c {
                    let t = state.transform
                    if allowElement() { path.addCurve(to: c.applying(t), control1: a.applying(t), control2: b.applying(t)) }
                    note(c.applying(t))
                }
            case "pgfpathquadraticcurveto":
                let control = point(group()), end = point(group())
                if let control, let end {
                    let t = state.transform
                    if allowElement() { path.addQuadCurve(to: end.applying(t), control: control.applying(t)) }
                    note(end.applying(t))
                }
            case "pgfpathclose":
                if !path.isEmpty { path.closeSubpath() }
            case "pgfpathrectangle":
                if let origin = point(group()), let size = point(group()) {
                    let rect = CGRect(origin: origin, size: CGSize(width: size.x, height: size.y))
                    if allowElement() { path.addRect(rect, transform: state.transform) }
                    note(rect.origin.applying(state.transform)); note(CGPoint(x: rect.maxX, y: rect.maxY).applying(state.transform))
                }
            case "pgfpathcircle":
                if let centre = point(group()), let radius = dimension(group()) {
                    let rect = CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2)
                    if allowElement() { path.addEllipse(in: rect, transform: state.transform) }
                }
            case "pgfpathellipse":
                if let centre = point(group()), let a = point(group()), let b = point(group()) {
                    let rect = CGRect(x: centre.x - abs(a.x), y: centre.y - abs(b.y), width: abs(a.x) * 2, height: abs(b.y) * 2)
                    if allowElement() { path.addEllipse(in: rect, transform: state.transform) }
                }
            case "pgfusepath":
                usePath(group())
            case "pgfsetlinewidth":
                if let w = dimension(group()) { state.lineWidth = max(0, w) }
            case "pgfsetdash":
                let pattern = group()
                let phase = group()
                state.dash = pattern.split(whereSeparator: { $0 == "{" || $0 == "}" }).compactMap { dimension(String($0)) }.filter { $0 > 0 }
                state.dashPhase = dimension(phase) ?? 0
            case "pgfsetbuttcap": state.cap = .butt
            case "pgfsetroundcap": state.cap = .round
            case "pgfsetrectcap": state.cap = .square
            case "pgfsetmiterjoin": state.join = .miter
            case "pgfsetroundjoin": state.join = .round
            case "pgfsetbeveljoin": state.join = .bevel
            case "pgfseteorule": state.evenOdd = true
            case "pgfsetnonzerorule": state.evenOdd = false
            case "pgfsetfillopacity": state.fillOpacity = number(group()).map { min(1, max(0, $0)) } ?? 1
            case "pgfsetstrokeopacity": state.strokeOpacity = number(group()).map { min(1, max(0, $0)) } ?? 1
            case "definecolor":
                let colorName = group()
                let model = group()
                let spec = group()
                if let rgb = Self.color(model: model, spec: spec) { colors[colorName] = rgb }
            case "pgfsetfillcolor":
                if let rgb = colors[group()] { state.fill = rgb }
            case "pgfsetstrokecolor":
                if let rgb = colors[group()] { state.stroke = rgb }
            case "pgfsetcolor":
                if let rgb = colors[group()] { state.fill = rgb; state.stroke = rgb }
            case "pgfsys@defobject":
                let objectName = group()
                _ = group(); _ = group()
                let body = group()
                if objects.count < 5000, body.unicodeScalars.count < 1_000_000 { objects[objectName] = body }
            case "pgfsys@useobject":
                let objectName = group()
                _ = group()
                if let body = objects[objectName], objectDepth < 4 { runObject(body) }
            case "pgfsys@transformshift":
                if let x = dimension(group()), let y = dimension(group()) { state.transform = CGAffineTransform(translationX: x, y: y).concatenating(state.transform) }
            case "pgfsys@transformcm":
                let values = (0..<6).compactMap { _ in dimension(group()) ?? number(group()) }
                if values.count == 6 {
                    state.transform = CGAffineTransform(a: values[0], b: values[1], c: values[2], d: values[3], tx: values[4], ty: values[5]).concatenating(state.transform)
                }
            case "pgftransformshift":
                if let p = point(group()) { state.transform = CGAffineTransform(translationX: p.x, y: p.y).concatenating(state.transform) }
            case "pgftransformrotate":
                if let degrees = number(group()) { state.transform = CGAffineTransform(rotationAngle: degrees * .pi / 180).concatenating(state.transform) }
            case "pgftransformscale":
                if let s = number(group()) { state.transform = CGAffineTransform(scaleX: s, y: s).concatenating(state.transform) }
            case "pgftext":
                let options = optional() ?? ""
                let content = group()
                text(options: options, content: content)
            default:
                break
            }
        }

        mutating func allowElement() -> Bool {
            elements += 1
            if elements > elementLimit { stopped = true; return false }
            return true
        }

        mutating func note(_ p: CGPoint) {
            guard p.x.isFinite, p.y.isFinite else { return }
            if let e = extent { extent = e.union(CGRect(origin: p, size: .zero)) } else { extent = CGRect(origin: p, size: .zero) }
        }

        mutating func usePath(_ options: String) {
            let words = options.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            defer { path = CGMutablePath() }
            guard !path.isEmpty else { return }
            if words.contains("use as bounding box") {
                if bounds == nil { bounds = path.boundingBoxOfPath }
            }
            if words.contains("clip") {
                let clip = path.copy()!
                openGroup(clip: clip)
            }
            let fill = words.contains("fill")
            let stroke = words.contains("stroke") && state.lineWidth > 0
            guard fill || stroke else { return }
            var style = PGFPicture.Style()
            if fill { style.fill = (state.fill.r, state.fill.g, state.fill.b, state.fillOpacity) }
            if stroke { style.stroke = (state.stroke.r, state.stroke.g, state.stroke.b, state.strokeOpacity) }
            if fill && state.fillOpacity == 0 && !stroke { return }
            if stroke && !fill && state.strokeOpacity == 0 { return }
            // Line widths scale with the transform (markers are drawn in their own space).
            let scale = sqrt(abs(state.transform.a * state.transform.d - state.transform.b * state.transform.c))
            style.lineWidth = state.lineWidth * (scale > 0 ? scale : 1)
            style.dash = state.dash
            style.dashPhase = state.dashPhase
            style.cap = state.cap
            style.join = state.join
            style.evenOdd = state.evenOdd
            groups[groups.count - 1].children.append(.path(path.copy()!, style))
            paths += 1
        }

        mutating func openGroup(clip: CGPath) {
            let box = GroupBox(clip: clip, isScope: false)
            groups.append(box)
        }

        mutating func closeGroup() {
            guard groups.count > 1 else { return }
            let box = groups.removeLast()
            if !box.children.isEmpty {
                groups[groups.count - 1].children.append(.group(clip: box.clip, children: box.children))
            }
        }

        mutating func pushScope() {
            stateStack.append(state)
            groups.append(GroupBox(clip: nil, isScope: true))
        }

        mutating func popScope() {
            // Close clip groups opened inside this scope, then the scope itself.
            while groups.count > 1, !groups[groups.count - 1].isScope { closeGroup() }
            closeGroup()
            if let saved = stateStack.popLast() { state = saved }
            path = CGMutablePath()
        }

        mutating func runObject(_ body: String) {
            objectDepth += 1
            var sub = Interpreter(chars: Array(body.unicodeScalars), image: image)
            sub.state = state
            sub.colors = colors
            sub.objects = objects
            sub.objectDepth = objectDepth
            sub.elements = elements
            sub.run()
            let nodes = sub.finish()
            groups[groups.count - 1].children.append(contentsOf: nodes)
            paths += sub.paths
            texts += sub.texts
            elements = sub.elements
            if sub.stopped { stopped = true }
            objectDepth -= 1
        }

        // MARK: Text

        mutating func text(options: String, content: String) {
            var x: CGFloat = 0, y: CGFloat = 0, rotation: CGFloat = 0
            var horizontal = 0, vertical = 0
            for part in options.split(separator: ",") {
                let word = part.trimmingCharacters(in: .whitespaces)
                if word.hasPrefix("x=") { x = dimension(String(word.dropFirst(2))) ?? 0 }
                else if word.hasPrefix("y=") { y = dimension(String(word.dropFirst(2))) ?? 0 }
                else if word.hasPrefix("rotate=") { rotation = number(String(word.dropFirst(7))) ?? 0 }
                else if word == "left" { horizontal = -1 }
                else if word == "right" { horizontal = 1 }
                else if word == "top" { vertical = 1 }
                else if word == "bottom" { vertical = -1 }
                else if word == "base" { vertical = -2 }
            }
            let origin = CGPoint(x: x, y: y).applying(state.transform)
            // An embedded raster image: \pgfimage[width=..,height=..]{file} or \includegraphics.
            if content.contains("\\pgfimage") || content.contains("\\includegraphics") {
                var inner = Interpreter(chars: Array(content.unicodeScalars), image: image)
                while inner.i < inner.chars.count {
                    if inner.chars[inner.i] == "\\" {
                        inner.i += 1
                        let name = inner.readName()
                        if name == "pgfimage" || name == "includegraphics" {
                            let opts = inner.optional() ?? ""
                            let file = inner.group()
                            var width: CGFloat = 0, height: CGFloat = 0
                            for part in opts.split(separator: ",") {
                                let kv = part.split(separator: "=").map { $0.trimmingCharacters(in: .whitespaces) }
                                if kv.count == 2, kv[0] == "width" { width = dimension(kv[1]) ?? 0 }
                                if kv.count == 2, kv[0] == "height" { height = dimension(kv[1]) ?? 0 }
                            }
                            if let data = image(file), width > 0, height > 0, data.count < 16 * 1024 * 1024 {
                                let rect = CGRect(x: origin.x, y: origin.y, width: width, height: height)
                                groups[groups.count - 1].children.append(.image(data, rect))
                                texts += 1
                            }
                            break
                        }
                    } else { inner.i += 1 }
                }
                return
            }
            var color = (CGFloat(0), CGFloat(0), CGFloat(0))
            if let m = content.range(of: #"\\color\{([^}]*)\}"#, options: .regularExpression) {
                let name = content[m].dropFirst(7).dropLast()
                if let rgb = colors[String(name)] { color = rgb }
            }
            var size: CGFloat = 10
            if let m = content.range(of: #"\\fontsize\{[0-9.]+\}"#, options: .regularExpression) {
                size = CGFloat(Double(content[m].dropFirst(10).dropLast()) ?? 10)
            }
            let angle = atan2(state.transform.b, state.transform.a) * 180 / .pi
            let item = PGFPicture.Text(origin: origin, rotation: rotation + angle, horizontal: horizontal, vertical: vertical,
                                       size: max(1, min(size, 144)), color: (color.0, color.1, color.2, 1),
                                       sans: content.contains("\\sffamily") || content.contains("\\sf "), bold: content.contains("\\bfseries"),
                                       runs: PGF.runs(content))
            guard !item.runs.isEmpty else { return }
            groups[groups.count - 1].children.append(.text(item))
            texts += 1
            note(origin)
        }

        // MARK: Values

        func point(_ text: String) -> CGPoint? {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("\\pgfpointorigin") { return .zero }
            guard let open = trimmed.firstIndex(of: "{") else { return nil }
            let rest = trimmed[open...]
            let parts = rest.split(separator: "}").map { $0.replacingOccurrences(of: "{", with: "") }
            guard parts.count >= 2, let x = dimension(parts[0]), let y = dimension(parts[1]) else { return nil }
            return CGPoint(x: x, y: y)
        }

        func dimension(_ text: String) -> CGFloat? {
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            var number = ""
            var unit = ""
            for c in t {
                if c.isNumber || c == "." || c == "-" || c == "+" || c == "e" && unit.isEmpty && !number.isEmpty && false { if unit.isEmpty { number.append(c) } }
                else if c.isLetter { unit.append(c) }
            }
            guard let value = Double(number), value.isFinite else { return nil }
            let factor: Double
            switch unit {
            case "in": factor = 72
            case "pt", "": factor = 72 / 72.27
            case "bp": factor = 1
            case "cm": factor = 72 / 2.54
            case "mm": factor = 72 / 25.4
            case "em": factor = 10
            default: factor = 1
            }
            let result = value * factor
            return abs(result) < 1e6 ? CGFloat(result) : nil
        }

        func number(_ text: String) -> CGFloat? {
            guard let value = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)), value.isFinite else { return nil }
            return CGFloat(value)
        }

        static func color(model: String, spec: String) -> (CGFloat, CGFloat, CGFloat)? {
            let parts = spec.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            switch model {
            case "rgb" where parts.count == 3: return (CGFloat(parts[0]), CGFloat(parts[1]), CGFloat(parts[2]))
            case "RGB" where parts.count == 3: return (CGFloat(parts[0] / 255), CGFloat(parts[1] / 255), CGFloat(parts[2] / 255))
            case "gray" where parts.count == 1: return (CGFloat(parts[0]), CGFloat(parts[0]), CGFloat(parts[0]))
            default: return nil
            }
        }
    }

    // MARK: - Text content

    private static let mathSymbols: [String: String] = [
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ε", "varepsilon": "ε", "zeta": "ζ", "eta": "η",
        "theta": "θ", "iota": "ι", "kappa": "κ", "lambda": "λ", "mu": "μ", "nu": "ν", "xi": "ξ", "pi": "π", "rho": "ρ",
        "sigma": "σ", "tau": "τ", "upsilon": "υ", "phi": "φ", "varphi": "φ", "chi": "χ", "psi": "ψ", "omega": "ω",
        "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ", "Xi": "Ξ", "Pi": "Π", "Sigma": "Σ", "Phi": "Φ", "Psi": "Ψ",
        "Omega": "Ω", "ell": "ℓ", "infty": "∞", "times": "×", "cdot": "·", "pm": "±", "mp": "∓", "leq": "≤", "le": "≤",
        "geq": "≥", "ge": "≥", "neq": "≠", "ne": "≠", "approx": "≈", "sim": "∼", "propto": "∝", "circ": "°", "degree": "°",
        "partial": "∂", "nabla": "∇", "sum": "∑", "int": "∫", "rightarrow": "→", "to": "→", "leftarrow": "←", "%": "%",
        ",": "\u{2009}", ";": " ", ":": " ", "!": "", " ": " ", "{": "{", "}": "}", "_": "_", "$": "$", "#": "#", "&": "&",
        "lvert": "|", "rvert": "|", "vert": "|", "langle": "⟨", "rangle": "⟩", "ldots": "…", "cdots": "⋯", "dots": "…",
        "AA": "Å", "deg": "°", "prime": "′", "minus": "−", "quad": " ",
    ]

    /// Text runs from a \pgftext body: font switches dropped, math turned into styled runs.
    static func runs(_ content: String) -> [PGFPicture.Run] {
        var text = content
        // matplotlib's catcode setup for ^ and %: noise for us.
        text = text.replacingOccurrences(of: #"\\catcode`\\.=\\active\\def.\{(?:[^{}]|\{[^{}]*\})*\}"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\\color\{[^{}]*\}"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\\fontsize\{[^{}]*\}\{[^{}]*\}"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\\(rmfamily|sffamily|ttfamily|selectfont|bfseries|itshape|normalfont|mdseries|upshape)(?![A-Za-z])"#, with: "", options: .regularExpression)
        let chars = Array(text)
        var runs: [PGFPicture.Run] = []
        func append(_ s: String, script: Int, italic: Bool) {
            guard !s.isEmpty else { return }
            if let last = runs.last, last.script == script, last.italic == italic { runs[runs.count - 1].text += s }
            else { runs.append(PGFPicture.Run(text: s, script: script, italic: italic)) }
        }
        var i = 0
        func readGroup() -> String {
            guard i < chars.count else { return "" }
            if chars[i] != "{" {
                if chars[i] == "\\" {
                    var name = "\\"
                    i += 1
                    while i < chars.count, chars[i].isLetter { name.append(chars[i]); i += 1 }
                    if name == "\\", i < chars.count { name.append(chars[i]); i += 1 }
                    return name
                }
                let c = String(chars[i]); i += 1; return c
            }
            var depth = 0
            var out = ""
            while i < chars.count {
                let c = chars[i]
                if c == "{" { depth += 1; if depth == 1 { i += 1; continue } }
                if c == "}" { depth -= 1; if depth == 0 { i += 1; break } }
                out.append(c)
                i += 1
            }
            return out
        }
        func walk(_ source: String, math: Bool, script: Int, depth: Int) {
            guard depth < 8 else { return }
            let saved = (chars: chars, i: i)
            _ = saved
            let inner = Array(source)
            var j = 0
            func group(_ from: inout Int) -> String {
                guard from < inner.count else { return "" }
                if inner[from] != "{" {
                    if inner[from] == "\\" {
                        var name = "\\"
                        from += 1
                        while from < inner.count, inner[from].isLetter { name.append(inner[from]); from += 1 }
                        if name == "\\", from < inner.count { name.append(inner[from]); from += 1 }
                        return name
                    }
                    let c = String(inner[from]); from += 1; return c
                }
                var d = 0
                var out = ""
                while from < inner.count {
                    let c = inner[from]
                    if c == "{" { d += 1; if d == 1 { from += 1; continue } }
                    if c == "}" { d -= 1; if d == 0 { from += 1; break } }
                    out.append(c)
                    from += 1
                }
                return out
            }
            var isMath = math
            while j < inner.count {
                let c = inner[j]
                switch c {
                case "$":
                    isMath.toggle(); j += 1
                case "{", "}":
                    j += 1
                case "^", "_":
                    j += 1
                    let arg = group(&j)
                    walk(arg, math: true, script: c == "^" ? 1 : -1, depth: depth + 1)
                case "\\":
                    j += 1
                    var name = ""
                    while j < inner.count, inner[j].isLetter { name.append(inner[j]); j += 1 }
                    if name.isEmpty, j < inner.count { name = String(inner[j]); j += 1 }
                    switch name {
                    case "mathdefault", "mathrm", "text", "textrm", "mathsf", "textsf", "mathbf", "textbf", "mathit", "textit", "emph", "mathtt", "texttt", "operatorname", "mbox", "hbox":
                        let arg = group(&j)
                        walk(arg, math: isMath && (name == "mathit"), script: script, depth: depth + 1)
                    case "textsc":
                        walk(group(&j).uppercased(), math: false, script: script, depth: depth + 1)
                    case "frac", "dfrac", "tfrac":
                        let a = group(&j), b = group(&j)
                        walk(a, math: isMath, script: script, depth: depth + 1)
                        append("/", script: script, italic: false)
                        walk(b, math: isMath, script: script, depth: depth + 1)
                    case "sqrt":
                        append("√", script: script, italic: false)
                        walk(group(&j), math: isMath, script: script, depth: depth + 1)
                    case "left", "right", "big", "Big", "bigl", "bigr", "displaystyle", "textstyle", "scriptstyle", "mathdefault ":
                        break
                    default:
                        if let symbol = mathSymbols[name] { append(symbol, script: script, italic: false) }
                    }
                default:
                    if isMath && c.isLetter && c.isASCII { append(String(c), script: script, italic: true) }
                    else if isMath && c == "-" { append("−", script: script, italic: false) }
                    else if c == "\n" { append(" ", script: script, italic: false) }
                    else { append(String(c), script: script, italic: false) }
                    j += 1
                }
            }
        }
        _ = readGroup
        walk(String(chars), math: false, script: 0, depth: 0)
        // Trim outer whitespace.
        if let first = runs.first { runs[0].text = String(first.text.drop(while: { $0 == " " })) }
        if let last = runs.last { runs[runs.count - 1].text = String(last.text.reversed().drop(while: { $0 == " " }).reversed()) }
        return runs.filter { !$0.text.isEmpty }
    }

    // MARK: - SVG

    static func svg(_ picture: PGFPicture) -> String {
        let b = picture.bounds
        var out = "<svg xmlns=\"http://www.w3.org/2000/svg\" class=\"pgf\" viewBox=\"0 0 \(fmt(b.width)) \(fmt(b.height))\" width=\"\(fmt(b.width))\" height=\"\(fmt(b.height))\" role=\"img\">"
        var defs = ""
        var clipCount = 0
        let flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: -b.minX, ty: b.maxY)

        func pathData(_ path: CGPath) -> String {
            var d = ""
            path.applyWithBlock { element in
                let e = element.pointee
                func p(_ k: Int) -> String { let q = e.points[k].applying(flip); return "\(fmt(q.x)) \(fmt(q.y))" }
                switch e.type {
                case .moveToPoint: d += "M\(p(0))"
                case .addLineToPoint: d += "L\(p(0))"
                case .addQuadCurveToPoint: d += "Q\(p(0)) \(p(1))"
                case .addCurveToPoint: d += "C\(p(0)) \(p(1)) \(p(2))"
                case .closeSubpath: d += "Z"
                @unknown default: break
                }
            }
            return d
        }
        func rgb(_ c: (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat)) -> String {
            "rgb(\(Int((c.r * 255).rounded())),\(Int((c.g * 255).rounded())),\(Int((c.b * 255).rounded())))"
        }
        func render(_ nodes: [PGFPicture.Node]) -> String {
            var s = ""
            for node in nodes {
                switch node {
                case .group(let clip, let children):
                    let inner = render(children)
                    guard !inner.isEmpty else { continue }
                    if let clip {
                        clipCount += 1
                        defs += "<clipPath id=\"c\(clipCount)\"><path d=\"\(pathData(clip))\"/></clipPath>"
                        s += "<g clip-path=\"url(#c\(clipCount))\">\(inner)</g>"
                    } else {
                        s += "<g>\(inner)</g>"
                    }
                case .path(let path, let style):
                    var attrs = "d=\"\(pathData(path))\""
                    if let fill = style.fill {
                        attrs += " fill=\"\(rgb(fill))\""
                        if fill.a < 1 { attrs += " fill-opacity=\"\(fmt(fill.a))\"" }
                        if style.evenOdd { attrs += " fill-rule=\"evenodd\"" }
                    } else { attrs += " fill=\"none\"" }
                    if let stroke = style.stroke {
                        attrs += " stroke=\"\(rgb(stroke))\" stroke-width=\"\(fmt(style.lineWidth))\""
                        if stroke.a < 1 { attrs += " stroke-opacity=\"\(fmt(stroke.a))\"" }
                        switch style.cap { case .round: attrs += " stroke-linecap=\"round\""; case .square: attrs += " stroke-linecap=\"square\""; default: break }
                        switch style.join { case .round: attrs += " stroke-linejoin=\"round\""; case .bevel: attrs += " stroke-linejoin=\"bevel\""; default: attrs += " stroke-miterlimit=\"10\"" }
                        if !style.dash.isEmpty {
                            attrs += " stroke-dasharray=\"\(style.dash.map(fmt).joined(separator: " "))\""
                            if style.dashPhase != 0 { attrs += " stroke-dashoffset=\"\(fmt(style.dashPhase))\"" }
                        }
                    }
                    s += "<path \(attrs)/>"
                case .text(let text):
                    let p = text.origin.applying(flip)
                    let anchor = text.horizontal < 0 ? "start" : text.horizontal > 0 ? "end" : "middle"
                    // Explicit offsets from the baseline (WebKit ignores most dominant-baseline values).
                    let dy: CGFloat
                    switch text.vertical {
                    case 1: dy = 0.76
                    case -1: dy = -0.22
                    case -2: dy = 0
                    default: dy = 0.34
                    }
                    let family = text.sans ? "-apple-system, 'Helvetica Neue', Helvetica, sans-serif" : "KaTeX_Main, 'Times New Roman', Times, serif"
                    var attrs = "x=\"\(fmt(p.x))\" y=\"\(fmt(p.y))\" font-size=\"\(fmt(text.size))\" fill=\"\(rgb(text.color))\" text-anchor=\"\(anchor)\"\(dy != 0 ? " dy=\"\(fmt(dy * text.size))\"" : "") font-family=\"\(family)\""
                    if text.bold { attrs += " font-weight=\"600\"" }
                    if text.rotation != 0 { attrs += " transform=\"rotate(\(fmt(-text.rotation)) \(fmt(p.x)) \(fmt(p.y)))\"" }
                    var spans = ""
                    for run in text.runs {
                        var a = ""
                        if run.italic { a += " font-style=\"italic\"" }
                        if run.script != 0 { a += " baseline-shift=\"\(run.script > 0 ? "super" : "sub")\" font-size=\"\(fmt(text.size * 0.7))\"" }
                        spans += "<tspan\(a)>\(escape(run.text))</tspan>"
                    }
                    s += "<text \(attrs)>\(spans)</text>"
                case .image(let data, let rect):
                    guard let mime = imageMIME(data) else { continue }
                    let top = CGPoint(x: rect.minX, y: rect.maxY).applying(flip)
                    s += "<image x=\"\(fmt(top.x))\" y=\"\(fmt(top.y))\" width=\"\(fmt(rect.width))\" height=\"\(fmt(rect.height))\" preserveAspectRatio=\"none\" href=\"data:\(mime);base64,\(data.base64EncodedString())\"/>"
                }
            }
            return s
        }
        let body = render(picture.root)
        if !defs.isEmpty { out += "<defs>\(defs)</defs>" }
        out += body + "</svg>"
        return out
    }

    static func imageMIME(_ data: Data) -> String? {
        let bytes = [UInt8](data.prefix(4))
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if bytes.starts(with: [0xFF, 0xD8]) { return "image/jpeg" }
        return nil
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func fmt(_ v: CGFloat) -> String {
        guard v.isFinite else { return "0" }
        let rounded = (Double(v) * 100).rounded() / 100
        if rounded == rounded.rounded() { return String(Int(rounded)) }
        return String(format: "%.2f", rounded).replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
    }

    // MARK: - Core Graphics

    /// Draws the picture fitted into `rect` (for thumbnails).
    static func draw(_ picture: PGFPicture, in rect: CGRect, context: CGContext) {
        let b = picture.bounds
        let scale = min(rect.width / b.width, rect.height / b.height)
        context.saveGState()
        context.translateBy(x: rect.midX - b.width * scale / 2, y: rect.midY - b.height * scale / 2)
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -b.minX, y: -b.minY)
        draw(picture.root, context: context)
        context.restoreGState()
    }

    private static func draw(_ nodes: [PGFPicture.Node], context: CGContext) {
        for node in nodes {
            switch node {
            case .group(let clip, let children):
                context.saveGState()
                if let clip { context.addPath(clip); context.clip() }
                draw(children, context: context)
                context.restoreGState()
            case .path(let path, let style):
                context.saveGState()
                if let fill = style.fill {
                    context.addPath(path)
                    context.setFillColor(CGColor(srgbRed: fill.r, green: fill.g, blue: fill.b, alpha: fill.a))
                    context.fillPath(using: style.evenOdd ? .evenOdd : .winding)
                }
                if let stroke = style.stroke {
                    context.addPath(path)
                    context.setStrokeColor(CGColor(srgbRed: stroke.r, green: stroke.g, blue: stroke.b, alpha: stroke.a))
                    context.setLineWidth(style.lineWidth)
                    context.setLineCap(style.cap)
                    context.setLineJoin(style.join)
                    if !style.dash.isEmpty { context.setLineDash(phase: style.dashPhase, lengths: style.dash) }
                    context.strokePath()
                }
                context.restoreGState()
            case .text(let text):
                let base: NSFont = text.sans ? .systemFont(ofSize: text.size, weight: text.bold ? .semibold : .regular)
                    : (NSFont(name: "Times New Roman", size: text.size) ?? .systemFont(ofSize: text.size))
                let string = NSMutableAttributedString()
                for run in text.runs {
                    var font = run.italic ? NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask) : base
                    if run.script != 0 { font = NSFontManager.shared.convert(font, toSize: text.size * 0.7) }
                    string.append(NSAttributedString(string: run.text, attributes: [
                        .font: font, .foregroundColor: NSColor(srgbRed: text.color.r, green: text.color.g, blue: text.color.b, alpha: 1),
                        .baselineOffset: run.script > 0 ? text.size * 0.38 : run.script < 0 ? -text.size * 0.2 : 0,
                    ]))
                }
                let size = string.size()
                let ascent = base.ascender, descent = -base.descender
                var x: CGFloat = text.horizontal < 0 ? 0 : text.horizontal > 0 ? -size.width : -size.width / 2
                // draw(at:) puts the bottom of the line (below the descender) at y.
                let y: CGFloat
                switch text.vertical {
                case 1: y = -(ascent + descent)
                case -1: y = 0
                case -2: y = -descent
                default: y = -(ascent + descent) / 2
                }
                x = x.isFinite ? x : 0
                context.saveGState()
                context.translateBy(x: text.origin.x, y: text.origin.y)
                context.rotate(by: text.rotation * .pi / 180)
                let graphics = NSGraphicsContext(cgContext: context, flipped: false)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = graphics
                string.draw(at: CGPoint(x: x, y: y))
                NSGraphicsContext.restoreGraphicsState()
                context.restoreGState()
            case .image(let data, let rect):
                if let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                    context.draw(image, in: rect)
                }
            }
        }
    }
}
