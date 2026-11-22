import XCTest
@testable import GreeceKit

/// Column filters on in-memory tables, and the context menus that set them.
@MainActor
final class TableFilterTests: XCTestCase {
    private var pasteboard: NSPasteboard!

    override func setUp() {
        super.setUp()
        // Never the person's clipboard.
        pasteboard = NSPasteboard(name: NSPasteboard.Name("greece-tests-\(UUID().uuidString)"))
        Clipboard.pasteboard = pasteboard
    }

    override func tearDown() {
        pasteboard.releaseGlobally()
        Clipboard.pasteboard = .general
        super.tearDown()
    }

    private static let islands = """
        island\tgroup\tarea\tnotes
        Naxos\tCyclades\t430\tlargest
        Corfu\tIonian\t610.9\t
        Ithaca\tIonian\t96\t\u{20}\u{20}
        Paros\tCyclades\t196\tmarble
        Kea\tCyclades\tunknown\t
        Rhodes\tDodecanese\t1,401\tknights
        """

    private func source(_ text: String = islands) -> RecordGridSource {
        RecordGridSource(store: DelimitedStore(table: DelimitedTable.parse(text + "\n", separator: UInt8(ascii: "\t"))))
    }

    /// The visible values of a column.
    private func column(_ index: Int, of source: RecordGridSource) -> [String] {
        (0..<source.rowCount).map { source.value(row: $0, column: index).plainText }
    }

    private func apply(_ change: (@escaping () -> Void) -> Void) {
        let done = expectation(description: "filtered")
        change { done.fulfill() }
        wait(for: [done], timeout: 5)
    }

    // MARK: - Filters

    func testShowOnlyKeepsEqualValues() {
        let source = source()
        apply { source.addColumnFilter(ColumnFilter(column: 1, test: .equals("Cyclades")), completion: $0) }
        XCTAssertEqual(column(0, of: source), ["Naxos", "Paros", "Kea"])
        XCTAssertTrue(source.isFiltered)
        // Exact matches only: no substrings, no case folding.
        apply { source.addColumnFilter(ColumnFilter(column: 1, test: .equals("cyclades")), completion: $0) }
        XCTAssertEqual(source.rowCount, 0)
    }

    func testHideRemovesEqualValues() {
        let source = source()
        apply { source.addColumnFilter(ColumnFilter(column: 1, test: .notEquals("Ionian")), completion: $0) }
        XCTAssertEqual(column(0, of: source), ["Naxos", "Paros", "Kea", "Rhodes"])
    }

    func testEmptyMeansBlank() {
        let source = source()
        apply { source.addColumnFilter(ColumnFilter(column: 3, test: .equals("")), completion: $0) }
        // An empty field and one holding only spaces are both empty.
        XCTAssertEqual(column(0, of: source), ["Corfu", "Ithaca", "Kea"])
        apply { source.setColumnFilters([ColumnFilter(column: 3, test: .notEquals(""))], completion: $0) }
        XCTAssertEqual(column(0, of: source), ["Naxos", "Paros", "Rhodes"])
        XCTAssertTrue(ColumnFilter.isBlank(" \t"))
        XCTAssertFalse(ColumnFilter.isBlank(" a "))
    }

    func testNumericBoundsSkipWhatIsntANumber() {
        let source = source()
        apply { source.addColumnFilter(ColumnFilter(column: 2, test: .atLeast(200, text: "200")), completion: $0) }
        XCTAssertEqual(column(0, of: source), ["Naxos", "Corfu", "Rhodes"], "1,401 reads as a number; “unknown” doesn’t")
        apply { source.addColumnFilter(ColumnFilter(column: 2, test: .atMost(500, text: "500")), completion: $0) }
        XCTAssertEqual(column(0, of: source), ["Naxos"])
    }

    func testColumnFiltersAndTextFilterCombine() {
        let source = source()
        apply { source.setFilter("an", completion: $0) }
        XCTAssertEqual(column(0, of: source), ["Corfu", "Ithaca", "Rhodes"], "Ionian and Dodecanese")
        apply { source.addColumnFilter(ColumnFilter(column: 1, test: .equals("Ionian")), completion: $0) }
        XCTAssertEqual(column(0, of: source), ["Corfu", "Ithaca"])
        apply { source.addColumnFilter(ColumnFilter(column: 2, test: .atLeast(100, text: "100")), completion: $0) }
        XCTAssertEqual(column(0, of: source), ["Corfu"])
        // Clearing the text keeps the column filters.
        apply { source.setFilter("", completion: $0) }
        XCTAssertEqual(column(0, of: source), ["Corfu"])
        XCTAssertEqual(source.columnFilters.count, 2)
    }

