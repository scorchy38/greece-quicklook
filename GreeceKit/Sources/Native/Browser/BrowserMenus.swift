import AppKit

/// Context menus shared by a browser's list and icons, so a right-click offers the same things
/// in both: Get Info, Open for folders, then copying names and paths.
enum FileMenus {
    /// - Parameters:
    ///   - node: the file under the pointer.
    ///   - selection: what's selected; when it holds more than one file, copying covers them all.
    ///   - folderItems: more folder actions after Open (the list's Expand and Collapse).
    static func items(for node: FileNode, selection: [FileNode], getInfo: ((FileNode) -> Void)?,
                      open: ((FileNode) -> Void)?, folderItems: [NSMenuItem] = []) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        if let getInfo {
            let info = ActionMenuItem(String(localized: "Get Info", bundle: .greeceKit)) { getInfo(node) }
            // Shown only where ⌘I reaches the preview: in Quick Look, Finder would take it.
            if PreviewHost.acceptsTyping { info.keyEquivalent = "i" }
            items += [info, .separator()]
        }
        var folder: [NSMenuItem] = []
        if let open, node.isDirectory, !node.isPackage {
            folder.append(ActionMenuItem(String(localized: "Open", bundle: .greeceKit, comment: "Menu item and button: opens a folder in the browser")) { open(node) })
        }
        folder += folderItems
        if !folder.isEmpty { items += folder + [.separator()] }
        let nodes = selection.count > 1 && selection.contains(where: { $0 === node }) ? selection : [node]
        let several = nodes.count > 1
        let names = nodes.map(\.name)
        let copyNames = several ? String(localized: "Copy Names", bundle: .greeceKit, comment: "Menu item: copies the names of the selected files")
            : String(localized: "Copy Name", bundle: .greeceKit)
        items.append(ActionMenuItem(copyNames) { Clipboard.copy(names.joined(separator: "\n")) })
        let paths = nodes.map { $0.url?.path ?? $0.path }
        if !paths.contains(where: \.isEmpty), paths != names {
            let copyPaths = several ? String(localized: "Copy Paths", bundle: .greeceKit, comment: "Menu item: copies the paths of the selected files")
                : String(localized: "Copy Path", bundle: .greeceKit)
            items.append(ActionMenuItem(copyPaths) { Clipboard.copy(paths.joined(separator: "\n")) })
        }
        return items
    }
}

/// The Sort By and Group By menus, for the toolbar's pull-downs and the icons' background menu.
enum ViewOptionMenus {
    static var sortByTitle: String { String(localized: "Sort By", bundle: .greeceKit, comment: "Menu and tooltip, as in Finder’s View menu") }
    static var groupByTitle: String { String(localized: "Group By", bundle: .greeceKit, comment: "Menu and tooltip, as in Finder’s View menu") }

    /// "Back to “Docs”": the button and menu item that go up to the folder above.
    static func backTitle(_ folder: String) -> String {
        String(localized: "Back to “\(folder)”", bundle: .greeceKit, comment: "Menu item and tooltip; the argument is the name of the folder above the one showing")
    }

    static func sortItems(_ state: BrowserViewState, keys: [BrowserViewState.SortKey],
                          choose: @escaping (BrowserViewState.SortKey, Bool) -> Void) -> [NSMenuItem] {
        var items: [NSMenuItem] = keys.map { key in
            ActionMenuItem(key.title, state: state.sort == key ? .on : .off) {
                // A new key starts in its natural order; the same key keeps the reader's.
                choose(key, state.sort == key ? state.ascending : key.startsAscending)
            }
        }
        items.append(.separator())
        items.append(ActionMenuItem(String(localized: "Ascending", bundle: .greeceKit, comment: "Sort By menu item: A to Z, oldest or smallest first"),
                                    state: state.ascending ? .on : .off) { choose(state.sort, true) })
        items.append(ActionMenuItem(String(localized: "Descending", bundle: .greeceKit, comment: "Sort By menu item: Z to A, newest or largest first"),
                                    state: state.ascending ? .off : .on) { choose(state.sort, false) })
        return items
    }

    static func groupItems(_ state: BrowserViewState, choose: @escaping (BrowserViewState.GroupKey) -> Void) -> [NSMenuItem] {
        BrowserViewState.GroupKey.allCases.flatMap { key -> [NSMenuItem] in
            let item = ActionMenuItem(key.title, state: state.group == key ? .on : .off) { choose(key) }
            return key == .none ? [item, .separator()] : [item]
        }
    }

    static func layoutItems(_ state: BrowserViewState, choose: @escaping (BrowserViewState.Layout) -> Void) -> [NSMenuItem] {
        [ActionMenuItem(BrowserViewState.Layout.icons.title, state: state.layout == .icons ? .on : .off) { choose(.icons) },
         ActionMenuItem(BrowserViewState.Layout.list.title, state: state.layout == .list ? .on : .off) { choose(.list) }]
    }

    static func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = .context(items)
        return item
    }
}
