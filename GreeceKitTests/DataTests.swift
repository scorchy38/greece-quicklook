import XCTest
import SQLite3
import UniformTypeIdentifiers
@testable import GreeceKit

private let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
private let fixtures = repo.appendingPathComponent("Fixtures/data")

/// A fresh temporary folder per test.
private func temporaryFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("greece-data-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Builds a SQLite database with the C API (fast enough for a million rows in a test).
private final class DatabaseBuilder {
    private var db: OpaquePointer?
    let url: URL

    init(_ url: URL) throws {
        self.url = url
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw NSError(domain: "test", code: 1) }
    }

    func exec(_ sql: String) {
        var error: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &error) != SQLITE_OK {
            XCTFail("SQL failed: \(error.map { String(cString: $0) } ?? "?") in \(sql.prefix(120))")
            sqlite3_free(error)
        }
    }

    /// Inserts rows through one prepared statement inside a transaction.
    func insert(_ sql: String, count: Int, bind: (OpaquePointer, Int) -> Void) {
        exec("BEGIN")
        var statement: OpaquePointer?
        sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        for i in 0..<count {
            bind(statement!, i)
            sqlite3_step(statement)
            sqlite3_reset(statement)
        }
        sqlite3_finalize(statement)
        exec("COMMIT")
    }

    func close() { sqlite3_close(db); db = nil }
}