    func testFiltersKeepTheSortOrder() {
        let source = source()
        source.sort(column: 0, ascending: false) { _ in }
        apply { source.addColumnFilter(ColumnFilter(column: 1, test: .equals("Cyclades")), completion: $0) }
        XCTAssertEqual(column(0, of: source), ["Paros", "Naxos", "Kea"])
    }

    func testRemovingAndClearing() {
        let source = source()
        let cyclades = ColumnFilter(column: 1, test: .equals("Cyclades"))
        let noted = ColumnFilter(column: 3, test: .notEquals(""))
        apply { source.addColumnFilter(cyclades, completion: $0) }
        apply { source.addColumnFilter(noted, completion: $0) }
        XCTAssertEqual(column(0, of: source), ["Naxos", "Paros"])
        apply { source.removeColumnFilter(cyclades, completion: $0) }
        XCTAssertEqual(source.columnFilters, [noted])
        XCTAssertEqual(column(0, of: source), ["Naxos", "Paros", "Rhodes"])
        apply { source.setFilter("naxos", completion: $0) }
        apply { source.clearFilters(completion: $0) }
        XCTAssertFalse(source.isFiltered)
        XCTAssertEqual(source.filter, "")
        XCTAssertEqual(source.rowCount, 6)
    }

    func testNewFiltersReplaceOnesTheyContradict() {
        let source = source()
        let cyclades = ColumnFilter(column: 1, test: .equals("Cyclades"))
        let ionian = ColumnFilter(column: 1, test: .equals("Ionian"))
        apply { source.addColumnFilter(cyclades, completion: $0) }
        apply { source.addColumnFilter(ionian, completion: $0) }
        XCTAssertEqual(source.columnFilters, [ionian], "one value shown at a time")
        XCTAssertEqual(source.rowCount, 2)
        let hideIonian = ColumnFilter(column: 1, test: .notEquals("Ionian"))
        apply { source.addColumnFilter(hideIonian, completion: $0) }
        XCTAssertEqual(source.columnFilters, [hideIonian], "hiding what was shown undoes showing it")
        XCTAssertEqual(source.rowCount, 4)
        // Other columns, and the same filter twice, leave the rest alone.
        let area = ColumnFilter(column: 2, test: .atLeast(100, text: "100"))
        apply { source.addColumnFilter(area, completion: $0) }
        apply { source.addColumnFilter(area, completion: $0) }
        XCTAssertEqual(source.columnFilters, [hideIonian, area])
    }

    func testTokenLabels() {
        XCTAssertEqual(ColumnFilter(column: 1, test: .equals("Cyclades")).label(columnTitle: "group"), "group = Cyclades")
        XCTAssertEqual(ColumnFilter(column: 1, test: .notEquals("Cyclades")).label(columnTitle: "group"), "group ≠ Cyclades")
        XCTAssertEqual(ColumnFilter(column: 1, test: .equals("")).label(columnTitle: "notes"), "notes is empty")
        XCTAssertEqual(ColumnFilter(column: 1, test: .notEquals("")).label(columnTitle: "notes"), "notes is not empty")
        XCTAssertEqual(ColumnFilter(column: 2, test: .atLeast(1401, text: "1,401")).label(columnTitle: "area"), "area ≥ 1,401")
        XCTAssertEqual(ColumnFilter(column: 2, test: .atMost(96, text: "96")).label(columnTitle: "area"), "area ≤ 96")
    }

    /// Large tables filter off the main thread, and a filter that finishes late never wins over
    /// a newer one.
    func testLargeTablesFilterInTheBackground() {
        var text = "id\tcity\n"
        let cities = ["Athens", "Naxos", "Paros", "Syros"]
        for i in 0..<200_000 { text += "\(i)\t\(cities[i % 4])\n" }
        let source = RecordGridSource(store: DelimitedStore(table: DelimitedTable.parse(text, separator: UInt8(ascii: "\t"), maxRows: 300_000)))
        XCTAssertGreaterThanOrEqual(source.totalRows, RecordGridSource.backgroundRows)

        var finished = 0
        let first = expectation(description: "first")
        let second = expectation(description: "second")
        source.addColumnFilter(ColumnFilter(column: 1, test: .equals("Naxos"))) { finished += 1; first.fulfill() }
        source.addColumnFilter(ColumnFilter(column: 1, test: .equals("Paros"))) { finished += 1; second.fulfill() }
        XCTAssertEqual(finished, 0, "not on the main thread")
        XCTAssertEqual(source.rowCount, 200_000, "the rows change when the work is done, not before")
        wait(for: [first, second], timeout: 20)
        XCTAssertEqual(source.rowCount, 50_000)
        XCTAssertEqual(source.value(row: 0, column: 1).plainText, "Paros")

        // A sort while a filter is still running already includes it.
        let third = expectation(description: "third")
        source.addColumnFilter(ColumnFilter(column: 1, test: .equals("Syros"))) { third.fulfill() }
        source.sort(column: 0, ascending: false) { _ in }
        XCTAssertEqual(source.rowCount, 50_000)
        XCTAssertEqual(source.value(row: 0, column: 0).plainText, "199999")
        wait(for: [third], timeout: 20)
        XCTAssertEqual(source.value(row: 0, column: 0).plainText, "199999", "the older background result was dropped")
    }

