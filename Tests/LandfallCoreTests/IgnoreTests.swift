import XCTest
@testable import LandfallCore

/// Ignored folders are off-limits everywhere: not recorded, never a source or destination of a move,
/// not measured or cleaned, not organized.
final class IgnoreTests: XCTestCase {
    var s: Sandbox!

    override func setUpWithError() throws {
        s = try Sandbox()
        s.config.mode = .auto
    }

    func testNothingInsideIsRecordedOrMoved() throws {
        let kept = s.downloads.appendingPathComponent("Keepers")
        s.config.ignore = [kept.path]
        let e = try s.engine()
        let u = try s.write(kept, "Product Call.txt", tactiqHeader)
        e.scanNow()
        XCTAssertTrue(fileExists(u.path))
        XCTAssertTrue(e.ledger.search("Keepers").isEmpty, "the ignored folder itself isn't tracked")
        XCTAssertEqual(s.classify(u).action, .ignore)
    }

    func testExecuteRefusesIgnoredSourceAndDestination() throws {
        let e = try s.engine()
        let u = try s.write(s.downloads, "Product Call.txt", tactiqHeader)
        s.config.mode = .shadow
        let shadow = try s.engine()
        shadow.scanNow()
        let it = shadow.ledger.search("Product Call").first!
        // Destination inside an ignored folder: refused, file stays put.
        var c = shadow.config
        c.ignore = [s.lib("Meetings")]
        shadow.reload(c)
        XCTAssertThrowsError(try shadow.apply(it.id))
        XCTAssertTrue(fileExists(u.path))
        // Source inside an ignored folder: refused too.
        c.ignore = [s.downloads.path]
        e.reload(c)
        XCTAssertThrowsError(try e.execute(it.id, path: u.path, Decision(action: .trash, confidence: 1, rule: "t", reason: "t")))
        XCTAssertTrue(fileExists(u.path))
    }

    func testSpaceScanSkipsIgnoredFolders() throws {
        let dev = s.base.appendingPathComponent("Dev")
        try s.write(dev.appendingPathComponent("app/node_modules/pkg"), "index.js", String(repeating: "x", count: 4096))
        try s.write(dev.appendingPathComponent("keep/node_modules/pkg"), "index.js", String(repeating: "x", count: 4096))
        let all = Space.scan([dev]).map(\.path)
        XCTAssertEqual(all.count, 2)
        let some = Space.scan([dev], ignore: [dev.appendingPathComponent("keep").path]).map(\.path)
        XCTAssertEqual(some.count, 1)
        XCTAssertTrue(some[0].contains("/app/"))
        XCTAssertTrue(Space.scan([dev], ignore: [dev.path]).isEmpty, "ignoring the root ignores everything")
    }

    func testOrganizerSkipsIgnoredFilingFolders() throws {
        let i = s.config.roots.firstIndex { $0.name == "desktop" }!
        s.config.roots[i].filing = Filing(mode: .inPlace, layout: "{yyyy-mm-dd}")
        let e = try s.engine()
        try s.write(s.desktop, "Product Call.txt", tactiqHeader)
        e.scanNow()
        let cabinet = try XCTUnwrap(e.cabinets().first)
        XCTAssertEqual(e.organizerEntries().count, 1)
        var c = e.config
        c.ignore = [cabinet.path]
        e.reload(c)
        XCTAssertTrue(e.organizerEntries().isEmpty)
        XCTAssertTrue(e.tidyCabinets().isEmpty)
    }

    func testIgnoredFolderMatchesWholeNamesOnly() {
        var c = Config.standard
        c.ignore = ["/tmp/x/Dev"]
        XCTAssertNotNil(c.ignoredFolder(containing: "/tmp/x/Dev"))
        XCTAssertNotNil(c.ignoredFolder(containing: "/tmp/x/Dev/a/b.txt"))
        XCTAssertNil(c.ignoredFolder(containing: "/tmp/x/Development/a.txt"))
    }
}
