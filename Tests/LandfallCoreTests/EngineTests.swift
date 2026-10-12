import XCTest
@testable import LandfallCore

final class EngineTests: XCTestCase {
    var s: Sandbox!

    override func setUpWithError() throws { s = try Sandbox() }

    func testShadowModeOnlyProposes() throws {
        s.config.mode = .shadow
        let e = try s.engine()
        let u = try s.write(s.downloads, "Product Call.txt", tactiqHeader)
        e.scanNow()
        XCTAssertTrue(fileExists(u.path), "shadow mode must not move anything")
        let it = e.ledger.search("Product Call").first!
        XCTAssertEqual(it.status, "proposed")
        XCTAssertEqual(it.decision?.rule, "transcript")
    }

    func testAutoModeFilesAndUndoRestores() throws {
        s.config.mode = .auto
        let e = try s.engine()
        let u = try s.write(s.downloads, "Product Call.txt", tactiqHeader)
        e.scanNow()
        let filed = s.lib("Meetings/Acme/2026-09/2026-09-21 Product Call.txt")
        XCTAssertFalse(fileExists(u.path))
        XCTAssertTrue(fileExists(filed))
        let it = e.ledger.search("Product Call").first!
        XCTAssertEqual(it.status, "filed")
        XCTAssertEqual(it.path, filed)

        let back = try e.undo(it.id)
        XCTAssertEqual(back, normalize(u.path))
        XCTAssertTrue(fileExists(u.path))
        XCTAssertEqual(e.ledger.item(it.id)?.status, "kept")
        // A kept item is left alone on the next scan.
        e.scanNow()
        XCTAssertTrue(fileExists(u.path))
    }

    func testLowConfidenceStaysProposedInAuto() throws {
        s.config.mode = .auto
        let e = try s.engine()
        let u = try s.write(s.desktop, "random.jpg", "jpeg")
        e.scanNow()
        XCTAssertTrue(fileExists(u.path))
        XCTAssertEqual(e.ledger.search("random.jpg").first?.status, "proposed")
    }

    func testApplyCarriesOutProposal() throws {
        s.config.mode = .review
        let e = try s.engine()
        try s.write(s.desktop, "Screenshot 2026-10-05 at 22.43.48.png", "png")
        e.scanNow()
        let it = e.ledger.search("Screenshot").first!
        XCTAssertEqual(it.status, "proposed")
        let done = try e.apply(it.id)
        XCTAssertEqual(done.status, "filed")
        XCTAssertTrue(fileExists(done.path))
    }

    func testDuplicateOfFiledItemIsTrashed() throws {
        s.config.mode = .auto
        let e = try s.engine()
        try s.write(s.downloads, "Product Call.txt", tactiqHeader)
        e.scanNow()
        let again = try s.write(s.desktop, "Product Call copy.txt", tactiqHeader)
        e.scanNow()
        XCTAssertFalse(fileExists(again.path))
        XCTAssertEqual(e.ledger.search("Product Call copy").first?.status, "trashed")
    }

    func testMoveBetweenRootsKeepsOneItem() throws {
        s.config.mode = .shadow
        let e = try s.engine()
        let u = try s.write(s.downloads, "plan.txt", "hello")
        e.observe(u)
        let id = e.ledger.search("plan.txt").first!.id
        let moved = s.desktop.appendingPathComponent("plan.txt")
        try FileManager.default.moveItem(at: u, to: moved)
        e.handle(paths: [u.path, moved.path])
        let items = e.ledger.search("plan.txt")
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.id, id)
        XCTAssertEqual(items.first?.root, "desktop")
        XCTAssertTrue(e.ledger.events(for: id).contains { $0.type == "relocated" })
    }

    func testGracePeriodDelaysProcessing() throws {
        s.config.mode = .auto
        s.config.roots[1].graceSeconds = 3600
        let e = try s.engine()
        let u = try s.write(s.desktop, "Screenshot 2026-10-05 at 22.43.48.png", "png")
        e.observe(u)
        e.tick()
        XCTAssertTrue(fileExists(u.path), "still inside its grace period")
        e.clock = { Date().addingTimeInterval(7200) }
        e.tick()
        XCTAssertFalse(fileExists(u.path))
    }

    func testReconcileRecordsCorrection() throws {
        s.config.mode = .auto
        let e = try s.engine()
        try s.write(s.downloads, "Product Call.txt", tactiqHeader)
        e.scanNow()
        let it = e.ledger.search("Product Call").first!
        let elsewhere = s.library.appendingPathComponent("Clients/Acme/Product Call.txt")
        try FileManager.default.createDirectory(at: elsewhere.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: URL(fileURLWithPath: it.path), to: elsewhere)
        e.reconcile()
        XCTAssertEqual(e.ledger.item(it.id)?.path, normalize(elsewhere.path))
        XCTAssertTrue(e.ledger.events(for: it.id).contains { $0.type == "corrected" })
    }
}
