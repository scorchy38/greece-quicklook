import XCTest
@testable import GreeceKit

/// Column filters on SQLite tables and views, done in SQL.
@MainActor
final class SQLiteFilterTests: XCTestCase {
    private let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/data/harbour.sqlite")

    private func source(_ name: String) throws -> SQLiteGridSource {
        let database = try SQLiteDatabase(url: url)
        let object = try XCTUnwrap(database.objects.first { $0.name == name })
        return SQLiteGridSource(database: database, worker: SQLiteWorker(url: url), object: object)
    }

    private func filter(_ source: SQLiteGridSource, _ filters: [ColumnFilter]) -> Bool {
        let done = expectation(description: "filtered")
        var result = false
        source.setFilters(filters) { result = $0; done.fulfill() }
        wait(for: [done], timeout: 10)
        return result
    }

    private func column(_ index: Int, of source: SQLiteGridSource) -> [String] {
        (0..<source.rowCount).map { source.value(row: $0, column: index).plainText }
    }

    func testFiltersMatchWhatTheGridShows() throws {
        let vessels = try source("vessels")
        XCTAssertTrue(filter(vessels, [ColumnFilter(column: 4, test: .equals("2400"))]), "an integer column, compared as shown")
        XCTAssertEqual(vessels.rowCount, 5)
        XCTAssertEqual(vessels.tableRows, 18)
        XCTAssertEqual(Set(column(4, of: vessels)), ["2400"])

        XCTAssertTrue(filter(vessels, [ColumnFilter(column: 4, test: .notEquals("2400"))]))
        XCTAssertEqual(vessels.rowCount, 13)
        XCTAssertTrue(filter(vessels, [ColumnFilter(column: 5, test: .null)]))
        XCTAssertTrue((0..<vessels.rowCount).allSatisfy { vessels.value(row: $0, column: 5) == .null })
        let nulls = vessels.rowCount
        XCTAssertTrue(filter(vessels, [ColumnFilter(column: 5, test: .notNull)]))
        XCTAssertEqual(vessels.rowCount + nulls, 18)

        XCTAssertTrue(filter(vessels, [ColumnFilter(column: 4, test: .atLeast(1800, text: "1800")),
                                       ColumnFilter(column: 2, test: .notEquals("Delos 2"))]))
        XCTAssertEqual(vessels.rowCount, 6, "two at 1800 and five at 2400, less Delos 2")
        XCTAssertTrue(filter(vessels, []))
        XCTAssertEqual(vessels.rowCount, 18)
        XCTAssertEqual(Array(column(0, of: vessels).prefix(3)), ["1", "2", "3"], "back in rowid order")
    }

    func testFiltersKeepTheSortAndSortsKeepTheFilters() throws {
        let vessels = try source("vessels")
        let sorted = expectation(description: "sorted")
        vessels.sort(column: 3, ascending: false) { _ in sorted.fulfill() }
        wait(for: [sorted], timeout: 10)
        XCTAssertTrue(filter(vessels, [ColumnFilter(column: 4, test: .equals("1200"))]))
        let built = column(3, of: vessels).compactMap { Int($0) }
        XCTAssertEqual(built.count, 7)
        XCTAssertEqual(built, built.sorted(by: >))
        let resorted = expectation(description: "resorted")
        vessels.sort(column: 3, ascending: true) { _ in resorted.fulfill() }
        wait(for: [resorted], timeout: 10)
        XCTAssertEqual(column(3, of: vessels).compactMap { Int($0) }, built.sorted())
    }

    func testViewsFilterInEveryPage() throws {
        let routes = try source("busy_routes")
        XCTAssertTrue(filter(routes, [ColumnFilter(column: 1, test: .equals("Naxos"))]))
        XCTAssertGreaterThan(routes.rowCount, 0)
        XCTAssertLessThan(routes.rowCount, routes.tableRows)
        XCTAssertEqual(Set(column(1, of: routes)), ["Naxos"])
    }

    func testCellsOfferWhatTheyCanBeFilteredBy() throws {
        let vessels = try source("vessels")
        guard case .text("Express 1") = vessels.filterCell(row: 0, column: 2) else { return XCTFail("text") }
        guard case .null = vessels.filterCell(row: 0, column: 5) else { return XCTFail("NULL") }
        guard case .unfilterable = vessels.filterCell(row: 2, column: 5) else { return XCTFail("a picture") }
    }

    func testFilterSQLBindsValuesAndKeepsNullsWhenHiding() {
        let hide = ColumnFilter(column: 0, test: .notEquals("O'Brien")).sql(column: "na\"me")
        XCTAssertEqual(hide.sql, "(\"na\"\"me\" IS NULL OR CAST(\"na\"\"me\" AS TEXT) <> ?)")
        XCTAssertEqual(hide.bindings, [.text("O'Brien")])
        XCTAssertEqual(ColumnFilter(column: 0, test: .atMost(5, text: "5")).sql(column: "n").bindings, [.real(5)])
    }

    func testBrowserMenusAndTokens() throws {
        let database = try SQLiteDatabase(url: url)
        let browser = SQLiteBrowserView(database: database, settings: PreviewSettings())
        let sidebar = try XCTUnwrap(browser.descendants(of: NSTableView.self).first { !($0 is GridTableView) })
        let names = (0..<sidebar.numberOfRows).map {
            (sidebar.view(atColumn: 0, row: $0, makeIfNecessary: true) as? NSTableCellView)?.textField?.stringValue
        }
        let vessels = try XCTUnwrap(names.firstIndex(of: "vessels"))
        sidebar.selectRowIndexes([vessels], byExtendingSelection: false)
        let grid = try XCTUnwrap(browser.descendants(of: GridView.self).first)
        XCTAssertEqual(grid.source.title(ofColumn: 4), "capacity")
        let menu = grid.menu(forRow: 0, column: 4)
        XCTAssertEqual(menu.items.map { $0.isSeparatorItem ? "—" : $0.title }, [
            "Copy “1800”", "Copy Row", "—",
            "Show Only Rows Where capacity Is “1800”", "Hide Rows Where capacity Is “1800”",
            "Show Only Rows Where capacity ≥ 1800", "Show Only Rows Where capacity ≤ 1800",
        ])
        let done = expectation(description: "filtered")
        done.assertForOverFulfill = false
        let poll = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            MainActor.assumeIsolated {
                if browser.descendants(of: FilterToken.self).count == 1, grid.source.rowCount == 2 { done.fulfill() }
            }
        }
        (menu.items[3] as? ActionMenuItem)?.perform()
        wait(for: [done], timeout: 10)
        poll.invalidate()
        XCTAssertTrue(browser.descendants(of: NSTextField.self).contains { $0.stringValue == "2 of 18 rows" })
        XCTAssertEqual(grid.menu(forRow: nil, column: nil).items.map(\.title), ["Clear Filters"])
    }
}
