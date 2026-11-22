import XCTest
@testable import GreeceKit

// MARK: - Sorting and grouping

/// Finder's orders and groups, as pure functions over a folder's files.
final class FileArrangementTests: XCTestCase {
    private func file(_ name: String, size: UInt64? = nil, modified: Date? = nil, kind: String? = nil) -> FileNode {
        FileNode(name: name, isDirectory: false, size: size, modified: modified, kind: kind)
    }

    private func folder(_ name: String, size: UInt64? = nil, modified: Date? = nil, package: Bool = false) -> FileNode {
        FileNode(name: name, isDirectory: true, size: size, modified: modified, isPackage: package, children: [])
    }

    private func names(_ nodes: [FileNode]) -> [String] { nodes.map(\.name) }

    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }()

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    func testSortsNamesAsFinderDoesWithFoldersFirst() {
        let nodes = [file("file 10.txt"), folder("Zeta"), file("file 9.txt"), file("Alpha.md"), folder("beta")]
        XCTAssertEqual(names(FileArrangement.sorted(nodes, by: .name, ascending: true, foldersFirst: true)),
                       ["beta", "Zeta", "Alpha.md", "file 9.txt", "file 10.txt"])
        XCTAssertEqual(names(FileArrangement.sorted(nodes, by: .name, ascending: false, foldersFirst: true)),
                       ["Zeta", "beta", "file 10.txt", "file 9.txt", "Alpha.md"], "folders stay on top either way")
        XCTAssertEqual(names(FileArrangement.sorted(nodes, by: .name, ascending: true, foldersFirst: false)),
                       ["Alpha.md", "beta", "file 9.txt", "file 10.txt", "Zeta"])
    }

    func testSortsBySizeDateAndKindWithNamesBreakingTies() {
        let a = file("a.png", size: 300, modified: date(2026, 5, 2), kind: "Image")
        let b = file("b.txt", size: 100, modified: date(2026, 5, 3), kind: "Text")
        let c = file("c.png", size: 100, modified: date(2026, 5, 1), kind: "Image")
        let d = file("d.bin")
        let nodes = [d, c, b, a]
        XCTAssertEqual(names(FileArrangement.sorted(nodes, by: .size, ascending: false, foldersFirst: true)), ["a.png", "b.txt", "c.png", "d.bin"])
        XCTAssertEqual(names(FileArrangement.sorted(nodes, by: .size, ascending: true, foldersFirst: true)), ["d.bin", "b.txt", "c.png", "a.png"])
        XCTAssertEqual(names(FileArrangement.sorted(nodes, by: .modified, ascending: false, foldersFirst: true)), ["b.txt", "a.png", "c.png", "d.bin"])
        XCTAssertEqual(names(FileArrangement.sorted(nodes, by: .modified, ascending: true, foldersFirst: true)), ["d.bin", "c.png", "a.png", "b.txt"])
        XCTAssertEqual(names(FileArrangement.sorted([a, b, c], by: .kind, ascending: true, foldersFirst: true)), ["a.png", "c.png", "b.txt"])
        XCTAssertEqual(names(FileArrangement.sorted([a, b, c], by: .kind, ascending: false, foldersFirst: true)), ["b.txt", "a.png", "c.png"])
    }

    func testTheListSortsTheSameWay() {
        let nodes = [file("b.txt", size: 100), folder("Docs"), file("a.png", size: 300), file("c.png", size: 100)]
        let root = FileNode(name: "", isDirectory: true, children: nodes)
        FileTreeView.sort(root, key: "size", ascending: false, foldersFirst: true)
        XCTAssertEqual(names(root.children ?? []), names(FileArrangement.sorted(nodes, by: .size, ascending: false, foldersFirst: true)))
        XCTAssertEqual(names(root.children ?? []), ["Docs", "a.png", "b.txt", "c.png"])
    }

    func testNotGroupingIsOneUntitledGroup() {
        let groups = FileArrangement.groups([file("a"), file("b")], by: .none)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].title, "")
        XCTAssertEqual(names(groups[0].nodes), ["a", "b"])
    }

    func testFindersBroadKinds() {
        let cases: [(String, KindGroup)] = [
            ("photo.png", .images), ("vector.svg", .images), ("song.mp3", .music), ("clip.mov", .movies), ("paper.pdf", .pdf),
            ("main.swift", .developer), ("data.json", .developer), ("page.html", .developer), ("notes.txt", .text),
            ("readme.md", .text), ("bundle.zip", .archives), ("backup.tar.gz", .archives), ("disk.dmg", .diskImages),
            ("deck.pptx", .presentations), ("sheet.xlsx", .spreadsheets), ("letter.docx", .documents), ("book.epub", .documents),
            ("font.ttf", .fonts), ("mystery.qqqzz", .other), ("Makefile", .other),
        ]
        for (name, kind) in cases {
            XCTAssertEqual(KindGroup.of(file(name)), kind, name)
        }
        XCTAssertEqual(KindGroup.of(folder("Docs")), .folders)
        XCTAssertEqual(KindGroup.of(folder("Calculator.app", package: true)), .applications)
    }

    func testGroupsByKindWithFoldersFirstAndOtherLast() {
        let nodes = [file("photo.png"), file("mystery.qqqzz"), folder("Docs"), file("main.swift"), file("song.mp3"),
                     file("notes.txt"), file("chart.png"), file("bundle.zip")]
        let groups = FileArrangement.groups(nodes, by: .kind, foldersFirst: true)
        XCTAssertEqual(groups.map(\.title), ["Folders", "Archives", "Developer", "Images", "Music", "Text", "Other"])
        XCTAssertEqual(names(groups[3].nodes), ["photo.png", "chart.png"], "files keep their order inside a group")
        XCTAssertEqual(Set(groups.map(\.id)).count, groups.count)

        let unpinned = FileArrangement.groups(nodes, by: .kind, foldersFirst: false)
        XCTAssertEqual(unpinned.map(\.title), ["Archives", "Developer", "Folders", "Images", "Music", "Text", "Other"])
        let reversed = FileArrangement.groups(nodes, by: .kind, sort: .kind, ascending: false, foldersFirst: true)
        XCTAssertEqual(reversed.map(\.title), ["Folders", "Text", "Music", "Images", "Developer", "Archives", "Other"],
                       "sorting by kind from Z turns the kinds around, not Folders or Other")
    }

    func testGroupsByDateModifiedAsFinderDoes() {
        let now = date(2026, 11, 22, 15)
        let nodes = [
            file("today.txt", modified: date(2026, 11, 22, 9)),
            file("yesterday.txt", modified: date(2026, 11, 21, 23)),
            file("week.txt", modified: date(2026, 11, 17)),
            file("month.txt", modified: date(2026, 10, 30)),
            file("september.txt", modified: date(2026, 9, 1)),
            file("march.txt", modified: date(2026, 3, 1)),
            file("old.txt", modified: date(2024, 7, 4)),
            file("older.txt", modified: date(2019, 1, 1)),
            file("undated.txt"),
            file("future.txt", modified: date(2026, 12, 25)),
        ]
        let groups = FileArrangement.groups(nodes, by: .modified, now: now, calendar: calendar)
        XCTAssertEqual(groups.map(\.title), ["Today", "Yesterday", "Previous 7 Days", "Previous 30 Days", "September", "March", "2024", "2019", "No Date"])
        XCTAssertEqual(names(groups[0].nodes), ["today.txt", "future.txt"])

        let oldestFirst = FileArrangement.groups(nodes, by: .modified, sort: .modified, ascending: true, now: now, calendar: calendar)
        XCTAssertEqual(oldestFirst.map(\.title), ["2019", "2024", "March", "September", "Previous 30 Days", "Previous 7 Days", "Yesterday", "Today", "No Date"])
        let newestFirst = FileArrangement.groups(nodes, by: .modified, sort: .modified, ascending: false, now: now, calendar: calendar)
        XCTAssertEqual(newestFirst.map(\.title), groups.map(\.title))
    }

    func testGroupsBySizeLargestFirst() {
        let nodes = [file("empty", size: 0), file("tiny", size: 900), file("small", size: 50_000), file("medium", size: 400_000),
                     file("large", size: 5_000_000), file("huge", size: 2_000_000_000), folder("Folder"), file("unknown")]
        let groups = FileArrangement.groups(nodes, by: .size, foldersFirst: true)
        XCTAssertEqual(groups.map(\.title), ["Folders", "1 GB to 10 GB", "1 MB to 10 MB", "100 KB to 1 MB", "10 KB to 100 KB",
                                             "Less than 10 KB", "Zero KB", "Unknown Size"])
        let smallestFirst = FileArrangement.groups(nodes, by: .size, sort: .size, ascending: true, foldersFirst: false)
        XCTAssertEqual(smallestFirst.map(\.title), ["Zero KB", "Less than 10 KB", "10 KB to 100 KB", "100 KB to 1 MB", "1 MB to 10 MB",
                                                    "1 GB to 10 GB", "Folders", "Unknown Size"])
        // Bands follow the sizes as the column rounds them.
        let edges = FileArrangement.groups([file("shown as 10 KB", size: 9_556), file("shown as 9 KB", size: 9_400)], by: .size)
        XCTAssertEqual(edges.map(\.title), ["10 KB to 100 KB", "Less than 10 KB"])
        XCTAssertEqual(FileArrangement.displayedSize(999_600), 1_000_000)
        XCTAssertEqual(FileArrangement.displayedSize(1_234_567), 1_200_000)
        // An archive knows its folders' sizes: they go in with the files.
        let archived = FileArrangement.groups([folder("src", size: 40_000), file("a", size: 20_000)], by: .size)
        XCTAssertEqual(archived.map(\.title), ["10 KB to 100 KB"])
    }
}