    /// A million rows made up as they're read, so the test measures filtering, not parsing.
    private final class MillionRows: RecordStore {
        let columns = [RecordColumn(title: "id", numeric: true), RecordColumn(title: "city")]
        let rowCount = 1_000_000
        private let cities = ["Athens", "Naxos", "Paros", "Syros"]
        func value(row: Int, column: Int) -> GridValue { .text(text(row: row, column: column)) }
        func text(row: Int, column: Int) -> String { column == 0 ? String(row) : cities[row % 4] }
    }

    func testMillionRowsFilterOffTheMainThread() {
        let source = RecordGridSource(store: MillionRows())
        let started = CFAbsoluteTimeGetCurrent()
        let done = expectation(description: "filtered")
        source.addColumnFilter(ColumnFilter(column: 1, test: .equals("Naxos"))) { done.fulfill() }
        let returned = CFAbsoluteTimeGetCurrent() - started
        wait(for: [done], timeout: 30)
        let equality = CFAbsoluteTimeGetCurrent() - started
        XCTAssertEqual(source.rowCount, 250_000)

        let bounded = expectation(description: "bounded")
        let again = CFAbsoluteTimeGetCurrent()
        source.addColumnFilter(ColumnFilter(column: 0, test: .atMost(1000, text: "1000"))) { bounded.fulfill() }
        wait(for: [bounded], timeout: 30)
        let bound = CFAbsoluteTimeGetCurrent() - again
        XCTAssertEqual(source.rowCount, 250)
        print(String(format: "Table 1M rows filter: returns in %.2f ms · equality %.0f ms · plus a number bound %.0f ms",
                     returned * 1000, equality * 1000, bound * 1000))
        XCTAssertLessThan(returned, 0.01, "the main thread only hands the work over")
        XCTAssertLessThan(equality, 5)
    }

    // MARK: - Menus

    private func tableView(_ text: String = islands) -> DataTableView {
        let table = DelimitedTable.parse(text + "\n", separator: UInt8(ascii: "\t"))
        var options = DataTableView.Options()
        options.profiles = false
        return DataTableView(store: DelimitedStore(table: table), settings: PreviewSettings(), options: options)
    }

    private func titles(_ menu: NSMenu) -> [String] {
        menu.items.map { $0.isSeparatorItem ? "—" : ($0.state == .on ? "✓ " : "") + $0.title }
    }

    private func item(_ title: String, in menu: NSMenu, file: StaticString = #filePath, line: UInt = #line) -> ActionMenuItem? {
        let found = menu.items.first { $0.title == title } as? ActionMenuItem
        XCTAssertNotNil(found, "no “\(title)” in \(titles(menu))", file: file, line: line)
        return found
    }

    func testCellMenuForTextValue() throws {
        let view = tableView()
        let menu = view.grid.menu(forRow: 0, column: 1)
        XCTAssertEqual(titles(menu), [
            "Copy “Cyclades”",
            "Copy Row",
            "—",
            "Show Only Rows Where group Is “Cyclades”",
            "Hide Rows Where group Is “Cyclades”",
        ])
        XCTAssertTrue(menu.items.filter { !$0.isSeparatorItem }.allSatisfy(\.isEnabled))
        XCTAssertFalse(menu.autoenablesItems, "enabled as built: there may be no responder chain in Quick Look")

        try XCTUnwrap(item("Copy “Cyclades”", in: menu)).perform()
        XCTAssertEqual(pasteboard.string(forType: .string), "Cyclades")
        try XCTUnwrap(item("Copy Row", in: menu)).perform()
        XCTAssertEqual(pasteboard.string(forType: .string), "Naxos\tCyclades\t430\tlargest")

        try XCTUnwrap(item("Show Only Rows Where group Is “Cyclades”", in: menu)).perform()
        XCTAssertEqual(view.source.rowCount, 3)
        XCTAssertEqual(view.source.columnFilters, [ColumnFilter(column: 1, test: .equals("Cyclades"))])
    }

