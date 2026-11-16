import XCTest
@testable import LandfallCore

final class OrganizerTests: XCTestCase {
    var s: Sandbox!

    override func setUpWithError() throws {
        s = try Sandbox()
        s.config.mode = .auto
        // The Desktop files into dated folders on itself, as installed.
        let i = s.config.roots.firstIndex { $0.name == "desktop" }!
        s.config.roots[i].filing = Filing(mode: .inPlace, layout: "{yyyy-mm-dd}")
    }

    /// File a transcript onto the Desktop the usual way: into a dated folder there.
    private func shelved(_ e: Engine) throws -> (url: URL, cabinet: URL) {
        try s.write(s.desktop, "Product Call.txt", tactiqHeader)
        e.scanNow()
        let it = e.ledger.search("Product Call").first!
        XCTAssertEqual(it.status, "filed")
        let url = URL(fileURLWithPath: it.path)
        let cabinet = url.deletingLastPathComponent()
        XCTAssertEqual(cabinet.deletingLastPathComponent().path, s.desktop.path, "filed into a dated Desktop folder")
        return (url, cabinet)
    }

    func testSuggestsTheLibraryHomeAndFilesItThere() throws {
        let e = try s.engine()
        let (url, cabinet) = try shelved(e)
        XCTAssertEqual(e.cabinets().map(\.path), [cabinet.path])

        let entries = e.organizerEntries()
        XCTAssertEqual(entries.count, 1)
        let entry = entries[0]
        XCTAssertEqual(entry.cabinet, cabinet.lastPathComponent)
        XCTAssertEqual(entry.suggestion, .file(s.lib("Meetings/Acme/2026-09")))

        let done = try XCTUnwrap(e.organize(entry, entry.suggestion))
        XCTAssertEqual(done.status, "filed")
        XCTAssertTrue(done.path.hasPrefix(s.library.path + "/Meetings/Acme/"))
        XCTAssertFalse(fileExists(url.path))

        // The emptied dated folder goes; undo brings the file back into a re-marked one.
        XCTAssertEqual(e.tidyCabinets(), [cabinet.lastPathComponent])
        XCTAssertFalse(fileExists(cabinet.path))
        _ = try e.undo(done.id)
        XCTAssertTrue(fileExists(url.path))
        XCTAssertEqual(e.cabinets().map(\.path), [cabinet.path])
    }

    func testUntrackedFileCanBeTrashedAndLeaveDoesNothing() throws {
        let e = try s.engine()
        let (_, cabinet) = try shelved(e)
        let stray = try s.write(cabinet, "notes.xyz", "scratch")

        let entry = try XCTUnwrap(e.organizerEntries().first { $0.name == "notes.xyz" })
        XCTAssertNil(entry.itemId)
        XCTAssertEqual(entry.suggestion, .leave)

        XCTAssertNil(try e.organize(entry, .leave))
        XCTAssertTrue(fileExists(stray.path))

        let trashed = try XCTUnwrap(e.organize(entry, .trash))
        XCTAssertEqual(trashed.status, "trashed")
        XCTAssertFalse(fileExists(stray.path))
        XCTAssertEqual(e.ledger.item(trashed.id)?.decision?.rule, "organizer")
        _ = try e.undo(trashed.id)
        XCTAssertTrue(fileExists(stray.path))
    }

    func testFoldersOutsideFilingFoldersAreNotTouched() throws {
        let e = try s.engine()
        try s.write(s.desktop.appendingPathComponent("My Project"), "readme.md", "mine")
        _ = try shelved(e)
        XCTAssertFalse(e.organizerEntries().contains { $0.path.contains("/My Project/") })
    }
}