// MARK: - Memory

final class BrowserMemoryTests: XCTestCase {
    private let suite = "greece-browser-memory-tests"
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testStartsAsAListByName() {
        XCTAssertEqual(BrowserMemory.state(for: .folders, defaults: defaults), BrowserViewState(layout: .list, sort: .name, ascending: true, group: .none))
    }

    func testRemembersFoldersAndArchivesApart() {
        let icons = BrowserViewState(layout: .icons, sort: .modified, ascending: false, group: .kind)
        BrowserMemory.remember(icons, for: .folders, defaults: defaults)
        XCTAssertEqual(BrowserMemory.state(for: .folders, defaults: defaults), icons)
        XCTAssertEqual(BrowserMemory.state(for: .archives, defaults: defaults), BrowserViewState())

        BrowserMemory.remember(BrowserViewState(layout: .icons, sort: .compressed, ascending: true, group: .size), for: .archives, defaults: defaults)
        let archives = BrowserMemory.state(for: .archives, defaults: defaults)
        XCTAssertEqual(archives, BrowserViewState(layout: .list, sort: .compressed, ascending: true, group: .size), "archives list only")
        XCTAssertEqual(BrowserMemory.state(for: .folders, defaults: defaults), icons)
    }

    func testToleratesWhatItDoesntKnow() {
        defaults.set(["folders": ["layout": "gallery", "sort": "modified", "group": 7, "extra": true]], forKey: BrowserMemory.key)
        XCTAssertEqual(BrowserMemory.state(for: .folders, defaults: defaults),
                       BrowserViewState(layout: .list, sort: .modified, ascending: false, group: .none),
                       "a missing direction is the key's own; unknown values fall back")
        defaults.set("garbage", forKey: BrowserMemory.key)
        XCTAssertEqual(BrowserMemory.state(for: .folders, defaults: defaults), BrowserViewState())
    }
}

