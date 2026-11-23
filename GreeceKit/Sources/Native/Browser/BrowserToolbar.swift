import AppKit

/// The slim bar above a folder browser: where you are (a back button and a path you can click
/// back up through) on the left; List or Icons, Sort By and Group By on the right. Every control
/// works by pointer alone, as Quick Look requires.
@MainActor
final class BrowserToolbar: NSObject {
    let view = DataToolbar()
    let back = FirstClickButton()
    let path = FirstClickPathControl()
    let layoutSwitch = FirstClickSegmentedControl()
    let sortButton = FirstClickPopUpButton(frame: .zero, pullsDown: true)
    let groupButton = FirstClickPopUpButton(frame: .zero, pullsDown: true)
    private let sortKeys: [BrowserViewState.SortKey]
    private var state = BrowserViewState()

    var onBack: (() -> Void)?
    /// A folder in the path was clicked: its depth, 0 being the folder previewed.
    var onJump: ((Int) -> Void)?
    var onLayout: ((BrowserViewState.Layout) -> Void)?
    var onSort: ((BrowserViewState.SortKey, Bool) -> Void)?
    var onGroup: ((BrowserViewState.GroupKey) -> Void)?

    init(showsLayouts: Bool, sortKeys: [BrowserViewState.SortKey]) {
        self.sortKeys = sortKeys
        super.init()

        back.image = NSImage(systemSymbolName: "chevron.left",
                             accessibilityDescription: String(localized: "Back", bundle: .greeceKit, comment: "Accessibility label: goes up to the folder above"))
        back.title = ""
        back.target = self
        back.action = #selector(goBack)
        back.bezelStyle = .accessoryBarAction
        back.setButtonType(.momentaryPushIn)
        back.imagePosition = .imageOnly
        back.controlSize = .small
        back.isHidden = true

        path.pathStyle = .standard
        path.controlSize = .small
        path.font = .systemFont(ofSize: 12)
        path.focusRingType = .none
        path.backgroundColor = .clear
        path.isEditable = false
        path.target = self
        path.action = #selector(jump)
        path.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        path.setContentHuggingPriority(.defaultLow, for: .horizontal)
        path.setAccessibilityLabel(String(localized: "Path", bundle: .greeceKit, comment: "Accessibility label of the path bar: the folders from the one previewed down to the one showing"))

        let list = BrowserViewState.Layout.list.title, icons = BrowserViewState.Layout.icons.title
        layoutSwitch.segmentCount = 2
        layoutSwitch.setImage(NSImage(systemSymbolName: "list.bullet", accessibilityDescription: list), forSegment: 0)
        layoutSwitch.setImage(NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: icons), forSegment: 1)
        layoutSwitch.trackingMode = .selectOne
        layoutSwitch.controlSize = .small
        layoutSwitch.segmentStyle = .automatic
        layoutSwitch.setToolTip(list, forSegment: 0)
        layoutSwitch.setToolTip(icons, forSegment: 1)
        layoutSwitch.target = self
        layoutSwitch.action = #selector(switchLayout)
        layoutSwitch.setAccessibilityLabel(String(localized: "View", bundle: .greeceKit, comment: "Noun. Accessibility label of the switch between the list and icons (as Finder’s View menu)"))
        layoutSwitch.setContentCompressionResistancePriority(.required, for: .horizontal)

        configure(sortButton, symbol: "arrow.up.arrow.down", title: ViewOptionMenus.sortByTitle)
        configure(groupButton, symbol: "square.grid.3x1.below.line.grid.1x2", title: ViewOptionMenus.groupByTitle)

