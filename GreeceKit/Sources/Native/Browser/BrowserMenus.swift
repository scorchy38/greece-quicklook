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
            let info = ActionMenuItem("Get Info") { getInfo(node) }
            // Shown only where ⌘I reaches the preview: in Quick Look, Finder would take it.
            if PreviewHost.acceptsTyping { info.keyEquivalent = "i" }
            items += [info, .separator()]
        }
        var folder: [NSMenuItem] = []
        if let open, node.isDirectory, !node.isPackage {
            folder.append(ActionMenuItem("Open") { open(node) })
        }
        folder += folderItems
        if !folder.isEmpty { items += folder + [.separator()] }
        let nodes = selection.count > 1 && selection.contains(where: { $0 === node }) ? selection : [node]
        let several = nodes.count > 1
        let names = nodes.map(\.name)
        items.append(ActionMenuItem(several ? "Copy Names" : "Copy Name") { Clipboard.copy(names.joined(separator: "\n")) })
        let paths = nodes.map { $0.url?.path ?? $0.path }
        if !paths.contains(where: \.isEmpty), paths != names {
            items.append(ActionMenuItem(several ? "Copy Paths" : "Copy Path") { Clipboard.copy(paths.joined(separator: "\n")) })
        }
        return items
    }
}

/// The Sort By and Group By menus, for the toolbar's pull-downs and the icons' background menu.
enum ViewOptionMenus {
    static func sortItems(_ state: BrowserViewState, keys: [BrowserViewState.SortKey],
                          choose: @escaping (BrowserViewState.SortKey, Bool) -> Void) -> [NSMenuItem] {
        var items: [NSMenuItem] = keys.map { key in
            ActionMenuItem(key.title, state: state.sort == key ? .on : .off) {
                // A new key starts in its natural order; the same key keeps the reader's.
                choose(key, state.sort == key ? state.ascending : key.startsAscending)
            }
        }
        items.append(.separator())
        items.append(ActionMenuItem("Ascending", state: state.ascending ? .on : .off) { choose(state.sort, true) })
        items.append(ActionMenuItem("Descending", state: state.ascending ? .off : .on) { choose(state.sort, false) })
        return items
    }

    static func groupItems(_ state: BrowserViewState, choose: @escaping (BrowserViewState.GroupKey) -> Void) -> [NSMenuItem] {
        BrowserViewState.GroupKey.allCases.flatMap { key -> [NSMenuItem] in
            let item = ActionMenuItem(key.title, state: state.group == key ? .on : .off) { choose(key) }
            return key == .none ? [item, .separator()] : [item]
        }
    }

    static func layoutItems(_ state: BrowserViewState, choose: @escaping (BrowserViewState.Layout) -> Void) -> [NSMenuItem] {
        [ActionMenuItem("as Icons", state: state.layout == .icons ? .on : .off) { choose(.icons) },
         ActionMenuItem("as List", state: state.layout == .list ? .on : .off) { choose(.list) }]
    }

    static func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = .context(items)
        return item
    }
}