    func testCellMenuForEmptyValue() throws {
        let view = tableView()
        // Ithaca's notes hold only spaces: empty, and nothing to copy.
        let menu = view.grid.menu(forRow: 2, column: 3)
        XCTAssertEqual(titles(menu), [
            "Copy Row",
            "—",
            "Show Only Rows Where notes Is Empty",
            "Hide Rows Where notes Is Empty",
        ])
        try XCTUnwrap(item("Hide Rows Where notes Is Empty", in: menu)).perform()
        XCTAssertEqual(view.source.rowCount, 3)
    }

    func testCellMenuForNumbersOffersBounds() throws {
        let areas = "island\tarea\nNaxos\t430\nCorfu\t610.9\nIthaca\t96\nParos\t196\nKea\tunknown\nRhodes\t1,401\nSyros\t84\nMilos\t151"
        let view = tableView(areas)
        XCTAssertTrue(view.source.holdsNumbers(column: 1))
        let menu = view.grid.menu(forRow: 5, column: 1)
        XCTAssertEqual(titles(menu), [
            "Copy “1,401”",
            "Copy Row",
            "—",
            "Show Only Rows Where area Is “1,401”",
            "Hide Rows Where area Is “1,401”",
            "Show Only Rows Where area ≥ 1,401",
            "Show Only Rows Where area ≤ 1,401",
        ])
        try XCTUnwrap(item("Show Only Rows Where area ≤ 1,401", in: menu)).perform()
        XCTAssertEqual(view.source.rowCount, 7, "every number, not “unknown”")
        // A value that isn't a number gets no bounds, and text columns never do.
        XCTAssertFalse(titles(tableView(areas).grid.menu(forRow: 4, column: 1)).contains { $0.contains("≥") })
        XCTAssertFalse(titles(tableView(areas).grid.menu(forRow: 4, column: 0)).contains { $0.contains("≥") })
    }

    func testActiveFiltersAreCheckedAndClearable() throws {
        let view = tableView()
        try XCTUnwrap(item("Show Only Rows Where group Is “Cyclades”", in: view.grid.menu(forRow: 0, column: 1))).perform()
        let menu = view.grid.menu(forRow: 0, column: 1)
        XCTAssertEqual(titles(menu).suffix(4), [
            "✓ Show Only Rows Where group Is “Cyclades”",
            "Hide Rows Where group Is “Cyclades”",
            "—",
            "Clear Filters",
        ])
        // Choosing a checked filter turns it off.
        try XCTUnwrap(item("Show Only Rows Where group Is “Cyclades”", in: menu)).perform()
        XCTAssertFalse(view.source.isFiltered)

        try XCTUnwrap(item("Hide Rows Where group Is “Cyclades”", in: view.grid.menu(forRow: 0, column: 1))).perform()
        XCTAssertEqual(view.source.rowCount, 3)
        // Off the rows, only Clear Filters.
        let background = view.grid.menu(forRow: nil, column: nil)
        XCTAssertEqual(titles(background), ["Clear Filters"])
        try XCTUnwrap(item("Clear Filters", in: background)).perform()
        XCTAssertEqual(view.source.rowCount, 6)
        XCTAssertTrue(view.grid.menu(forRow: nil, column: nil).items.isEmpty)
    }

    func testSeveralSelectedRowsCopyTogether() throws {
        let view = tableView()
        view.grid.tableView.selectRowIndexes([0, 1], byExtendingSelection: false)
        let menu = view.grid.menu(forRow: 1, column: 0)
        XCTAssertEqual(Array(titles(menu).prefix(3)), ["Copy “Corfu”", "Copy Row", "Copy Selected Rows"])
        try XCTUnwrap(item("Copy Selected Rows", in: menu)).perform()
        XCTAssertEqual(pasteboard.string(forType: .string), "Naxos\tCyclades\t430\tlargest\nCorfu\tIonian\t610.9\t")
        // On the row numbers: rows only.
        XCTAssertEqual(Array(titles(view.grid.menu(forRow: 1, column: nil)).prefix(2)), ["Copy Row", "Copy Selected Rows"])
    }