// MARK: - The browser

/// The folder browser by pointer alone: Quick Look gives it no keys, and turns any double-click
/// into opening the previewed folder in Finder.
@MainActor
final class FolderBrowserTests: XCTestCase {
    private let suite = "greece-folder-browser-tests"
    private var directory: URL!
    private var window: NSWindow?
    private var pasteboard: NSPasteboard!

    override func setUp() {
        super.setUp()
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        BrowserMemory.store = defaults
        pasteboard = NSPasteboard(name: NSPasteboard.Name("greece-tests-\(UUID().uuidString)"))
        Clipboard.pasteboard = pasteboard
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("greece-browser-\(UUID().uuidString)")
        let fm = FileManager.default
        try? fm.createDirectory(at: directory.appendingPathComponent("Docs/Deeper"), withIntermediateDirectories: true)
        try? fm.createDirectory(at: directory.appendingPathComponent("Zeta"), withIntermediateDirectories: true)
        fm.createFile(atPath: directory.appendingPathComponent("b.txt").path, contents: Data(repeating: 65, count: 10))
        fm.createFile(atPath: directory.appendingPathComponent("a.swift").path, contents: Data(repeating: 65, count: 20_000))
        fm.createFile(atPath: directory.appendingPathComponent("Docs/inner.md").path, contents: Data("# Inner".utf8))
    }

