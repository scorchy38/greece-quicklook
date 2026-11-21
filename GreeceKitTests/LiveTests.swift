import XCTest
@testable import GreeceKit

@MainActor
final class LiveTests: XCTestCase {
    private func temporaryFile(_ text: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("notes.md")
        try text.write(to: url, atomically: false, encoding: .utf8)
        return url
    }

    func testNoticesInPlaceWrites() throws {
        let url = try temporaryFile("one")
        let changed = expectation(description: "change")
        let watcher = FileWatcher(url: url) { changed.fulfill() }
        try "one two".write(to: url, atomically: false, encoding: .utf8)
        wait(for: [changed], timeout: 3)
        withExtendedLifetime(watcher) {}
    }

    func testFollowsAtomicSaves() throws {
        let url = try temporaryFile("one")
        let changed = expectation(description: "change")
        changed.assertForOverFulfill = false
        let watcher = FileWatcher(url: url) { changed.fulfill() }
        // What most editors do: write elsewhere, then rename over the original.
        try "replaced".write(to: url, atomically: true, encoding: .utf8)
        wait(for: [changed], timeout: 3)

        // And it keeps watching the new file.
        let again = expectation(description: "again")
        again.assertForOverFulfill = false
        let watcher2 = FileWatcher(url: url) { again.fulfill() }
        try "replaced twice".write(to: url, atomically: true, encoding: .utf8)
        wait(for: [again], timeout: 3)
        withExtendedLifetime((watcher, watcher2)) {}
    }

    func testIgnoresTouchesThatChangeNothing() throws {
        let url = try temporaryFile("same")
        let changed = expectation(description: "no change")
        changed.isInverted = true
        let watcher = FileWatcher(url: url) { changed.fulfill() }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        wait(for: [changed], timeout: 1)
        withExtendedLifetime(watcher) {}
    }

    func testRemembersScrollPositions() throws {
        let url = URL(fileURLWithPath: "/tmp/greece-test-\(UUID().uuidString).md")
        XCTAssertNil(PreviewMemory.scroll(for: url, mode: .session))
        PreviewMemory.remember(CGPoint(x: 0, y: 840), for: url, mode: .session)
        PreviewMemory.flush()
        XCTAssertEqual(PreviewMemory.scroll(for: url, mode: .session), CGPoint(x: 0, y: 840))
        XCTAssertEqual(PreviewMemory.scroll(for: url, mode: .always), CGPoint(x: 0, y: 840))
        XCTAssertNil(PreviewMemory.scroll(for: url, mode: .off))

        PreviewMemory.remember(CGPoint(x: 0, y: 12), for: url, mode: .off)
        PreviewMemory.flush()
        XCTAssertEqual(PreviewMemory.scroll(for: url, mode: .session), CGPoint(x: 0, y: 840), "Off never records")
    }

    func testOldSettingsGainTheNewDefaults() throws {
        let settings = try JSONDecoder().decode(PreviewSettings.self, from: Data(#"{"theme":"xcode"}"#.utf8))
        XCTAssertTrue(settings.liveUpdates)
        XCTAssertEqual(settings.rememberScroll, .session)
        XCTAssertEqual(settings.rememberWindowSize, .allFiles)
    }
}