        view.leading.spacing = 2
        view.leading.addArrangedSubview(back)
        view.leading.addArrangedSubview(path)
        if showsLayouts {
            view.trailing.addArrangedSubview(layoutSwitch)
            view.trailing.setCustomSpacing(10, after: layoutSwitch)
        }
        view.trailing.addArrangedSubview(sortButton)
        view.trailing.addArrangedSubview(groupButton)
        view.trailing.spacing = 2
    }

    private func configure(_ button: NSPopUpButton, symbol: String, title: String) {
        button.bezelStyle = .accessoryBarAction
        button.controlSize = .small
        button.imagePosition = .imageOnly
        button.autoenablesItems = false
        button.toolTip = title
        button.setAccessibilityLabel(title)
        (button.cell as? NSPopUpButtonCell)?.arrowPosition = .arrowAtBottom
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    /// The pull-down's first item is its face; the menu proper follows it.
    private func setMenu(_ button: NSPopUpButton, symbol: String, header: String, items: [NSMenuItem]) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let face = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        face.image = NSImage(systemSymbolName: symbol, accessibilityDescription: header)
        menu.addItem(face)
        menu.addItem(.sectionHeader(title: header))
        for item in items { menu.addItem(item) }
        button.menu = menu
    }

    func update(_ state: BrowserViewState) {
        self.state = state
        layoutSwitch.selectedSegment = state.layout == .icons ? 1 : 0
        setMenu(sortButton, symbol: "arrow.up.arrow.down", header: ViewOptionMenus.sortByTitle,
                items: ViewOptionMenus.sortItems(state, keys: sortKeys) { [weak self] key, ascending in self?.onSort?(key, ascending) })
        setMenu(groupButton, symbol: "square.grid.3x1.below.line.grid.1x2", header: ViewOptionMenus.groupByTitle,
                items: ViewOptionMenus.groupItems(state) { [weak self] key in self?.onGroup?(key) })
        let group = state.group.title, sort = state.sort.title
        groupButton.toolTip = state.group == .none ? ViewOptionMenus.groupByTitle
            : String(localized: "Grouped by \(group)", bundle: .greeceKit, comment: "Tooltip; the argument is a Group By menu item, such as “Kind” or “Date Modified”")
        sortButton.toolTip = state.ascending
            ? String(localized: "Sorted by \(sort), ascending", bundle: .greeceKit, comment: "Tooltip; the argument is a Sort By menu item, such as “Name” or “Date Modified”")
            : String(localized: "Sorted by \(sort), descending", bundle: .greeceKit, comment: "Tooltip; the argument is a Sort By menu item, such as “Name” or “Date Modified”")
    }

    /// The folders from the one previewed down to the one showing.
    func update(trail: [(title: String, icon: NSImage?)]) {
        path.pathItems = trail.map { step in
            let item = NSPathControlItem()
            item.title = step.title
            let icon = step.icon?.copy() as? NSImage
            icon?.size = NSSize(width: 16, height: 16)
            item.image = icon
            return item
        }
        back.isHidden = trail.count < 2
        if trail.count >= 2 {
            back.toolTip = ViewOptionMenus.backTitle(trail[trail.count - 2].title)
            back.setAccessibilityLabel(back.toolTip)
        }
    }

    @objc private func goBack() { onBack?() }

    @objc private func jump() {
        guard let clicked = path.clickedPathItem, let index = path.pathItems.firstIndex(of: clicked),
              index < path.pathItems.count - 1 else { return }
        onJump?(index)
    }

    @objc private func switchLayout() {
        let layout: BrowserViewState.Layout = layoutSwitch.selectedSegment == 1 ? .icons : .list
        guard layout != state.layout else { return }
        onLayout?(layout)
    }
}

// Controls that take the first click: Quick Look's panel is never the key window.

final class FirstClickButton: NSButton {
    /// Quick Look's panel is never the key window, so without this the reader's first click on the preview would only activate it and do nothing.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class FirstClickPopUpButton: NSPopUpButton {
    /// Quick Look's panel is never the key window, so without this the reader's first click on the preview would only activate it and do nothing.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class FirstClickSegmentedControl: NSSegmentedControl {
    /// Quick Look's panel is never the key window, so without this the reader's first click on the preview would only activate it and do nothing.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class FirstClickPathControl: NSPathControl {
    /// Quick Look's panel is never the key window, so without this the reader's first click on the preview would only activate it and do nothing.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