    override func tearDown() {
        window?.orderOut(nil)
        window = nil
        try? FileManager.default.removeItem(at: directory)
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        BrowserMemory.store = .standard
        pasteboard.releaseGlobally()
        Clipboard.pasteboard = .general
        super.tearDown()
    }

    private func browser(_ state: BrowserViewState = BrowserViewState()) -> MemberBrowserView {
        BrowserMemory.remember(state, for: .folders)
        let root = FileNode.folder(at: directory, showHidden: false)
        let browser = MemberBrowserView(root: root, source: LocalMembers(), scratch: ArchiveScratch(), settings: PreviewSettings(), showsKind: true)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 1000, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = browser
        window.orderFrontRegardless()
        browser.layoutSubtreeIfNeeded()
        browser.grid?.collectionView.layoutSubtreeIfNeeded()
        self.window?.orderOut(nil)
        self.window = window
        return browser
    }

    private func titles(_ items: [NSMenuItem]) -> [String] { items.map { $0.isSeparatorItem ? "—" : $0.title } }

    private func node(_ name: String, in browser: MemberBrowserView) -> FileNode {
        (browser.current.children ?? []).first { $0.name == name }!
    }

    private func perform(_ title: String, in items: [NSMenuItem], file: StaticString = #filePath, line: UInt = #line) {
        guard let item = items.first(where: { $0.title == title }) as? ActionMenuItem else {
            return XCTFail("no “\(title)” in \(titles(items))", file: file, line: line)
        }
        item.perform()
    }

    func testOpensTheWayTheReaderLastLeftIt() throws {
        let view = browser(BrowserViewState(layout: .icons, sort: .size, ascending: false, group: .kind))
        let grid = try XCTUnwrap(view.grid)
        XCTAssertTrue(grid.superview != nil && view.tree.superview == nil, "only the icons are showing")
        XCTAssertEqual(grid.groups.map(\.title), ["Folders", "Developer", "Text"])
        XCTAssertEqual(grid.groups[0].nodes.map(\.name), ["Docs", "Zeta"])
        XCTAssertEqual(view.tree.outline.sortDescriptors.first?.key, "size")
        XCTAssertEqual(view.tree.outline.sortDescriptors.first?.ascending, false)
        XCTAssertTrue(view.tree.isGrouped)
        XCTAssertEqual(view.toolbar.layoutSwitch.selectedSegment, 1)
    }

    func testSortMenuAndColumnHeadersStayInStep() {
        let view = browser()
        view.setSort(.size, ascending: false)
        XCTAssertEqual(view.tree.outline.sortDescriptors.first?.key, "size")
        XCTAssertEqual(view.tree.root.children?.map(\.name), ["Docs", "Zeta", "a.swift", "b.txt"])
        XCTAssertEqual(BrowserMemory.state(for: .folders).sort, .size)

        // A click on the Date Modified header: the menu follows, and it's remembered.
        view.tree.outline.sortDescriptors = [NSSortDescriptor(key: "modified", ascending: true)]
        XCTAssertEqual(view.state.sort, .modified)
        XCTAssertEqual(view.state.ascending, true)
        let items = view.toolbar.sortButton.menu?.items ?? []
        XCTAssertEqual(items.first { $0.title == "Date Modified" }?.state, .on)
        XCTAssertEqual(items.first { $0.title == "Ascending" }?.state, .on)
        XCTAssertEqual(items.first { $0.title == "Size" }?.state, .off)
        XCTAssertEqual(BrowserMemory.state(for: .folders).sort, .modified)

        // Choosing a new key from the menu starts it in its own direction, as Finder's columns do.
        perform("Size", in: items)
        XCTAssertEqual(view.state.sort, .size)
        XCTAssertEqual(view.state.ascending, false)
        perform("Ascending", in: view.toolbar.sortButton.menu?.items ?? [])
        XCTAssertEqual(view.tree.outline.sortDescriptors.first?.ascending, true)
    }

