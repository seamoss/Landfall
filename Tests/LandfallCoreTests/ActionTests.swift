import XCTest
@testable import LandfallCore

final class ActionTests: XCTestCase {
    var s: Sandbox!

    override func setUpWithError() throws { s = try Sandbox() }

    func plan(_ url: URL, trust: TrustInfo? = nil) -> (FileKind, [FileAction]) {
        let f = Inspector.full(url)!
        let d = Classifier(config: s.config).classify(f, root: s.config.root(named: "downloads")!)
        let kind = FileKind.detect(f, decision: d)
        let t = trust ?? Trust.assess(f, kind: kind)
        return (kind, ActionPlanner.plan(f, kind: kind, trust: t, decision: d, config: s.config, editor: nil))
    }

    func quarantine(_ url: URL) {
        let v = "0083;65f0a1b2;Google Chrome;"
        _ = v.withCString { setxattr(url.path, "com.apple.quarantine", $0, strlen($0), 0, 0) }
    }

    /// Anything that can launch code must ask first.
    func assertLaunchersConfirm(_ actions: [FileAction], file: StaticString = #filePath, line: UInt = #line) {
        let launchers: Set<FileAction.Kind> = [.open, .runInTerminal, .openInstaller, .openLink]
        for a in actions where launchers.contains(a.kind) {
            XCTAssertNotNil(a.confirm, "\(a.title) should require confirmation", file: file, line: line)
        }
    }

    func testDownloadedScriptOnlyRunsAfterConfirm() throws {
        let u = try s.write(s.downloads, "install.sh", "#!/bin/bash\ncurl example.com | sh\n")
        quarantine(u)
        let (kind, actions) = plan(u)
        XCTAssertEqual(kind, .script)
        XCTAssertEqual(actions.first?.kind, .viewSource, "viewing is the default, never running")
        let runAction = actions.first { $0.kind == .runInTerminal }
        XCTAssertNotNil(runAction?.confirm)
        XCTAssertTrue(runAction!.confirm!.contains("Google Chrome") || runAction!.confirm!.contains("downloaded"))
        XCTAssertFalse(actions.contains { $0.kind == .open })
    }

