import XCTest
@testable import GreeceKit

private let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

/// Context menus that stand in for keyboard shortcuts and double-clicks, which Quick Look keeps
/// for Finder.
@MainActor
final class PointerMenuTests: XCTestCase {
    private var pasteboard: NSPasteboard!
    private var typing = true

    override func setUp() {
        super.setUp()
        pasteboard = NSPasteboard(name: NSPasteboard.Name("greece-tests-\(UUID().uuidString)"))
        Clipboard.pasteboard = pasteboard
        typing = PreviewHost.acceptsTyping
    }

    override func tearDown() {
        pasteboard.releaseGlobally()
        Clipboard.pasteboard = .general
        PreviewHost.acceptsTyping = typing
        super.tearDown()
    }

    private var copied: String? { pasteboard.string(forType: .string) }

    private func titles(_ items: [NSMenuItem]) -> [String] {
        items.map { $0.isSeparatorItem ? "—" : $0.title }
    }

    private func perform(_ title: String, in items: [NSMenuItem], file: StaticString = #filePath, line: UInt = #line) {
        guard let item = items.first(where: { $0.title == title }) as? ActionMenuItem else {
            return XCTFail("no “\(title)” in \(titles(items))", file: file, line: line)
        }
        item.perform()
    }

    // MARK: - File lists

    private func tree() -> FileTreeView {
        let a = FileNode(name: "a.txt", isDirectory: false, size: 10)
        a.path = "docs/a.txt"
        let b = FileNode(name: "b.txt", isDirectory: false, size: 20)
        b.path = "docs/b.txt"
        let docs = FileNode(name: "docs", isDirectory: true, children: [a, b])
        docs.path = "docs"
        let readme = FileNode(name: "readme.md", isDirectory: false, size: 5)
        readme.path = "readme.md"
        let root = FileNode(name: "", isDirectory: true, children: [docs, readme])
        root.computeArchiveTotals()
        return FileTreeView(root: root, settings: PreviewSettings(), showsKind: false)
    }

    func testFileListMenusCopyAndOpenFolders() {
        let view = tree()
        view.onGetInfo = { _ in }
        PreviewHost.acceptsTyping = false
        let outline = view.outline
        let docs = outline.row(forItem: view.root.children?[0])
        var items = view.rowMenuItems(forRow: docs)
        XCTAssertEqual(titles(items), ["Get Info", "—", "Expand", "Expand All", "—", "Copy Name"])
        XCTAssertEqual(items[0].keyEquivalent, "", "no ⌘I where Finder would take it")
        perform("Expand", in: items)
        XCTAssertTrue(outline.isItemExpanded(view.root.children?[0]))
        items = view.rowMenuItems(forRow: docs)
        XCTAssertEqual(titles(items)[2...3], ["Collapse", "Collapse All"])
        perform("Collapse", in: items)
        XCTAssertFalse(outline.isItemExpanded(view.root.children?[0]))

        // A file inside a folder: its name and its path.
        perform("Expand All", in: view.rowMenuItems(forRow: docs))
        let a = outline.row(forItem: view.root.children?[0].children?[0])
        items = view.rowMenuItems(forRow: a)
        XCTAssertEqual(titles(items), ["Get Info", "—", "Copy Name", "Copy Path"])
        perform("Copy Path", in: items)
        XCTAssertEqual(copied, "docs/a.txt")

        // Several selected: all their names.
        outline.selectRowIndexes([a, a + 1], byExtendingSelection: false)
        items = view.rowMenuItems(forRow: a + 1)
        XCTAssertEqual(titles(items).suffix(2), ["Copy Names", "Copy Paths"])
        perform("Copy Names", in: items)
        XCTAssertEqual(copied, "a.txt\nb.txt")
    }

    func testDoubleClickOnlyWhereItIsntQuickLooks() {
        PreviewHost.acceptsTyping = false
        XCTAssertNil(tree().outline.doubleAction, "in Quick Look a double-click opens the file in its app")
        PreviewHost.acceptsTyping = true
        let view = tree()
        XCTAssertNotNil(view.outline.doubleAction)
        view.onGetInfo = { _ in }
        XCTAssertEqual(view.rowMenuItems(forRow: 0).first?.keyEquivalent, "i")
    }