    func testGroupsInTheListAndTheIcons() throws {
        let view = browser()
        perform("Kind", in: view.toolbar.groupButton.menu?.items ?? [])
        let outline = view.tree.outline
        let first = try XCTUnwrap(outline.item(atRow: 0) as? FileGroupItem)
        XCTAssertEqual(first.title, "Folders")
        XCTAssertTrue(outline.delegate?.outlineView?(outline, isGroupItem: first) ?? false)
        XCTAssertEqual((outline.item(atRow: 1) as? FileNode)?.name, "Docs")
        XCTAssertEqual(outline.delegate?.outlineView?(outline, shouldSelectItem: first), false)

        view.setLayout(.icons)
        XCTAssertEqual(view.grid?.groups.map(\.title), ["Folders", "Developer", "Text"])
        perform("None", in: view.toolbar.groupButton.menu?.items ?? [])
        XCTAssertEqual(view.grid?.groups.count, 1)
        XCTAssertTrue(outline.item(atRow: 0) is FileNode)
        XCTAssertEqual(BrowserMemory.state(for: .folders), BrowserViewState(layout: .icons, sort: .name, ascending: true, group: .none))
    }

    func testOpensFoldersByPointerAndComesBack() throws {
        let view = browser(BrowserViewState(layout: .icons))
        let grid = try XCTUnwrap(view.grid)
        XCTAssertTrue(view.toolbar.back.isHidden, "nothing to go back to")

        // The chevron on a folder's icon opens it.
        let docs = node("Docs", in: view)
        let item = try XCTUnwrap(grid.collectionView.item(at: try XCTUnwrap(grid.indexPath(of: docs))) as? IconItem)
        item.cell.onOpen?()
        XCTAssertEqual(view.current.name, "Docs")
        XCTAssertEqual(grid.allNodes.map(\.name), ["Deeper", "inner.md"])
        XCTAssertFalse(view.toolbar.back.isHidden)
        XCTAssertEqual(view.toolbar.path.pathItems.map(\.title), [directory.lastPathComponent, "Docs"])

        // Open in the context menu goes further; the path goes back up.
        perform("Open", in: view.grid?.itemMenu?(node("Deeper", in: view)) ?? [])
        XCTAssertEqual(view.trail.map(\.name), [directory.lastPathComponent, "Docs", "Deeper"])
        view.goUp(to: 0)
        XCTAssertEqual(view.current.name, directory.lastPathComponent)
        XCTAssertEqual(view.selection.map(\.name), ["Docs"], "the folder just left is selected, as in Finder")
        XCTAssertEqual(grid.selectedNodes.map(\.name), ["Docs"])

        // And from a list: Open next to Expand.
        view.setLayout(.list)
        let row = view.tree.outline.row(forItem: node("Docs", in: view))
        perform("Open", in: view.tree.rowMenuItems(forRow: row))
        XCTAssertEqual(view.current.name, "Docs")
        view.goBack()
        XCTAssertEqual(view.trail.count, 1)
    }

    func testFoldersOpenFromTheirInfoToo() throws {
        let docs = FileNode.folder(at: directory.appendingPathComponent("Docs"), showHidden: false)
        var opened = false
        let info = EntryInfoView(node: docs, kind: "Folder", open: { opened = true })
        let button = try XCTUnwrap(info.firstSubview(of: ActionButton.self))
        XCTAssertEqual(button.title, "Open")
        button.perform()
        XCTAssertTrue(opened)
        XCTAssertNil(EntryInfoView(node: docs, kind: "Folder").firstSubview(of: ActionButton.self))
        let rows = EntryInfoView.rows(docs, kind: "Folder")
        XCTAssertFalse(rows.contains { $0.1.contains("archive") }, "a folder on disk isn't in an archive")
    }