private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class SQLiteDataTests: XCTestCase {

    func testSchemaReadsKeysIndexesViewsAndTriggers() throws {
        let database = try SQLiteDatabase(url: fixtures.appendingPathComponent("harbour.sqlite"))
        XCTAssertEqual(database.objects.filter { !$0.isView }.count, 10)
        XCTAssertEqual(database.objects.filter(\.isView).map(\.name), ["busy_routes"])

        let tickets = try XCTUnwrap(database.objects.first { $0.name == "tickets" })
        XCTAssertEqual(tickets.rowCount, 2200)
        XCTAssertEqual(tickets.columns.first?.name, "id")
        XCTAssertTrue(tickets.columns[0].isPrimaryKey)
        XCTAssertEqual(Set(tickets.foreignKeys.map(\.table)), ["sailings", "passengers", "fares"])
        let composite = try XCTUnwrap(tickets.foreignKeys.first { $0.table == "fares" })
        XCTAssertEqual(composite.from, ["route_id", "class"])
        XCTAssertEqual(tickets.foreignKeys.first { $0.table == "sailings" }?.onDelete, "CASCADE")
        XCTAssertEqual(tickets.indexes.map(\.name), ["tickets_passenger"])
        XCTAssertEqual(tickets.indexes.first?.columns, ["passenger_id", "issued"])
        XCTAssertEqual(tickets.triggers.first?.timing, "AFTER")
        XCTAssertEqual(tickets.triggers.first?.event, "INSERT")

        let fares = try XCTUnwrap(database.objects.first { $0.name == "fares" })
        XCTAssertTrue(fares.withoutRowid)
        XCTAssertNil(fares.rowidAlias)
        XCTAssertEqual(fares.columns.filter(\.isPrimaryKey).map(\.primaryKey), [1, 2])

        let routes = try XCTUnwrap(database.objects.first { $0.name == "routes" })
        XCTAssertTrue(routes.indexes.contains { $0.name == "routes_pair" && $0.partial })
        let crew = try XCTUnwrap(database.objects.first { $0.name == "crew" })
        XCTAssertTrue(crew.foreignKeys.contains { $0.table == "crew" }, "self-reference")
        let vessels = try XCTUnwrap(database.objects.first { $0.name == "vessels" })
        XCTAssertEqual(vessels.columns.first { $0.name == "capacity" }?.defaultValue, "0")
    }

    func testRelationshipDiagramPlacesParentsLeftOfChildren() throws {
        let database = try SQLiteDatabase(url: fixtures.appendingPathComponent("harbour.sqlite"))
        let diagram = RelationshipDiagram(database: database)
        XCTAssertEqual(diagram.cards.count, 10)
        XCTAssertEqual(diagram.edges.count, 12)
        for edge in diagram.edges where edge.child != edge.parent {
            XCTAssertLessThan(diagram.cards[edge.parent].frame.minX, diagram.cards[edge.child].frame.minX,
                              "\(diagram.cards[edge.parent].name) should sit left of \(diagram.cards[edge.child].name)")
        }
        // No two cards overlap.
        for a in diagram.cards.indices {
            for b in diagram.cards.indices where b > a {
                XCTAssertFalse(diagram.cards[a].frame.intersects(diagram.cards[b].frame), "\(diagram.cards[a].name) overlaps \(diagram.cards[b].name)")
            }
        }
    }

    func testViewsPageAndSortWithSQL() throws {
        let database = try SQLiteDatabase(url: fixtures.appendingPathComponent("harbour.sqlite"))
        let view = try XCTUnwrap(database.objects.first { $0.name == "busy_routes" })
        let source = SQLiteGridSource(database: database, worker: SQLiteWorker(url: database.url), object: view)
        XCTAssertEqual(source.rowCount, 32)
        XCTAssertTrue(source.isNumeric(column: 3), "an untyped count column reads as numbers")
        let sorted = expectation(description: "sorted")
        source.sort(column: 1, ascending: true) { finished in
            XCTAssertTrue(finished)
            sorted.fulfill()
        }
        wait(for: [sorted], timeout: 5)
        let origins = (0..<source.rowCount).map { source.value(row: $0, column: 1).plainText }
        XCTAssertEqual(origins, origins.sorted())
    }

    /// A million rows, foreign keys, an index and a view, built in a temporary folder.
    private func millionRowDatabase() throws -> URL {
        let url = try temporaryFolder().appendingPathComponent("million.sqlite")
        let builder = try DatabaseBuilder(url)
        builder.exec("""
            CREATE TABLE customers (id INTEGER PRIMARY KEY, name TEXT NOT NULL, country TEXT);
            CREATE TABLE orders (id INTEGER PRIMARY KEY, customer_id INTEGER NOT NULL REFERENCES customers(id),
                                 amount REAL, note TEXT, created TEXT NOT NULL);
            CREATE INDEX orders_customer ON orders(customer_id);
            CREATE VIEW big_orders AS SELECT * FROM orders WHERE amount > 900;
            """)
        builder.insert("INSERT INTO customers VALUES (?, ?, ?)", count: 1000) { statement, i in
            sqlite3_bind_int64(statement, 1, Int64(i + 1))
            sqlite3_bind_text(statement, 2, "Customer \(i + 1)", -1, transient)
            sqlite3_bind_text(statement, 3, ["GR", "IT", "FR"][i % 3], -1, transient)
        }
        var seed: UInt64 = 42
        func next() -> UInt64 { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return seed >> 33 }
        builder.insert("INSERT INTO orders VALUES (?, ?, ?, ?, ?)", count: 1_000_000) { statement, i in
            sqlite3_bind_int64(statement, 1, Int64(i + 1))
            sqlite3_bind_int64(statement, 2, Int64(next() % 1000 + 1))
            sqlite3_bind_double(statement, 3, Double(next() % 100_000) / 100)
            sqlite3_bind_text(statement, 4, "order note \(next() % 5000)", -1, transient)
            sqlite3_bind_text(statement, 5, "2025-\(String(format: "%02d", i % 12 + 1))-\(String(format: "%02d", i % 28 + 1))", -1, transient)
        }
        builder.close()
        return url
    }

    func testMillionRowsOpenPageAndSortQuickly() throws {
        let url = try millionRowDatabase()
        var started = CFAbsoluteTimeGetCurrent()
        let database = try SQLiteDatabase(url: url)
        let opened = CFAbsoluteTimeGetCurrent() - started
        let orders = try XCTUnwrap(database.objects.first { $0.name == "orders" })
        XCTAssertEqual(orders.rowCount, 1_000_000)
        XCTAssertLessThan(opened, 2.5, "schema and counts")

        let worker = SQLiteWorker(url: url)
        let source = SQLiteGridSource(database: database, worker: worker, object: orders)
        XCTAssertEqual(source.rowCount, 1_000_000)
        // Jump straight to the end (an OFFSET scan), then scroll on from there (keyset paging).
        started = CFAbsoluteTimeGetCurrent()
        XCTAssertEqual(source.value(row: 999_999, column: 0).plainText, "1000000")
        let jump = CFAbsoluteTimeGetCurrent() - started
        started = CFAbsoluteTimeGetCurrent()
        for page in 0..<50 { _ = source.value(row: page * SQLiteGridSource.pageSize, column: 0) }
        let sequential = (CFAbsoluteTimeGetCurrent() - started) / 50
        XCTAssertEqual(source.value(row: 4_321, column: 0).plainText, "4322")

        // Sort by an unindexed column: built once off the main thread, then pages by rowid.
        let sorted = expectation(description: "sorted")
        started = CFAbsoluteTimeGetCurrent()
        var sortTime = 0.0
        source.sort(column: 2, ascending: false) { finished in
            XCTAssertTrue(finished)
            sortTime = CFAbsoluteTimeGetCurrent() - started
            sorted.fulfill()
        }
        wait(for: [sorted], timeout: 30)
        started = CFAbsoluteTimeGetCurrent()
        let amounts = (0..<500).map { Double(source.value(row: 500_000 + $0, column: 2).plainText) ?? -1 }
        let sortedPage = (CFAbsoluteTimeGetCurrent() - started) / Double(500 / SQLiteGridSource.pageSize + 1)
        XCTAssertEqual(amounts, amounts.sorted(by: >))
        XCTAssertGreaterThanOrEqual(Double(source.value(row: 0, column: 2).plainText) ?? 0, 999)

        print(String(format: "SQLite 1M rows: open %.0f ms · jump to end %.1f ms · next page %.2f ms · sort %.0f ms · sorted page %.2f ms",
                     opened * 1000, jump * 1000, sequential * 1000, sortTime * 1000, sortedPage * 1000))
        XCTAssertLessThan(jump, 0.5)
        XCTAssertLessThan(sequential, 0.02)
        XCTAssertLessThan(sortedPage, 0.05)
    }

    /// Scrolling a real table view over a million rows: every frame fetches and lays out rows.
    @MainActor
    func testMillionRowsScrollSmoothly() throws {
        let url = try millionRowDatabase()
        let database = try SQLiteDatabase(url: url)
        let orders = try XCTUnwrap(database.objects.first { $0.name == "orders" })
        let source = SQLiteGridSource(database: database, worker: SQLiteWorker(url: url), object: orders)
        let grid = GridView(source: source, showsRowNumbers: true, stripHeight: 16)
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 1000, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = grid
        window.orderFrontRegardless()
        window.layoutIfNeeded()
        window.displayIfNeeded()
        // Let the background rowid index arrive, as it would while the preview is on screen.
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        let clip = grid.scrollView.contentView

        // Scrolling: each frame moves the clip view and lays out (row views for the rows that come
        // into view, their data fetched page by page). Drawing is measured separately below,
        // because the test process doesn't composite layers.
        func layout(atRow row: Int) {
            clip.scroll(to: NSPoint(x: 0, y: CGFloat(row) * grid.tableView.rowHeight))
            grid.scrollView.reflectScrolledClipView(clip)
            grid.layoutSubtreeIfNeeded()
            let visible = grid.tableView.rows(in: grid.tableView.visibleRect)
            for index in visible.lowerBound..<visible.upperBound {
                _ = grid.tableView.rowView(atRow: index, makeIfNecessary: true)
            }
            // The data for the rows now in view (a page fetch whenever a page boundary is crossed).
            _ = source.value(row: visible.lowerBound, column: 0)
            _ = source.value(row: max(visible.upperBound - 1, 0), column: 0)
        }
        // A fast fling: 30 new rows every frame, 600 frames.
        var started = CFAbsoluteTimeGetCurrent()
        var worst = 0.0
        for frame in 0..<600 {
            let begin = CFAbsoluteTimeGetCurrent()
            layout(atRow: frame * 30)
            worst = max(worst, CFAbsoluteTimeGetCurrent() - begin)
        }
        let fling = (CFAbsoluteTimeGetCurrent() - started) / 600
        // Dragging the scroller: jumps anywhere in the table (pages found through the rowid index).
        started = CFAbsoluteTimeGetCurrent()
        for jump in 0..<100 { layout(atRow: (jump * 9_973) % 999_000) }
        let jumps = (CFAbsoluteTimeGetCurrent() - started) / 100

        // Drawing: one row's cells into a 2x bitmap, as its layer would.
        let row = try XCTUnwrap(grid.tableView.rowView(atRow: grid.tableView.rows(in: grid.tableView.visibleRect).location, makeIfNecessary: true) as? GridRowView)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(row.bounds.width * 2), pixelsHigh: Int(row.bounds.height * 2),
                                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        context.cgContext.scaleBy(x: 2, y: 2)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        started = CFAbsoluteTimeGetCurrent()
        for index in 0..<2_000 {
            row.row = 400_000 + index
            row.draw(row.bounds)
        }
        let perRow = (CFAbsoluteTimeGetCurrent() - started) / 2_000
        NSGraphicsContext.restoreGraphicsState()
        window.orderOut(nil)

        let frame = fling + 30 * perRow
        print(String(format: "SQLite 1M rows scrolling: layout %.2f ms a frame (worst %.1f ms) · draw %.3f ms a row · fling frame ≈ %.1f ms · scroller jump %.2f ms",
                     fling * 1000, worst * 1000, perRow * 1000, frame * 1000, jumps * 1000))
        XCTAssertLessThan(frame, 1.0 / 60, "a 30-row fling frame fits in a 60 Hz frame")
        XCTAssertLessThan(jumps, 0.05)
    }

    func testHostileNamesAreQuotedNotExecuted() throws {
        let url = try temporaryFolder().appendingPathComponent("hostile.sqlite")
        let builder = try DatabaseBuilder(url)
        builder.exec(#"CREATE TABLE "x""; DROP TABLE keep; --" ("a""b" TEXT, "rowid" INTEGER, "_rowid_" INTEGER, "oid" INTEGER)"#)
        builder.exec(#"INSERT INTO "x""; DROP TABLE keep; --" VALUES ('one', 1, 2, 3), ('two', 4, 5, 6)"#)
        builder.exec("CREATE TABLE keep (id INTEGER PRIMARY KEY)")
        builder.close()

        let database = try SQLiteDatabase(url: url)
        let hostile = try XCTUnwrap(database.objects.first { $0.name.hasPrefix("x\"") })
        XCTAssertEqual(hostile.rowCount, 2)
        XCTAssertNil(hostile.rowidAlias, "every rowid alias is shadowed by a real column")
        XCTAssertEqual(hostile.columns.map(\.name), ["a\"b", "rowid", "_rowid_", "oid"])
        let source = SQLiteGridSource(database: database, worker: SQLiteWorker(url: url), object: hostile)
        XCTAssertEqual(source.value(row: 1, column: 0).plainText, "two")
        let sorted = expectation(description: "sorted")
        source.sort(column: 0, ascending: false) { _ in sorted.fulfill() }
        wait(for: [sorted], timeout: 5)
        XCTAssertEqual(source.value(row: 0, column: 0).plainText, "two")
        XCTAssertNotNil(database.objects.first { $0.name == "keep" }, "the other table survives")
    }

    func testRunawayViewHitsItsDeadline() throws {
        let url = try temporaryFolder().appendingPathComponent("runaway.sqlite")
        let builder = try DatabaseBuilder(url)
        builder.exec("CREATE TABLE t (x INTEGER)")
        builder.exec("CREATE VIEW forever AS WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n) SELECT i FROM n ORDER BY i DESC")
        builder.close()
        let started = CFAbsoluteTimeGetCurrent()
        let database = try SQLiteDatabase(url: url)
        let view = try XCTUnwrap(database.objects.first { $0.name == "forever" })
        let source = SQLiteGridSource(database: database, worker: SQLiteWorker(url: url), object: view)
        _ = source.value(row: 0, column: 0)
        XCTAssertTrue(source.failed)
        XCTAssertLessThan(CFAbsoluteTimeGetCurrent() - started, 6, "count and first page both stop at their deadlines")
    }

    func testCorruptDatabaseFailsCleanly() throws {
        let url = try temporaryFolder().appendingPathComponent("corrupt.sqlite")
        var bytes = Array("SQLite format 3\0".utf8) + [UInt8](repeating: 0xFF, count: 4096)
        bytes[16] = 0x10; bytes[17] = 0x00
        try Data(bytes).write(to: url)
        XCTAssertThrowsError(try SQLiteDatabase(url: url))
    }

    func testBlobsAreDescribed() {
        XCTAssertEqual(SQLiteDatabase.blobKind([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A]), "PNG image")
        XCTAssertEqual(SQLiteDatabase.blobKind(Array("bplist00".utf8)), "Property list")
        XCTAssertNil(SQLiteDatabase.blobKind([1, 2, 3]))
    }

    func testSQLFormatterEvensIndentation() {
        let sql = "CREATE TABLE t (\n            a INTEGER,\n            b TEXT\n        )"
        XCTAssertEqual(SQLFormatter.format(sql), "CREATE TABLE t (\n    a INTEGER,\n    b TEXT\n)")
        let long = "CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT NOT NULL, note TEXT DEFAULT 'a, b', price REAL CHECK (price > 0))"
        XCTAssertEqual(SQLFormatter.format(long).components(separatedBy: "\n").count, 6)
    }
}

final class TableDataTests: XCTestCase {

    func testNaturalOrder() {
        func less(_ a: String, _ b: String) -> Bool {
            let direct = NaturalOrder.compare(Array(a.utf8), Array(b.utf8)) < 0
            XCTAssertEqual(direct, NaturalOrder.compareKeys(NaturalOrder.key(a), NaturalOrder.key(b)) < 0, "\(a) vs \(b)")
            return direct
        }
        XCTAssertTrue(less("file9", "file10"))
        XCTAssertTrue(less("File2", "file10"))
        XCTAssertTrue(less("a", "B"))
        XCTAssertTrue(less("v1.2", "v1.10"))
        XCTAssertTrue(less("007", "8"))
        XCTAssertFalse(less("b", "a"))
    }

    func testNumbersAndDates() {
        XCTAssertEqual(DataValueParser.number("1,234.5"), 1234.5)
        XCTAssertEqual(DataValueParser.number("-$40"), -40)
        XCTAssertEqual(DataValueParser.number("€12"), 12)
        XCTAssertEqual(DataValueParser.number("12%"), 12)
        XCTAssertEqual(DataValueParser.number("1e3"), 1000)
        XCTAssertEqual(DataValueParser.number("1_000"), 1000)
        XCTAssertNil(DataValueParser.number("12,34"))
        XCTAssertNil(DataValueParser.number("1.2.3"))
        XCTAssertNil(DataValueParser.number("Naxos"))
        XCTAssertNil(DataValueParser.number(String(repeating: "9", count: 5000)))
        XCTAssertEqual(DataValueParser.date("1970-01-02"), 86_400)
        XCTAssertEqual(DataValueParser.date("1970-01-01T01:00:00Z"), 3_600)
        XCTAssertEqual(DataValueParser.date("1970-01-01T02:00:00+01:00"), 3_600)
        XCTAssertEqual(DataValueParser.date("01/02/1970"), 86_400, "month first")
        XCTAssertEqual(DataValueParser.date("02.01.1970"), 86_400, "day first")
        XCTAssertEqual(DataValueParser.date("13/01/1970"), 12 * 86_400, "day first when the month can't be")
        XCTAssertNil(DataValueParser.date("2024-13-01"))
        XCTAssertNil(DataValueParser.date("20240101"))
        XCTAssertNil(DataValueParser.date("2024-01-01 junk"))
    }

    func testProfilesInferTypesAndCount() {
        let columns: [[String]] = [
            ["1", "2", "3", "", "5"],
            ["1.5", "2", "-3.25", "4", "5e2"],
            ["2024-01-01", "2024-02-01", "2024-03-01T10:00", "", "N/A"],
            ["yes", "no", "yes", "yes", ""],
            ["Naxos", "Paros", "Naxos", "Ios", "Naxos"],
            ["", "", "", "", ""],
        ]
        let profiles = columns.map { values in ColumnProfile.make(rows: values.count) { values[$0] } }
        XCTAssertEqual(profiles.map(\.kind), [.integer, .number, .date, .boolean, .text, .empty])
        XCTAssertEqual(profiles[0].empty, 1)
        XCTAssertEqual(profiles[0].minimum, 1)
        XCTAssertEqual(profiles[0].maximum, 5)
        XCTAssertEqual(profiles[0].mean, 2.75)
        XCTAssertEqual(profiles[2].empty, 2, "N/A counts as empty")
        XCTAssertTrue(profiles[2].hasTime)
        XCTAssertEqual(profiles[3].trueCount, 3)
        XCTAssertEqual(profiles[4].distinct, 3)
        XCTAssertEqual(profiles[4].top.first?.value, "Naxos")
        XCTAssertEqual(profiles[4].top.first?.count, 3)
        XCTAssertEqual(profiles[1].histogram.reduce(0, +), 5)
    }

    func testSortsNumbersNumericallyAndEmptiesLast() {
        let table = DelimitedTable.parse("name\tsize\nb\t10\na\t9\nc\t\nd\t100\n", separator: UInt8(ascii: "\t"))
        let source = RecordGridSource(store: DelimitedStore(table: table))
        source.sort(column: 1, ascending: true) { _ in }
        XCTAssertEqual((0..<4).map { source.value(row: $0, column: 0).plainText }, ["a", "b", "d", "c"])
        source.sort(column: 1, ascending: false) { _ in }
        XCTAssertEqual((0..<4).map { source.value(row: $0, column: 0).plainText }, ["d", "b", "a", "c"])
        source.sort(column: 0, ascending: false) { _ in }
        XCTAssertEqual((0..<4).map { source.value(row: $0, column: 0).plainText }, ["d", "c", "b", "a"])
    }

    func testFilterMatchesAnyColumnIgnoringCase() {
        let table = DelimitedTable.parse("island|group\nNaxos|Cyclades\nCorfu|Ionian\nIthaca|Ionian\n", separator: UInt8(ascii: "|"))
        let source = RecordGridSource(store: DelimitedStore(table: table))
        let done = expectation(description: "filtered")
        source.setFilter("IONIAN") { done.fulfill() }
        wait(for: [done], timeout: 2)
        XCTAssertEqual(source.rowCount, 2)
        XCTAssertEqual(source.value(row: 0, column: 0).plainText, "Corfu")
    }

    func testHundredThousandRowsParseSortAndProfileQuickly() {
        var text = "id\tcity\tamount\twhen\n"
        let cities = ["Athens", "Naxos", "Paros", "Syros", "Milos", "Ios", "Kea", "Andros"]
        for i in 0..<120_000 {
            text += "\(i)\t\(cities[i % cities.count])\t\((i * 7919) % 100_000 / 10)\t2025-\(String(format: "%02d", i % 12 + 1))-\(String(format: "%02d", i % 28 + 1))\n"
        }
        var started = CFAbsoluteTimeGetCurrent()
        let table = DelimitedTable.parse(text, separator: UInt8(ascii: "\t"), maxRows: 200_000)
        let parse = CFAbsoluteTimeGetCurrent() - started
        XCTAssertEqual(table.rows.count, 120_000)
        let source = RecordGridSource(store: DelimitedStore(table: table))
        started = CFAbsoluteTimeGetCurrent()
        source.sort(column: 2, ascending: true) { _ in }
        let numeric = CFAbsoluteTimeGetCurrent() - started
        started = CFAbsoluteTimeGetCurrent()
        source.sort(column: 1, ascending: true) { _ in }
        let text_ = CFAbsoluteTimeGetCurrent() - started
        XCTAssertEqual(source.value(row: 0, column: 1).plainText, "Andros")
        started = CFAbsoluteTimeGetCurrent()
        let profile = ColumnProfile.make(rows: table.rows.count) { table.rows[$0][3] }
        let profiling = CFAbsoluteTimeGetCurrent() - started
        XCTAssertEqual(profile.kind, .date)
        print(String(format: "TSV 120k rows: parse %.0f ms · numeric sort %.0f ms · text sort %.0f ms · profile one column %.0f ms",
                     parse * 1000, numeric * 1000, text_ * 1000, profiling * 1000))
        // Generous for unoptimised test builds; release builds are several times faster.
        XCTAssertLessThan(numeric, 1.0)
        XCTAssertLessThan(text_, 1.0)
    }

    func testWideTablesProfileWithinBudget() {
        let header = (0..<1000).map { "c\($0)" }.joined(separator: ",")
        let row = (0..<1000).map(String.init).joined(separator: ",")
        let table = DelimitedTable.parse(header + "\n" + Array(repeating: row, count: 500).joined(separator: "\n"))
        XCTAssertEqual(table.columnCount, 1000)
        let started = CFAbsoluteTimeGetCurrent()
        for column in 0..<1000 { _ = ColumnProfile.make(rows: table.rows.count, limit: 4_000) { table.rows[$0][column] } }
        XCTAssertLessThan(CFAbsoluteTimeGetCurrent() - started, 3)
    }
}

final class FormatDataTests: XCTestCase {

    private func info(_ path: String) -> FileInfo { FileInfo(url: fixtures.appendingPathComponent(path)) }

    // MARK: Detection

    func testDetection() throws {
        XCTAssertEqual(DataModule.kind(of: info("events.jsonl")), .jsonLines)
        XCTAssertEqual(DataModule.kind(of: info("ferries.har")), .har)
        XCTAssertEqual(DataModule.kind(of: info("dbf/foxpro/fleet.dbf")), .dbf)
        XCTAssertEqual(DataModule.kind(of: info("parquet/plain.parquet")), .parquet)
        XCTAssertEqual(DataModule.kind(of: info("strings/Localizable.xcstrings")), .stringCatalog)
        XCTAssertEqual(DataModule.kind(of: info("strings/Resources/en.lproj/Localizable.strings")), .strings)
        XCTAssertEqual(DataModule.kind(of: info("strings/Resources/en.lproj/Localizable.stringsdict")), .stringsdict)
        XCTAssertEqual(DataModule.kind(of: info("lock/cargo/Cargo.lock")), .lockFile(.cargo))
        XCTAssertEqual(DataModule.kind(of: info("lock/swiftpm/Package.resolved")), .lockFile(.swiftpm))
        XCTAssertNil(DataModule.kind(of: info("islands.tsv")), "delimited text stays with Greece's own table")
        XCTAssertNil(DataModule.kind(of: info("harbour.sqlite")), "SQLite stays with Greece's own browser")
        XCTAssertEqual(FileKind.detect(fixtures.appendingPathComponent("events.jsonl")), .module("data"))

        // GeoJSON features in JSON Lines are left for the map preview; random .dbf and .json aren't claimed.
        let folder = try temporaryFolder()
        let geo = folder.appendingPathComponent("places.jsonl")
        try Data(#"{"type": "Feature", "geometry": {"type": "Point", "coordinates": [1, 2]}}"#.utf8).write(to: geo)
        XCTAssertNil(DataModule.kind(of: FileInfo(url: geo)))
        let notDBF = folder.appendingPathComponent("notes.dbf")
        try Data("just some text that is long enough to be a header".utf8).write(to: notDBF)
        XCTAssertNil(DataModule.kind(of: FileInfo(url: notDBF)))
        let plainJSON = folder.appendingPathComponent("data.json")
        try Data(#"{"log": "not a capture"}"#.utf8).write(to: plainJSON)
        XCTAssertNil(DataModule.kind(of: FileInfo(url: plainJSON)))
    }

    // MARK: JSON

    func testOrderedJSONKeepsKeyOrderAndRejectsBombs() throws {
        let value = try JSONReader.parse(Data(#"{"z": 1, "a": [true, null, "xé\n"], "m": {"k": -1.5e3}}"#.utf8))
        guard case .object(let pairs) = value else { return XCTFail("not an object") }
        XCTAssertEqual(pairs.map(\.0), ["z", "a", "m"])
        XCTAssertEqual(value["a"], .array([.bool(true), .null, .string("xé\n")]))
        XCTAssertEqual(value["m"]?["k"], .number("-1.5e3"))
        XCTAssertEqual(try JSONReader.parse(Data(#""😀""#.utf8)), .string("😀"))
        let deep = String(repeating: "[", count: 100_000) + String(repeating: "]", count: 100_000)
        XCTAssertThrowsError(try JSONReader.parse(Data(deep.utf8)))
        for bad in ["{", "[1,]", "{\"a\" 1}", "tru", "\"unterminated", "{} trailing", "-"] {
            XCTAssertThrowsError(try JSONReader.parse(Data(bad.utf8)), bad)
        }
    }

    func testJSONLinesUnionsKeysInOrder() throws {
        let lines = try XCTUnwrap(try JSONLinesTable.load(fixtures.appendingPathComponent("events.jsonl"), maxRows: 1000))
        XCTAssertEqual(lines.table.rowCount, 60)
        XCTAssertEqual(lines.invalid, 1)
        XCTAssertEqual(Array(lines.table.columns.map(\.title).prefix(7)), ["id", "event", "port", "at", "passengers", "on_time", "vessel"])
        XCTAssertTrue(lines.table.columns.map(\.title).contains("delay_minutes"))
        XCTAssertTrue(lines.table.columns[0].numeric)
        XCTAssertEqual(lines.table.value(row: 0, column: 6), .secondary(#"{"name": "Aegean 1", "imo": 9000000}"#))
        let delay = try XCTUnwrap(lines.table.columns.firstIndex { $0.title == "delay_minutes" })
        XCTAssertEqual(lines.table.value(row: 1, column: delay), .placeholder(""), "missing keys are empty")
        XCTAssertNil(try JSONLinesTable.load(fixtures.appendingPathComponent("matrix.ndjson"), maxRows: 1000), "arrays read better as code")
    }

    func testJSONLinesCapsColumnsAndRows() {
        let wide = "{" + (0..<5000).map { "\"k\($0)\": \($0)" }.joined(separator: ",") + "}\n"
        let table = JSONLinesTable.parse(wide + wide, maxRows: 1)
        XCTAssertEqual(table?.table.columns.count, JSONLinesTable.maxColumns)
        XCTAssertEqual(table?.skippedColumns, 5000 - JSONLinesTable.maxColumns)
        XCTAssertEqual(table?.table.rowCount, 1)
        XCTAssertEqual(table?.lines, 2)
        XCTAssertEqual(table?.truncated, true)
    }

    // MARK: Lock files

    private func lock(_ path: String) throws -> LockFile {
        try XCTUnwrap(try LockFile.load(fixtures.appendingPathComponent(path)), path)
    }

    private func kinds(_ lock: LockFile) -> [String: LockedPackage.Kind] {
        Dictionary(lock.packages.map { ($0.name, $0.kind) }) { a, _ in a }
    }

    func testEveryLockFormat() throws {
        let npm = try lock("lock/npm/package-lock.json")
        XCTAssertEqual(npm.packages.count, 9)
        XCTAssertEqual(kinds(npm)["react"], .direct)
        XCTAssertEqual(kinds(npm)["vite"], .directDev)
        XCTAssertEqual(kinds(npm)["esbuild"], .dev)
        XCTAssertEqual(kinds(npm)["scheduler"], .transitive)
        XCTAssertEqual(kinds(npm)["my-local"], .workspace)
        XCTAssertEqual(npm.packages.first { $0.name == "react" }?.source, "registry.npmjs.org")
        XCTAssertEqual(npm.detail, "Lockfile v3")

        let shrinkwrap = try lock("lock/npm-shrinkwrap/npm-shrinkwrap.json")
        XCTAssertEqual(Set(shrinkwrap.packages.map(\.name)), ["lodash", "mocha", "ms"])

        let yarn = try lock("lock/yarn/yarn.lock")
        XCTAssertEqual(kinds(yarn)["@babel/core"], .direct, "package.json beside the lock file says so")
        XCTAssertEqual(kinds(yarn)["jest"], .directDev)
        XCTAssertEqual(kinds(yarn)["@babel/code-frame"], .transitive)
        XCTAssertEqual(yarn.packages.first { $0.name == "lodash" }?.version, "4.17.21")
        XCTAssertEqual(yarn.packages.first { $0.name == "harbour-ui" }?.source, "git")

        let berry = try lock("lock/yarn-berry/yarn.lock")
        XCTAssertEqual(berry.packages.first { $0.name == "react" }?.version, "18.3.1")
        XCTAssertEqual(kinds(berry)["harbour"], .workspace)

        let pnpm = try lock("lock/pnpm/pnpm-lock.yaml")
        XCTAssertEqual(kinds(pnpm)["express"], .direct)
        XCTAssertEqual(kinds(pnpm)["typescript"], .directDev)
        XCTAssertEqual(kinds(pnpm)["accepts"], .transitive)
        XCTAssertEqual(pnpm.packages.first { $0.name == "typescript" }?.version, "5.6.3")

        let cargo = try lock("lock/cargo/Cargo.lock")
        XCTAssertEqual(kinds(cargo)["harbour"], .workspace)
        XCTAssertEqual(kinds(cargo)["serde"], .direct)
        XCTAssertEqual(kinds(cargo)["serde_derive"], .transitive)
        XCTAssertEqual(cargo.packages.first { $0.name == "serde" }?.source, "crates.io")
        XCTAssertEqual(cargo.packages.first { $0.name == "nautical" }?.source, "git")

        let gems = try lock("lock/bundler/Gemfile.lock")
        XCTAssertEqual(kinds(gems)["actionpack"], .direct)
        XCTAssertEqual(kinds(gems)["rack"], .transitive)
        XCTAssertEqual(gems.packages.first { $0.name == "tide" }?.source, "git")
        XCTAssertEqual(gems.packages.first { $0.name == "nokogiri" }?.version, "1.16.7-arm64-darwin")
        XCTAssertEqual(gems.detail, "Bundler 2.5.22")

        let poetry = try lock("lock/poetry/poetry.lock")
        XCTAssertEqual(kinds(poetry)["requests"], .direct)
        XCTAssertEqual(kinds(poetry)["pytest"], .directDev)
        XCTAssertEqual(kinds(poetry)["certifi"], .transitive)
        XCTAssertEqual(poetry.packages.first { $0.name == "harbour-tools" }?.source, "pypi.harbour.example")

        let uv = try lock("lock/uv/uv.lock")
        XCTAssertEqual(kinds(uv)["httpx"], .direct)
        XCTAssertEqual(kinds(uv)["ruff"], .directDev)
        XCTAssertEqual(kinds(uv)["anyio"], .transitive)
        XCTAssertEqual(kinds(uv)["harbour"], .workspace)

        let pods = try lock("lock/cocoapods/Podfile.lock")
        XCTAssertEqual(kinds(pods)["Alamofire"], .direct)
        XCTAssertEqual(kinds(pods)["FirebaseAnalytics"], .transitive)
        XCTAssertEqual(pods.packages.first { $0.name == "HarbourKit" }?.source, "local")
        XCTAssertEqual(pods.packages.first { $0.name == "Alamofire" }?.source, "CocoaPods trunk")

        let swiftpm = try lock("lock/swiftpm/Package.resolved")
        XCTAssertEqual(swiftpm.packages.map(\.name), ["harbourkit", "swift-argument-parser", "swift-collections"])
        XCTAssertEqual(swiftpm.packages.first?.version, "branch main")
        XCTAssertEqual(swiftpm.packages.last?.source, "github.com")

        let composer = try lock("lock/composer/composer.lock")
        XCTAssertEqual(kinds(composer)["monolog/monolog"], .direct)
        XCTAssertEqual(kinds(composer)["phpunit/phpunit"], .directDev)
        XCTAssertEqual(kinds(composer)["psr/log"], .transitive)
        XCTAssertEqual(kinds(composer)["sebastian/diff"], .dev)

        let go = try lock("lock/go/go.sum")
        XCTAssertEqual(go.packages.count, 4, "go.mod-only lines aren't modules")
        XCTAssertEqual(kinds(go)["github.com/spf13/cobra"], .direct)
        XCTAssertEqual(kinds(go)["golang.org/x/sync"], .transitive, "// indirect")

        let mix = try lock("lock/mix/mix.lock")
        XCTAssertEqual(mix.packages.first { $0.name == "jason" }?.version, "1.4.4")
        XCTAssertEqual(mix.packages.first { $0.name == "tide" }?.source, "git")

        let pub = try lock("lock/pub/pubspec.lock")
        XCTAssertEqual(kinds(pub)["http"], .direct)
        XCTAssertEqual(kinds(pub)["flutter_test"], .directDev)
        XCTAssertEqual(kinds(pub)["async"], .transitive)
        XCTAssertEqual(pub.packages.first { $0.name == "harbour_ui" }?.source, "local")

        let pipenv = try lock("lock/pipenv/Pipfile.lock")
        XCTAssertEqual(pipenv.packages.first { $0.name == "requests" }?.version, "2.32.3")
        XCTAssertEqual(kinds(pipenv)["pytest"], .dev)

        let bun = try lock("lock/bun/bun.lock")
        XCTAssertEqual(kinds(bun)["hono"], .direct)
        XCTAssertEqual(kinds(bun)["@types/bun"], .directDev)
        XCTAssertEqual(kinds(bun)["bun-types"], .transitive)

        let flake = try lock("lock/nix/flake.lock")
        XCTAssertEqual(kinds(flake)["nixpkgs"], .direct)
        XCTAssertEqual(kinds(flake)["systems"], .transitive)
        XCTAssertEqual(flake.packages.first { $0.name == "nixpkgs" }?.source, "github:NixOS/nixpkgs")

        let gradle = try lock("lock/gradle/gradle.lockfile")
        XCTAssertEqual(gradle.packages.count, 4)
        XCTAssertEqual(kinds(gradle)["org.junit.jupiter:junit-jupiter"], .dev)

        let nuget = try lock("lock/nuget/packages.lock.json")
        XCTAssertEqual(kinds(nuget)["Newtonsoft.Json"], .direct)
        XCTAssertEqual(kinds(nuget)["System.Diagnostics.DiagnosticSource"], .transitive)
    }

    func testMalformedLockFilesDontCrash() {
        for format in LockFile.Format.allCases {
            for garbage in ["", "{", "[[package]]\nname = ", "\u{0}\u{1}\u{2}", String(repeating: "  - x (\n", count: 1000), "packages:\n  /:\n    resolution: {"] {
                _ = LockFile.parse(Data(garbage.utf8), format: format)
            }
        }
        XCTAssertEqual(LockFile.pnpmKey("/@scope/name@1.2.3(react@18.0.0)").name, "@scope/name")
        XCTAssertEqual(LockFile.pnpmKey("/@scope/name@1.2.3(react@18.0.0)").version, "1.2.3")
        XCTAssertEqual(LockFile.pnpmKey("/lodash/4.17.21").version, "4.17.21")
        XCTAssertEqual(LockFile.packageName(fromSpec: "\"@babel/core@npm:^7.0.0\""), "@babel/core")
    }

    // MARK: Strings

    func testStringCatalogStates() throws {
        let data = try Data(contentsOf: fixtures.appendingPathComponent("strings/Localizable.xcstrings"))
        let catalog = try XCTUnwrap(StringTable.catalog(data))
        XCTAssertEqual(catalog.sourceLanguage, "en")
        XCTAssertEqual(catalog.languages.first, "en")
        XCTAssertEqual(Set(catalog.languages), ["en", "de", "el", "fr", "ja"])
        let book = try XCTUnwrap(catalog.rows.first { $0.key == "Book a cabin" })
        XCTAssertEqual(book.entries["fr"]?.state, .needsReview)
        XCTAssertEqual(book.comment, "Button on the sailing detail screen")
        XCTAssertEqual(catalog.rows.first { $0.key == "Aegean Ferries" }?.entries["de"]?.state, .notTranslated)
        XCTAssertEqual(catalog.rows.first { $0.key == "Cancelled" }?.entries["de"]?.state, .stale)
        let plural = try XCTUnwrap(catalog.rows.first { $0.key == "%lld passengers" })
        XCTAssertEqual(plural.entries["el"]?.state, .needsReview, "the worst state among variations")
        XCTAssertEqual(plural.entries["de"]?.value, "%lld Passagiere")
        let german = catalog.completion("de")
        XCTAssertEqual(german.done, 6)
        XCTAssertEqual(german.total, 7, "the untranslatable key doesn't count")
    }

    func testStringsJoinSiblingLanguagesAndKeepComments() throws {
        let table = try XCTUnwrap(try StringTable.strings(fixtures.appendingPathComponent("strings/Resources/en.lproj/Localizable.strings")))
        XCTAssertEqual(table.languages, ["en", "de", "el"])
        XCTAssertEqual(table.rows.map(\.key), ["timetable.title", "sailing.book", "sailing.departs", "weather.warning"])
        XCTAssertEqual(table.rows[3].entries["en"]?.value, "Gale warning in the \"Cyclades\"")
        XCTAssertEqual(table.rows[3].entries["el"]?.value, "Προειδοποίηση θυελλωδών ανέμων στις \"Κυκλάδες\"", "UTF-16 sibling")
        XCTAssertNil(table.rows[2].entries["el"])
        XCTAssertEqual(table.rows[1].comment, "Button on the sailing screen")
        let binary = try XCTUnwrap(try StringTable.strings(fixtures.appendingPathComponent("strings/binary/InfoPlist.strings")))
        XCTAssertEqual(binary.rows.map(\.key), ["CFBundleDisplayName", "NSLocationWhenInUseUsageDescription"])
        let rules = try XCTUnwrap(StringTable.stringsdict(try Data(contentsOf: fixtures.appendingPathComponent("strings/Resources/en.lproj/Localizable.stringsdict"))))
        XCTAssertEqual(rules.count, 2)
        XCTAssertEqual(rules.first { $0.key == "%d sailings" }?.forms["zero"], "No sailings")
        // Unterminated input ends cleanly.
        _ = StringTable.parseStrings(Data("\"unterminated = \"value".utf8))
        _ = StringTable.parseStrings(Data("/* never closed".utf8))
    }

    // MARK: DBF

    func testDBaseIIIWithMemosAndDeletedRows() throws {
        let table = try DBFTable.load(fixtures.appendingPathComponent("dbf/dbase3/ports.dbf"))
        XCTAssertEqual(table.versionName, "dBase III with memo")
        XCTAssertEqual(table.recordCount, 5)
        XCTAssertEqual(table.fields.map(\.name), ["NAME", "REGION", "LAT", "LON", "OPENED", "YEARROUND", "NOTES"])
        XCTAssertEqual(table.deleted, [1])
        XCTAssertEqual(table.rows[0][0], .text("Piraeus"))
        XCTAssertEqual(table.rows[0][2], .text("37.9425"))
        XCTAssertEqual(table.rows[0][4], .text("1835-05-01"))
        XCTAssertEqual(table.rows[0][5], .text("true"))
        XCTAssertEqual(table.rows[0][6], .text("Main port of Athens and the busiest passenger port in Europe."))
        XCTAssertEqual(table.rows[3][4], .null, "blank date")
        XCTAssertEqual(table.rows[1][6], .null, "no memo")
        XCTAssertEqual(table.memoFile, "ports.dbt")
    }

    func testDBaseIVMemos() throws {
        let table = try DBFTable.load(fixtures.appendingPathComponent("dbf/dbase4/harbours.dbf"))
        XCTAssertEqual(table.versionName, "dBase IV with memo")
        XCTAssertEqual(table.rows[4][2], .text("Overnight ferries to Piraeus."))
        XCTAssertEqual(table.encodingName, "Windows ANSI (1252)")
    }

    func testVisualFoxProTypesNullsAndCodePage() throws {
        let table = try DBFTable.load(fixtures.appendingPathComponent("dbf/foxpro/fleet.dbf"))
        XCTAssertEqual(table.versionName, "Visual FoxPro")
        XCTAssertEqual(table.encodingName, "Windows Greek (1253)")
        XCTAssertFalse(table.fields.filter { !$0.isSystem }.map(\.name).contains("_NullFlags"))
        XCTAssertEqual(table.rows[0][0], .text("1"))
        XCTAssertEqual(table.rows[0][4], .text("1250.5000"), "currency")
        XCTAssertEqual(table.rows[0][5], .text("2025-05-30 07:25:00"), "datetime")
        XCTAssertEqual(table.rows[0][6], .text("0.82"), "double")
        XCTAssertEqual(table.rows[0][7], .text("Λιμάνι Πειραιά"), "Greek from code page 1253")
        XCTAssertEqual(table.rows[0][8], .text("Flagship on the western Cyclades line."), "FoxPro memo")
        XCTAssertEqual(table.rows[1][7], .null, "null flag")
        XCTAssertEqual(table.rows[2][1], .text("Αιγαίο Πέλαγος"))
        XCTAssertEqual(table.rows[2][8], .text("Ρυμουλκό λιμένος."))
        XCTAssertEqual(table.deleted, [3])
    }

    func testMalformedDBFIsRefusedOrTruncatedSafely() throws {
        let original = try Data(contentsOf: fixtures.appendingPathComponent("dbf/dbase3/ports.dbf"))
        // Cut short while claiming a billion records: no crash, no huge allocation.
        var bytes = [UInt8](original.prefix(300))
        bytes[4] = 0xFF; bytes[5] = 0xFF; bytes[6] = 0xFF; bytes[7] = 0x3F
        let table = try DBFTable.parse(Data(bytes))
        XCTAssertLessThan(table.rows.count, 10)
        XCTAssertThrowsError(try DBFTable.parse(Data([0x03] + [UInt8](repeating: 0, count: 40))))
        var fieldsOnly = [UInt8](original.prefix(32))
        fieldsOnly[8] = 0xFF; fieldsOnly[9] = 0xFF
        XCTAssertThrowsError(try DBFTable.parse(Data(fieldsOnly)))
        // A memo block number pointing far past the end of the memo file.
        let memo = try XCTUnwrap(MemoFile.make(Data(count: 1024), name: "x.fpt", foxPro: true))
        if case .missing = memo.read(block: Int.max / 2) {} else { XCTFail("read past the end") }
    }

    // MARK: HAR

    func testHARWaterfallAndDetails() throws {
        let capture = try HARCapture.load(fixtures.appendingPathComponent("ferries.har"))
        let summary = capture.summary
        XCTAssertEqual(summary.entries.count, 33)
        XCTAssertEqual(summary.pages.first?.title, "Aegean Ferries — Timetable")
        XCTAssertNotNil(summary.pages.first?.load)
        XCTAssertEqual(summary.entries[0].status, 301)
        XCTAssertEqual(summary.entries[0].type, "document")
        XCTAssertEqual(summary.entries[0].start, 0)
        XCTAssertTrue(summary.entries.contains { $0.failed })
        XCTAssertTrue(summary.entries.contains { $0.status == 404 })
        XCTAssertEqual(summary.entries.first { $0.path.hasPrefix("/v2/sailings") }?.host, "api.ferries.example")
        let index = try XCTUnwrap(summary.entries.firstIndex { $0.method == "POST" })
        let detail = try XCTUnwrap(capture.detail(index))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: detail) as? [String: Any])
        XCTAssertEqual(json["method"] as? String, "POST")
        XCTAssertTrue((json["postText"] as? String)?.contains("BSD-0725") == true)
        XCTAssertNil(capture.detail(9999))
        XCTAssertThrowsError(try HARCapture.parse(Data("{\"log\": 5}".utf8)))
        XCTAssertThrowsError(try HARCapture.parse(Data("not json".utf8)))
    }

    func testHARPageKeepsCaptureTextOutOfMarkup() throws {
        // Hostile strings reach the page as JSON data, never as markup.
        let har = #"{"log": {"version": "1.2", "creator": {"name": "</script><script>alert(1)</script>"}, "entries": [{"startedDateTime": "2025-01-01T00:00:00Z", "time": 1, "request": {"method": "GET", "url": "https://x.example/<img src=x onerror=alert(1)>", "headers": []}, "response": {"status": 200, "content": {"mimeType": "text/html"}}, "timings": {}}]}}"#
        let url = try temporaryFolder().appendingPathComponent("hostile.har")
        try Data(har.utf8).write(to: url)
        guard case .web(let document, _, _) = try HARPage.prepare(FileInfo(url: url), modified: nil) else { return XCTFail("not a web page") }
        let html = document.html(settings: PreviewSettings())
        XCTAssertFalse(html.contains("</script><script>alert"))
        XCTAssertFalse(html.contains("<img src=x"))
    }

    // MARK: Parquet

    func testParquetSchemaAndRows() throws {
        for (name, codec) in [("plain", "Uncompressed"), ("sailings", "Snappy"), ("gzip", "Gzip")] {
            let url = fixtures.appendingPathComponent("parquet/\(name).parquet")
            let parquet = try ParquetFile.open(url)
            XCTAssertEqual(parquet.codecs, [codec], name)
            XCTAssertEqual(parquet.columns.first?.name, "sailing")
            XCTAssertEqual(parquet.columns.first?.kind, .string)
            XCTAssertTrue(parquet.nested.contains("stops.list.element"), name)
            let (values, reasons) = parquet.firstRows(url, limit: 50)
            let names = try XCTUnwrap(values[0], "\(name): \(reasons[0] ?? "")")
            XCTAssertEqual(names.first, .text("S0000"), name)
            XCTAssertEqual(names.count > 49 ? names[49] : nil, .text("S0049"), name)
            XCTAssertEqual(values[2]?.first, .text("2025-06-01 06:00:00"), name)
            XCTAssertEqual(values[3]?.first, .text("2025-06-01"), "\(name): date")
            XCTAssertEqual(values[5]?.first, .null, "\(name): a null in an optional column")
            XCTAssertNotNil(values[6]?.first?.plainText.firstMatch(of: #/^\d+\.\d\d$/#), "\(name): decimal(8,2)")
            XCTAssertNotNil(values[8]?.first, "\(name): boolean")
            XCTAssertNil(values[9], "\(name): nested lists aren't flattened")
        }
        let snappy = try ParquetFile.open(fixtures.appendingPathComponent("parquet/sailings.parquet"))
        XCTAssertEqual(snappy.rows, 400)
        XCTAssertEqual(snappy.groups.map(\.rows), [150, 150, 100])
        let zstd = fixtures.appendingPathComponent("parquet/zstd.parquet")
        let (values, reasons) = try ParquetFile.open(zstd).firstRows(zstd, limit: 10)
        XCTAssertNil(values[0])
        XCTAssertEqual(reasons[0], "Zstandard")
    }

    func testSnappyAndHostileParquet() throws {
        XCTAssertEqual(try Snappy.decompress(Data([5, 0x10, 0x68, 0x65, 0x6C, 0x6C, 0x6F])), Data("hello".utf8))
        // A one-byte literal, then a copy of length 9 at offset 1 that overlaps itself: "aaaaaaaaaa".
        XCTAssertEqual(try Snappy.decompress(Data([10, 0x00, 0x61, 0x15, 0x01])), Data(repeating: 0x61, count: 10))
        XCTAssertThrowsError(try Snappy.decompress(Data([0xFF, 0xFF, 0xFF, 0xFF, 0x0F])), "huge declared length")
        XCTAssertThrowsError(try Snappy.decompress(Data([4, 0x09, 0x10])), "copy before any output")
        // Footers: absurd lengths, garbage, endless nesting.
        let folder = try temporaryFolder()
        let footers: [[UInt8]] = [
            Array("PAR1".utf8) + [0xFF, 0xFF, 0xFF, 0x7F] + Array("PAR1".utf8),
            Array("PAR1".utf8) + [0x15, 0x00, 0x19, 0xFC] + [0x04, 0x00, 0x00, 0x00] + Array("PAR1".utf8),
            Array("PAR1".utf8) + [UInt8](repeating: 0x1C, count: 4000) + [0xA0, 0x0F, 0x00, 0x00] + Array("PAR1".utf8),
        ]
        for (index, bytes) in footers.enumerated() {
            let url = folder.appendingPathComponent("bad\(index).parquet")
            try Data(bytes).write(to: url)
            XCTAssertThrowsError(try ParquetFile.open(url), "footer \(index)")
        }
        XCTAssertEqual(try Hybrid.decode(Data([0x08, 0x01])[...], bitWidth: 1, count: 4), [1, 1, 1, 1])
        XCTAssertEqual(ParquetFile.decimal("12345", negative: true, scale: 2), "-123.45")
        XCTAssertEqual(ParquetFile.bigEndianDecimalString([0x01, 0x00]), "256")
    }

    // MARK: Previews and thumbnails

    func testEveryFixturePreparesAndDrawsAThumbnail() throws {
        let files = try FileManager.default.subpathsOfDirectory(atPath: fixtures.path)
            .map { fixtures.appendingPathComponent($0) }
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == false }
            .filter { !["py", "md", "dbt", "fpt", "toml", "mod"].contains($0.pathExtension) && !["package.json", "composer.json"].contains($0.lastPathComponent) }
        XCTAssertGreaterThan(files.count, 30)
        for url in files {
            let info = FileInfo(url: url)
            if case .module = FileKind.detect(info), let module = PreviewModules.claiming(info) {
                XCTAssertNoThrow(try module.prepare(info, settings: PreviewSettings()), url.lastPathComponent)
            }
            let page = Thumbnailer.page(for: url, maximumSize: CGSize(width: 256, height: 256), settings: PreviewSettings())
            if DataModule.kind(of: info) != nil || ["sqlite", "tsv", "psv"].contains(url.pathExtension) {
                XCTAssertNotNil(page, "thumbnail for \(url.lastPathComponent)")
                if let page {
                    let image = NSImage(size: page.size, flipped: false) { _ in page.draw(); return true }
                    XCTAssertNotNil(image.tiffRepresentation)
                }
            }
        }
    }

    func testDataExtensionsReachGreece() throws {
        // Like CoverageTests: each extension must resolve to a content type Greece claims.
        func list(_ kind: String) throws -> Set<String> {
            var result = Set<String>()
            let folder = repo.appendingPathComponent("Types/\(kind)")
            for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) where name.hasSuffix(".txt") {
                for line in try String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8).split(separator: "\n") {
                    let type = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0].trimmingCharacters(in: .whitespaces)
                    if !type.isEmpty { result.insert(type) }
                }
            }
            return result
        }
        var declared: [String: String] = [:]
        let folder = repo.appendingPathComponent("Types/declarations")
        for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) where name.hasSuffix(".plist") {
            let declarations = try PropertyListSerialization.propertyList(from: Data(contentsOf: folder.appendingPathComponent(name)), format: nil) as? [[String: Any]] ?? []
            for declaration in declarations {
                guard let identifier = declaration["UTTypeIdentifier"] as? String, let tags = declaration["UTTypeTagSpecification"] as? [String: Any] else { continue }
                for ext in (tags["public.filename-extension"] as? [String]) ?? [] { declared[ext.lowercased()] = identifier }
            }
        }
        let previews = try list("preview"), thumbnails = try list("thumbnails")
        var missing: [String] = []
        for ext in ["dbf", "jsonl", "ndjson", "har", "xcstrings", "strings", "stringsdict", "parquet", "tsv", "psv", "sqlite", "db", "lock", "resolved", "sum", "lockfile"] {
            guard let type = declared[ext] ?? UTType(filenameExtension: ext).map(\.identifier) else { missing.append("\(ext): no type"); continue }
            if !previews.contains(type) { missing.append("\(ext) (\(type)): not previewed") }
            if !thumbnails.contains(type) { missing.append("\(ext) (\(type)): no thumbnail") }
        }
        XCTAssert(missing.isEmpty, missing.joined(separator: "\n"))
    }
}