    func testLongValuesAreShortenedInTitles() {
        let long = String(repeating: "Aegean ", count: 12)
        let view = tableView("name\tnote\nA\t\(long)")
        let title = view.grid.menu(forRow: 0, column: 1).items[0].title
        XCTAssertTrue(title.hasPrefix("Copy “Aegean Aegean"))
        XCTAssertTrue(title.hasSuffix("…”"))
        XCTAssertLessThan(title.count, 45)
        XCTAssertEqual(MenuText.quoted("two\nlines"), "“two lines”")
    }

    func testHeaderMenuSortsAndCopies() throws {
        let view = tableView()
        let menu = view.grid.headerMenu(forColumn: 0)
        XCTAssertEqual(titles(menu), ["Sort Ascending", "Sort Descending", "—", "Copy “island”", "Copy Column"])
        try XCTUnwrap(item("Sort Descending", in: menu)).perform()
        XCTAssertEqual(view.source.value(row: 0, column: 0).plainText, "Rhodes")
        XCTAssertEqual(titles(view.grid.headerMenu(forColumn: 0)).prefix(2), ["Sort Ascending", "✓ Sort Descending"])
        try XCTUnwrap(item("Copy Column", in: view.grid.headerMenu(forColumn: 0))).perform()
        XCTAssertEqual(pasteboard.string(forType: .string), "Rhodes\nParos\nNaxos\nKea\nIthaca\nCorfu")

        // Nothing to copy when no rows are left.
        view.source.setColumnFilters([ColumnFilter(column: 1, test: .equals("Atlantis"))]) {}
        XCTAssertEqual(view.source.rowCount, 0)
        XCTAssertEqual(item("Copy Column", in: view.grid.headerMenu(forColumn: 0))?.isEnabled, false)
    }

    func testTokensFollowTheFilters() throws {
        let view = tableView()
        try XCTUnwrap(item("Show Only Rows Where group Is “Cyclades”", in: view.grid.menu(forRow: 0, column: 1))).perform()
        try XCTUnwrap(item("Hide Rows Where notes Is Empty", in: view.grid.menu(forRow: 2, column: 3))).perform()
        var tokens = view.descendants(of: FilterToken.self)
        XCTAssertEqual(tokens.map { $0.accessibilityLabel() }, ["Filter: group = Cyclades", "Filter: notes is not empty"])
        XCTAssertTrue(view.descendants(of: NSTextField.self).contains { $0.stringValue == "2 of 6 rows" })
        // The token's button removes its filter.
        let remove = try XCTUnwrap(tokens[0].descendants(of: NSButton.self).first)
        remove.performClick(nil)
        tokens = view.descendants(of: FilterToken.self)
        XCTAssertEqual(tokens.map { $0.accessibilityLabel() }, ["Filter: notes is not empty"])
        XCTAssertEqual(view.source.rowCount, 3)
    }

    func testSearchFieldOnlyWhereTypingWorks() {
        let saved = PreviewHost.acceptsTyping
        defer { PreviewHost.acceptsTyping = saved }
        PreviewHost.acceptsTyping = true
        XCTAssertEqual(tableView().descendants(of: NSSearchField.self).count, 1)
        PreviewHost.acceptsTyping = false
        XCTAssertEqual(tableView().descendants(of: NSSearchField.self).count, 0)
        // The menus are the same either way.
        XCTAssertEqual(titles(tableView().grid.menu(forRow: 0, column: 1)).count, 5)
    }

    func testProfileValuesPickRows() throws {
        let table = DelimitedTable.parse(Self.islands + "\n", separator: UInt8(ascii: "\t"))
        let profile = ColumnProfile.make(rows: table.rows.count) { table.rows[$0][1] }
        var picked: [String] = []
        let popover = ProfilePopoverView(title: "group", profile: profile) { picked.append($0) }
        let rows = popover.descendants(of: CommonValueRow.self)
        XCTAssertEqual(rows.count, 3)
        XCTAssertTrue(rows.allSatisfy(\.isPickable))
        XCTAssertEqual(rows[0].toolTip, "Show Only Rows Where group Is “Cyclades”")
        XCTAssertTrue(rows[1].accessibilityPerformPress())
        XCTAssertEqual(picked, ["Ionian"])
        // Without a handler the values are just values.
        XCTAssertFalse(ProfilePopoverView(title: "group", profile: profile).descendants(of: CommonValueRow.self).contains(where: \.isPickable))
    }
}

extension NSView {
    /// Every view of a kind under this one, in order.
    func descendants<T: NSView>(of type: T.Type) -> [T] {
        subviews.flatMap { view -> [T] in
            let own: [T] = (view as? T).map { [$0] } ?? []
            return own + view.descendants(of: type)
        }
    }
}
