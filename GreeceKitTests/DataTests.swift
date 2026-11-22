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