    func testMenusMatchInBothViews() {
        let view = browser()
        let tree = view.tree
        let listFolder = titles(tree.rowMenuItems(forRow: tree.outline.row(forItem: node("Docs", in: view))))
        XCTAssertEqual(listFolder, ["Get Info", "—", "Open", "Expand", "Expand All", "—", "Copy Name", "Copy Path"])
        let listFile = titles(tree.rowMenuItems(forRow: tree.outline.row(forItem: node("b.txt", in: view))))

        view.setLayout(.icons)
        let iconsFolder = titles(view.grid?.itemMenu?(node("Docs", in: view)) ?? [])
        XCTAssertEqual(iconsFolder, ["Get Info", "—", "Open", "—", "Copy Name", "Copy Path"])
        perform("Copy Path", in: view.grid?.itemMenu?(node("b.txt", in: view)) ?? [])
        let copied = pasteboard.string(forType: .string).map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        XCTAssertEqual(copied, directory.appendingPathComponent("b.txt").resolvingSymlinksInPath().path)
        XCTAssertEqual(titles(view.grid?.itemMenu?(node("b.txt", in: view)) ?? []), listFile)
        XCTAssertEqual(listFile, ["Get Info", "—", "Copy Name", "Copy Path"])
    }

    func testBackgroundMenuOffersTheViewOptions() throws {
        let view = browser(BrowserViewState(layout: .icons))
        let menu = try XCTUnwrap(view.grid?.backgroundMenu?())
        XCTAssertEqual(titles(menu), ["as Icons", "as List", "—", "Group By", "Sort By"])
        XCTAssertEqual(menu[0].state, .on)
        XCTAssertEqual(titles(menu[3].submenu?.items ?? []), ["None", "—", "Kind", "Date Modified", "Size"])
        XCTAssertEqual(titles(menu[4].submenu?.items ?? []), ["Name", "Kind", "Date Modified", "Size", "—", "Ascending", "Descending"])
        perform("as List", in: menu)
        XCTAssertEqual(view.state.layout, .list)
    }

    func testSwitchingViewsKeepsTheSelection() throws {
        let view = browser()
        let file = node("a.swift", in: view)
        view.tree.select([file])
        XCTAssertEqual(view.selection.map(\.name), ["a.swift"])
        view.setLayout(.icons)
        XCTAssertEqual(view.grid?.selectedNodes.map(\.name), ["a.swift"])
        XCTAssertEqual(view.selection.map(\.name), ["a.swift"])
        view.setLayout(.list)
        XCTAssertEqual(view.tree.selectedNodes.map(\.name), ["a.swift"])
    }

    func testARebuildKeepsTheReaderWhereTheyWere() {
        let first = browser(BrowserViewState(layout: .icons))
        first.restore(MemberBrowserView.Location(path: ["Docs"], selection: ["inner.md"], showsInfo: false))
        let location = first.location
        XCTAssertEqual(location, MemberBrowserView.Location(path: ["Docs"], selection: ["inner.md"], showsInfo: false))

        let second = browser(BrowserViewState(layout: .icons))
        second.restore(location)
        XCTAssertEqual(second.current.name, "Docs")
        XCTAssertEqual(second.selection.map(\.name), ["inner.md"])
        XCTAssertEqual(second.grid?.selectedNodes.map(\.name), ["inner.md"])

        // A folder that's gone: as far as it still exists.
        let third = browser()
        third.restore(MemberBrowserView.Location(path: ["Missing"], selection: ["b.txt"], showsInfo: false))
        XCTAssertEqual(third.trail.count, 1)
        XCTAssertEqual(third.selection.map(\.name), ["b.txt"])
    }

    func testEveryControlTakesTheFirstClick() throws {
        let view = browser(BrowserViewState(layout: .icons))
        let grid = try XCTUnwrap(view.grid)
        let item = try XCTUnwrap(grid.collectionView.visibleItems().first as? IconItem)
        let views: [NSView] = [grid.collectionView, item.cell, view.toolbar.back, view.toolbar.path, view.toolbar.layoutSwitch,
                               view.toolbar.sortButton, view.toolbar.groupButton, ActionButton(title: "Open") {}]
        for control in views {
            XCTAssertTrue(control.acceptsFirstMouse(for: nil), "\(type(of: control))")
        }
    }