    func testArchiveInfoAndPackageMenus() {
        let node = FileNode(name: "a.txt", isDirectory: false, size: 1200)
        node.path = "docs/a.txt"
        let items = EntryInfoView.menuItems(node, kind: "Plain Text")
        XCTAssertEqual(titles(items), ["Copy Name", "Copy Path", "Copy Info"])
        perform("Copy Info", in: items)
        XCTAssertEqual(copied?.components(separatedBy: "\n").prefix(3), ["a.txt", "Plain Text · 1 KB", "Size: 1,200 bytes (1 KB)"])
        XCTAssertNotNil(EntryInfoView(node: node, kind: "Plain Text").menu)

        var info = PackageInfo(kind: .wheel, name: "harbourmaster", version: "2.4.1")
        info.dependencies = ["requests>=2.31", "click"]
        let package = PackageHeaderView.menuItems(info)
        XCTAssertEqual(titles(package), ["Copy Name", "Copy Version", "Copy Dependencies"])
        perform("Copy Dependencies", in: package)
        XCTAssertEqual(copied, "requests>=2.31\nclick")
    }

    // MARK: - SQLite

    private func database() throws -> SQLiteDatabase {
        try SQLiteDatabase(url: repo.appendingPathComponent("Fixtures/data/harbour.sqlite"))
    }

    func testSchemaTablesCopyCellsRowsAndTables() {
        let table = SchemaTableView(headers: ["Name", "Type", "Default"], rows: [
            [.name("id", symbol: "key.fill"), .code("INTEGER"), .none],
            [.name("name"), .code("TEXT"), .code("''")],
        ])
        let items = table.menuItems(row: 0, column: 1)
        XCTAssertEqual(titles(items), ["Copy “INTEGER”", "Copy Row", "Copy Table"])
        perform("Copy Row", in: items)
        XCTAssertEqual(copied, "id\tINTEGER\t", "“—” stands for nothing and copies as nothing")
        XCTAssertEqual(titles(table.menuItems(row: 0, column: 2)), ["Copy Row", "Copy Table"])
        perform("Copy Table", in: items)
        XCTAssertEqual(copied, "Name\tType\tDefault\nid\tINTEGER\t\nname\tTEXT\t''")
        XCTAssertNil(table.row(at: NSPoint(x: 20, y: 4)), "the header isn't a row")
        XCTAssertEqual(table.row(at: NSPoint(x: 20, y: SchemaTableView.headerHeight + SchemaTableView.rowHeight + 2)), 1)
    }

    func testDiagramTablesOpenFromTheirMenus() throws {
        let diagram = RelationshipDiagram(database: try database())
        let view = SQLiteDiagramView(diagram: diagram)
        var opened: [String] = []
        view.canvas.onOpen = { opened.append("data " + $0) }
        view.canvas.onShowSchema = { opened.append("schema " + $0) }
        let items = view.canvas.menuItems(forTable: "vessels")
        XCTAssertEqual(titles(items), ["Show Data", "Show Schema", "—", "Copy Name"])
        perform("Show Data", in: items)
        perform("Show Schema", in: items)
        XCTAssertEqual(opened, ["data vessels", "schema vessels"])

        let zoom = view.zoomMenuItems()
        XCTAssertEqual(titles(zoom), ["Zoom In", "Zoom Out", "—", "Zoom to Fit", "Actual Size"])
        XCTAssertEqual(zoom.first { $0.title == "Actual Size" }?.isEnabled, false, "already at actual size")
        perform("Zoom Out", in: zoom)
        XCTAssertEqual(view.zoomMenuItems().first { $0.title == "Actual Size" }?.isEnabled, true)
    }

    func testSQLiteSidebarAndGridMenus() throws {
        let database = try database()
        let browser = SQLiteBrowserView(database: database, settings: PreviewSettings())
        let sidebar = try XCTUnwrap(browser.descendants(of: NSTableView.self).first { !($0 is GridTableView) })
        let vessels = try XCTUnwrap((0..<sidebar.numberOfRows).first { browser.sidebarMenuItems(forRow: $0).first.map { _ in true } ?? false })
        let items = browser.sidebarMenuItems(forRow: vessels)
        XCTAssertEqual(titles(items), ["Copy Name", "Copy CREATE Statement"])
        XCTAssertTrue(browser.sidebarMenuItems(forRow: -1).isEmpty)

        let grid = try XCTUnwrap(browser.descendants(of: GridView.self).first)
        let menu = grid.menu(forRow: 0, column: 0)
        XCTAssertEqual(titles(menu.items).prefix(2).last, "Copy Row")
    }

    // MARK: - Inspector

    func testInspectorSectionsCopyAsText() {
        let section = InspectorSection("entitlements", title: "Entitlements", rows: [
            .item(InspectorItem(title: "App Sandbox", value: "Yes")),
            .item(InspectorItem(title: "com.apple.security.network.client", subtitle: "Outgoing connections", mono: true)),
            .note(InspectorNote(symbol: nil, text: "Signed for development.", tone: .caution)),
        ])
        XCTAssertEqual(section.copyText, """
            Entitlements
            App Sandbox: Yes
            com.apple.security.network.client
                Outgoing connections
            Signed for development.
            """)
    }
}
