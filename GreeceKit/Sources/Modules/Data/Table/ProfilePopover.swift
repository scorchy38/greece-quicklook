import AppKit

/// The full profile of a column: kind, counts, spread and top values.
final class ProfilePopoverView: NSView {
    private let profile: ColumnProfile

    init(title: String, profile: ColumnProfile) {
        self.profile = profile
        super.init(frame: .zero)

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            widthAnchor.constraint(equalToConstant: 300),
        ])

        // Title and kind
        let name = NSTextField(labelWithString: title)
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        name.lineBreakMode = .byTruncatingMiddle
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let kind = NSTextField(labelWithString: profile.isUnique ? "Unique Text" : profile.kind.title + (profile.kind == .date && profile.hasTime ? " & Time" : ""))
        kind.font = .systemFont(ofSize: 11, weight: .medium)
        kind.textColor = .secondaryLabelColor
        let titleRow = NSStackView(views: [name, NSView(), kind])
        titleRow.distribution = .fill
        stack.addArrangedSubview(titleRow)
        titleRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true

        // Distribution
        if [.integer, .number, .date].contains(profile.kind), !profile.histogram.isEmpty {
            let chart = HistogramView(bins: profile.histogram)
            chart.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(chart)
            NSLayoutConstraint.activate([
                chart.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
                chart.heightAnchor.constraint(equalToConstant: 56),
            ])
            if let low = profile.minimum, let high = profile.maximum {
                let left = caption(format(low)), right = caption(format(high))
                right.alignment = .right
                let range = NSStackView(views: [left, NSView(), right])
                stack.setCustomSpacing(4, after: chart)
                stack.addArrangedSubview(range)
                range.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
            }
        }

        // Facts
        var facts: [(String, String)] = [
            ("Values", profile.filled.formatted()),
            ("Empty", profile.empty == 0 ? "None" : "\(profile.empty.formatted()) (\(ColumnProfile.percent(Double(profile.empty) / Double(max(profile.examined, 1)))))"),
            ("Distinct", profile.distinctCapped ? "\(profile.distinct.formatted())+" : profile.distinct.formatted()),
        ]
        switch profile.kind {
        case .integer, .number:
            if let v = profile.minimum { facts.append(("Minimum", ColumnProfile.full(v))) }
            if let v = profile.maximum { facts.append(("Maximum", ColumnProfile.full(v))) }
            if let v = profile.mean { facts.append(("Mean", ColumnProfile.rounded(v))) }
            if let v = profile.median { facts.append(("Median", ColumnProfile.full(v))) }
        case .date:
            if let v = profile.minimum { facts.append(("Earliest", ColumnProfile.dateText(v, time: profile.hasTime))) }
            if let v = profile.maximum { facts.append(("Latest", ColumnProfile.dateText(v, time: profile.hasTime))) }
        case .boolean:
            facts.append(("True", profile.trueCount.formatted()))
            facts.append(("False", (profile.filled - profile.trueCount).formatted()))
        case .text:
            if profile.longest > 0 {
                facts.append(("Length", profile.shortest == profile.longest ? "\(profile.longest)" : "\(profile.shortest)–\(profile.longest) characters"))
            }
        case .empty:
            break
        }
        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.rowSpacing = 5
        grid.columnSpacing = 16
        for (label, value) in facts {
            let l = NSTextField(labelWithString: label)
            l.font = .systemFont(ofSize: 12)
            l.textColor = .secondaryLabelColor
            let v = NSTextField(labelWithString: value)
            v.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            v.lineBreakMode = .byTruncatingTail
            v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            grid.addRow(with: [l, v])
        }
        grid.column(at: 0).xPlacement = .leading
        grid.column(at: 1).xPlacement = .trailing
        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(grid)
        grid.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true

        // Top values
        if profile.kind != .empty, let first = profile.top.first, first.count > 1 {
            stack.addArrangedSubview(separator())
            let heading = NSTextField(labelWithString: "Most Common")
            heading.font = .systemFont(ofSize: 11, weight: .semibold)
            heading.textColor = .secondaryLabelColor
            stack.addArrangedSubview(heading)
            stack.setCustomSpacing(6, after: heading)
            let list = NSGridView(numberOfColumns: 3, rows: 0)
            list.rowSpacing = 5
            list.columnSpacing = 10
            let filled = max(profile.filled, 1)
            for entry in profile.top {
                let value = NSTextField(labelWithString: entry.value.replacingOccurrences(of: "\n", with: " "))
                value.font = .systemFont(ofSize: 12)
                value.lineBreakMode = .byTruncatingTail
                value.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                value.widthAnchor.constraint(lessThanOrEqualToConstant: 150).isActive = true
                let bar = ShareBar(share: CGFloat(entry.count) / CGFloat(filled))
                bar.translatesAutoresizingMaskIntoConstraints = false
                bar.widthAnchor.constraint(equalToConstant: 60).isActive = true
                bar.heightAnchor.constraint(equalToConstant: 6).isActive = true
                let count = NSTextField(labelWithString: "\(entry.count.formatted())  \(ColumnProfile.percent(Double(entry.count) / Double(filled)))")
                count.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
                count.textColor = .secondaryLabelColor
                count.alignment = .right
                list.addRow(with: [value, bar, count])
            }
            list.column(at: 2).xPlacement = .trailing
            list.rowAlignment = .none
            for row in 0..<list.numberOfRows { list.row(at: row).yPlacement = .center }
            stack.addArrangedSubview(list)
        }

        if profile.sampled {
            let note = caption("Based on \(profile.examined.formatted()) of \(profile.totalRows.formatted()) rows")
            stack.addArrangedSubview(note)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func format(_ value: Double) -> String {
        profile.kind == .date ? ColumnProfile.dateText(value, time: false) : ColumnProfile.full(value)
    }

    private func caption(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        label.textColor = .tertiaryLabelColor
        return label
    }

    private func separator() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        line.widthAnchor.constraint(equalToConstant: 268).isActive = true
        return line
    }
}

/// Bars for a distribution, rounded at the top like Health's charts.
final class HistogramView: NSView {
    private let bins: [Int]
    init(bins: [Int]) {
        self.bins = bins
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        guard let peak = bins.max(), peak > 0 else { return }
        let gap: CGFloat = 2
        let width = (bounds.width - gap * CGFloat(bins.count - 1)) / CGFloat(bins.count)
        NSColor.controlAccentColor.withAlphaComponent(0.7).setFill()
        for (i, value) in bins.enumerated() where value > 0 {
            let height = max(2, (bounds.height - 1) * CGFloat(value) / CGFloat(peak))
            let rect = NSRect(x: CGFloat(i) * (width + gap), y: 1, width: width, height: height)
            NSBezierPath(roundedRect: rect, xRadius: min(2, width / 2), yRadius: min(2, width / 2)).fill()
        }
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }
}

final class ShareBar: NSView {
    private let share: CGFloat
    init(share: CGFloat) {
        self.share = min(max(share, 0), 1)
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        guard share > 0 else { return }
        NSColor.controlAccentColor.withAlphaComponent(0.75).setFill()
        let fill = NSRect(x: 0, y: 0, width: max(bounds.height, bounds.width * share), height: bounds.height)
        NSBezierPath(roundedRect: fill, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
    }
}