    func testThumbnailsAreCachedByFileAndDate() throws {
        let url = directory.appendingPathComponent("square.png")
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.systemTeal.setFill()
        NSRect(x: 0, y: 0, width: 64, height: 64).fill()
        NSGraphicsContext.restoreGraphicsState()
        try rep.representation(using: .png, properties: [:])!.write(to: url)
        let modified = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate

        let loader = ThumbnailLoader()
        let done = expectation(description: "thumbnail")
        var images = 0
        let ticket = loader.load(url, modified: modified, side: 64, scale: 2) { image, final in
            if image != nil { images += 1 }
            if final { done.fulfill() }
        }
        XCTAssertNotNil(ticket)
        wait(for: [done], timeout: 20)
        XCTAssertGreaterThan(images, 0)
        XCTAssertNotNil(loader.cached(url, modified: modified, side: 64, scale: 2))
        XCTAssertNil(loader.cached(url, modified: modified?.addingTimeInterval(1), side: 64, scale: 2), "a changed file is asked again")
        XCTAssertNil(loader.cached(url, modified: modified, side: 96, scale: 2), "and so is another size")
        XCTAssertEqual(loader.pendingCount, 0)

        // Cancelling the only waiter cancels the request.
        let other = directory.appendingPathComponent("b.txt")
        let pending = try XCTUnwrap(loader.load(other, modified: nil, side: 64, scale: 2) { _, _ in })
        XCTAssertEqual(loader.pendingCount, 1)
        loader.cancel(pending)
        XCTAssertEqual(loader.pendingCount, 0)
    }
}

// MARK: - Performance

/// Opening and scrolling a big folder as icons. Set GREECE_PERF_FOLDER (in xcodebuild,
/// TEST_RUNNER_GREECE_PERF_FOLDER) to a folder of thousands of files.
@MainActor
final class FolderBrowserPerformance: XCTestCase {
    func testBigFolder() async throws {
        guard let path = ProcessInfo.processInfo.environment["GREECE_PERF_FOLDER"] else { throw XCTSkip("Set GREECE_PERF_FOLDER") }
        let suite = "greece-folder-perf"
        let defaults = UserDefaults(suiteName: suite)!
        BrowserMemory.store = defaults
        defer { BrowserMemory.store = .standard; defaults.removePersistentDomain(forName: suite) }
        for (group, step) in [(BrowserViewState.GroupKey.none, 250.0), (.none, 60), (.kind, 250)] {
            BrowserMemory.remember(BrowserViewState(layout: .icons, group: group), for: .folders)
            try await measure(URL(fileURLWithPath: path), label: "\(group.rawValue), \(Int(step)) pt steps", step: step)
        }
    }

    private func measure(_ url: URL, label: String, step: CGFloat) async throws {
        var clock = CFAbsoluteTimeGetCurrent()
        func lap() -> Double {
            let now = CFAbsoluteTimeGetCurrent()
            defer { clock = now }
            return (now - clock) * 1000
        }
        let preview = try await PreviewFactory.makePreview(for: url, settings: PreviewSettings())
        let built = lap()
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 980, height: 640), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = preview
        window.orderFrontRegardless()
        preview.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        CATransaction.flush()
        let painted = lap()
        let browser = try XCTUnwrap(preview.content.firstSubview(of: MemberBrowserView.self))
        let grid = try XCTUnwrap(browser.grid)
        let count = grid.allNodes.count

        // Two rows a step, as a quick flick of the wheel moves; the run loop turns between steps so
        // thumbnails land as they would on screen.
        let scroll = grid.scrollView
        var frames: [Double] = []
        var y: CGFloat = 0
        let end = grid.collectionView.frame.height - scroll.contentView.bounds.height
        var waiting = 0
        while y < end {
            y = min(end, y + step)
            let start = CFAbsoluteTimeGetCurrent()
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
            grid.collectionView.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            CATransaction.flush()
            frames.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
            waiting = max(waiting, grid.pendingThumbnails)
            try await Task.sleep(nanoseconds: 8_000_000)
        }
        let sorted = frames.sorted()
        let average = frames.reduce(0, +) / Double(max(frames.count, 1))
        let p95 = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        print(String(format: "PERF [%@] %d items: built %.0f ms, first paint %.0f ms; %d scroll steps avg %.1f ms, p95 %.1f ms, max %.1f ms; at most %d thumbnails waited for, %d at the end",
                     label, count, built, painted, frames.count, average, p95, sorted.last ?? 0, waiting, grid.pendingThumbnails))
        XCTAssertLessThan(grid.pendingThumbnails, 200, "thumbnails scrolled away are cancelled")
        window.orderOut(nil)
    }
}