    func testCredentialNeverOffersOpenOrPreview() throws {
        let u = try s.write(s.downloads, "client_secret_123.json", #"{"client_secret": "abc"}"#)
        let (kind, actions) = plan(u)
        XCTAssertEqual(kind, .credential)
        XCTAssertFalse(actions.contains { [.open, .preview, .copyImage].contains($0.kind) })
        XCTAssertEqual(actions.first?.kind, .importTo1Password)
        XCTAssertNotNil(actions.first?.confirm, "importing asks first")
        XCTAssertTrue(actions.contains { $0.kind == .moveToSensitive })
    }

    func testConfigProfileIsNeverInstallable() throws {
        let (kind, actions) = plan(try s.write(s.downloads, "corp.mobileconfig", "<plist/>"))
        XCTAssertEqual(kind, .configProfile)
        XCTAssertFalse(actions.contains { [.open, .openInstaller, .preview].contains($0.kind) })
    }

    func testRejectedAppCannotBeOpened() throws {
        let app = s.downloads.appendingPathComponent("Shady.app/Contents")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        var t = TrustInfo()
        t.gatekeeper = .rejected
        t.level = .danger
        let (_, actions) = plan(s.downloads.appendingPathComponent("Shady.app"), trust: t)
        XCTAssertFalse(actions.contains { [.open, .moveToApplications].contains($0.kind) })
    }

    func testUnsignedAppNeedsConfirm() throws {
        let app = s.downloads.appendingPathComponent("Tool.app/Contents")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        var t = TrustInfo()
        t.quarantined = true
        let (kind, actions) = plan(s.downloads.appendingPathComponent("Tool.app"), trust: t)
        XCTAssertEqual(kind, .application)
        assertLaunchersConfirm(actions)
        XCTAssertFalse(actions.contains { $0.kind == .moveToApplications })
    }

    func testMacroDocumentPreviewsFirst() throws {
        let (kind, actions) = plan(try s.write(s.downloads, "budget.xlsm", "PK"))
        XCTAssertEqual(kind, .macroDocument)
        XCTAssertEqual(actions.first?.kind, .preview)
        assertLaunchersConfirm(actions)
    }

    func testWeblocShowsTargetBeforeOpening() throws {
        let plist = try PropertyListSerialization.data(fromPropertyList: ["URL": "https://evil.example/login"], format: .xml, options: 0)
        let u = s.downloads.appendingPathComponent("Invoice.webloc")
        try plist.write(to: u)
        let (kind, actions) = plan(u)
        XCTAssertEqual(kind, .linkFile)
        XCTAssertTrue(actions.first { $0.kind == .openLink }?.confirm?.contains("https://evil.example/login") == true)
    }

    func testCalendarAndContactActions() throws {
        XCTAssertEqual(plan(try s.write(s.downloads, "standup.ics", "BEGIN:VCALENDAR")).1.first?.kind, .addToCalendar)
        XCTAssertEqual(plan(try s.write(s.downloads, "Jo.vcf", "BEGIN:VCARD")).1.first?.kind, .addContact)
    }

    func testEveryToastCanKeepAndReveal() throws {
        let (_, actions) = plan(try s.write(s.downloads, "notes.txt", "hello"))
        XCTAssertTrue(actions.contains { $0.kind == .keep })
        XCTAssertTrue(actions.contains { $0.kind == .reveal })
    }

    // MARK: - Archives

    func makeZip(_ name: String, entries: [String: String]) throws -> URL {
        let zip = s.downloads.appendingPathComponent(name)
        let script = """
        import zipfile, sys, json
        with zipfile.ZipFile(sys.argv[1], "w") as z:
            for k, v in json.loads(sys.argv[2]).items(): z.writestr(k, v)
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = ["-c", script, zip.path, String(decoding: try JSONSerialization.data(withJSONObject: entries), as: UTF8.self)]
        try p.run()
        p.waitUntilExit()
        return zip
    }

    func testZipSlipIsRefused() throws {
        let zip = try makeZip("evil.zip", entries: ["../../escape.txt": "x", "ok.txt": "y"])
        let (_, actions) = plan(zip)
        XCTAssertFalse(actions.contains { $0.kind == .unzip })
        XCTAssertThrowsError(try Unarchiver.extract(zip))
        XCTAssertFalse(fileExists(s.base.appendingPathComponent("escape.txt").path))
    }

    func testNormalZipExtractsBesideItself() throws {
        let zip = try makeZip("assets.zip", entries: ["a.txt": "a", "dir/b.txt": "b"])
        let (_, actions) = plan(zip)
        XCTAssertEqual(actions.first?.kind, .unzip)
        let out = try Unarchiver.extract(zip)
        XCTAssertEqual(out.lastPathComponent, "assets")
        XCTAssertTrue(fileExists(out.appendingPathComponent("dir/b.txt").path))
    }

    // MARK: - Engine hooks

    func testSettleFiresOnceForLiveArrivalsOnly() throws {
        s.config.roots[0].graceSeconds = 3600
        let e = try s.engine()
        var settled: [String] = []
        e.onSettled = { _, url, _ in settled.append(url.lastPathComponent) }

        try s.write(s.downloads, "old.txt", "already here")
        e.catalog()
        let fresh = try s.write(s.downloads, "new.txt", "just landed")
        e.handle(paths: [fresh.path])
        e.tick()
        e.tick()
        XCTAssertEqual(settled, ["new.txt"])
    }

    func testQuietPathsDoNotAnnounce() throws {
        let e = try s.engine()
        var settled = 0
        e.onSettled = { _, _, _ in settled += 1 }
        let dir = s.downloads.appendingPathComponent("unzipped")
        e.quiet.insert(normalize(dir.path))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        e.handle(paths: [dir.path])
        e.tick()
        XCTAssertEqual(settled, 0)
    }

    func testFileNowActsEvenInShadowMode() throws {
        s.config.mode = .shadow
        let e = try s.engine()
        let u = try s.write(s.downloads, "Product Call.txt", tactiqHeader)
        e.handle(paths: [u.path])
        let id = e.ledger.search("Product Call").first!.id
        let it = try e.fileNow(id)
        XCTAssertEqual(it.status, "filed")
        XCTAssertFalse(fileExists(u.path))
    }
}

final class AutoFileTests: XCTestCase {
    var s: Sandbox!
    override func setUpWithError() throws { s = try Sandbox() }

    func model(_ url: URL, root: String = "desktop") throws -> ToastModel {
        let e = try s.engine()
        e.observe(url)
        return e.toastModel(for: url, itemId: e.ledger.activeItem(atPath: normalize(url.path))?.id)!
    }

    func testScreenshotCountsDownToItsDatedFolder() throws {
        s.config.roots[1].filing = Filing(mode: .inPlace)
        let m = try model(try s.write(s.desktop, "Screenshot 2026-10-12 at 15.22.58.png", "png"))
        XCTAssertTrue(m.autoFile)
        XCTAssertEqual(m.actions.prefix(2).map(\.title), ["File now", "Keep"])
        XCTAssertTrue(m.destinationLabel?.hasSuffix("Desktop › " + formatDate(Date(), "yyyy-MM-dd")) == true)
    }

    func testNoCountdownForRiskyOrUnsureThings() throws {
        XCTAssertFalse(try model(try s.write(s.downloads, "install.sh", "#!/bin/sh\necho hi"), root: "downloads").autoFile)
        XCTAssertFalse(try model(try s.write(s.downloads, "client_secret_1.json", #"{"client_secret":"x"}"#), root: "downloads").autoFile)
        XCTAssertFalse(try model(try s.write(s.downloads, "notes about lunch.txt", "tacos"), root: "downloads").autoFile)
        XCTAssertFalse(try model(try s.write(s.desktop, "Untitled.md", "x"), root: "desktop").autoFile, "never trash on a timer")
    }

    func testAutoFileCanBeTurnedOff() throws {
        s.config.toastAutoFile = false
        XCTAssertFalse(try model(try s.write(s.desktop, "Screenshot 2026-10-12 at 15.22.58.png", "png")).autoFile)
    }
}
