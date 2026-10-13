import XCTest
@testable import LandfallCore

final class FakeCalendar: MeetingProvider {
    var meetings: [Meeting]
    init(_ meetings: [Meeting]) { self.meetings = meetings }
    func meetings(around date: Date) -> [Meeting] { meetings }
}

final class FeatureTests: XCTestCase {
    var s: Sandbox!

    override func setUpWithError() throws { s = try Sandbox() }

    /// Write the raw timespec macOS keeps as "last opened".
    func setLastUsed(_ url: URL, daysAgo: Double) {
        var ts: (Int64, Int64) = (Int64(Date().addingTimeInterval(-daysAgo * 86400).timeIntervalSince1970), 0)
        _ = withUnsafeBytes(of: &ts) { setxattr(url.path, "com.apple.lastuseddate#PS", $0.baseAddress, 16, 0, 0) }
    }

    // MARK: Renaming

    func testRenamerFixesTyposAndCopySuffixes() throws {
        XCTAssertEqual(Renamer.suggest(Inspector.full(try s.write(s.downloads, "Another Resu,e.pdf", "x"))!), "Another Resume.pdf")
        XCTAssertEqual(Renamer.suggest(Inspector.full(try s.write(s.downloads, "Quarterly Report (2).pdf", "x"))!), "Quarterly Report.pdf")
        XCTAssertNil(Renamer.suggest(Inspector.full(try s.write(s.downloads, "Board deck.pdf", "x"))!))
    }

    func testHashNamedImageGetsADatedName() throws {
        let f = Inspector.full(try s.write(s.downloads, "c43336eb7f0805d52bf89ff40e752f13.jpg", "jpeg"))!
        XCTAssertTrue(Renamer.suggest(f)?.hasPrefix("Image ") == true)
    }

    // MARK: Calendar context

    func testTranscriptStartTimeIsParsed() {
        let t = Transcript.parse(tactiqHeader)!
        XCTAssertEqual(formatDate(t.date!, "HH:mm"), "11:00")
    }

    func testMeetingTitlePicksClient() throws {
        s.config.mode = .shadow
        let e = try s.engine()
        let cal = FakeCalendar([Meeting(title: "Globex weekly sync", attendees: [])])
        e.meetingProvider = cal
        let u = try s.write(s.downloads, "whiteboard notes.txt", "rough notes, no names here")
        e.scanNow()
        let it = e.ledger.search("whiteboard").first!
        XCTAssertEqual(it.decision?.destination, s.lib("Clients/Globex"))
        XCTAssertTrue(it.decision?.reason.contains("Globex weekly sync") == true)
        _ = u
    }

    func testAttendeeDomainPicksClient() throws {
        s.config.clients.append(ClientConfig(name: "Initech", domains: ["initech.example"]))
        let e = try s.engine()
        let cal = FakeCalendar([Meeting(title: "Intro", attendees: ["Sam Lee", "brian@initech.example"])])
        e.meetingProvider = cal
        try s.write(s.downloads, "proposal.txt", "draft")
        e.scanNow()
        XCTAssertEqual(e.ledger.search("proposal").first?.decision?.destination, s.lib("Clients/Initech"))
    }

    // MARK: Dev captures

    func testOlderLocalhostCaptureIsProposedForTrash() throws {
        let old = try s.write(s.downloads, "127.0.0.1_5174___foundation (1).png", "old")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-600)], ofItemAtPath: old.path)
        try s.write(s.downloads, "127.0.0.1_5174___foundation (2).png", "new")
        let d = s.classify(old)
        XCTAssertEqual(d.rule, "stale-capture")
        XCTAssertLessThan(d.confidence, s.config.trashThreshold, "never auto-trashed; you approve")
    }

    // MARK: Per-folder filing

    func testDesktopFilesInPlaceIntoDateFolders() throws {
        s.config.mode = .auto
        s.config.roots[1].filing = Filing(mode: .inPlace, layout: "{yyyy-mm-dd}")
        let e = try s.engine()
        let shot = try s.write(s.desktop, "Screenshot 2026-10-05 at 22.43.48.png", "png")
        let day = formatDate(Inspector.quick(shot)!.added ?? Date(), "yyyy-MM-dd")
        e.scanNow()
        let filed = s.desktop.appendingPathComponent("\(day)/Screenshot 2026-10-05 at 22.43.48.png").path
        XCTAssertTrue(fileExists(filed))
        // The date folder is Landfall's own cabinet: never treated as a new arrival.
        e.scanNow()
        XCTAssertTrue(fileExists(filed))
        XCTAssertNil(e.ledger.search(day).first { $0.path == normalize(s.desktop.appendingPathComponent(day).path) && $0.status != "ignored" })
    }

    func testDayThenTypeLayout() throws {
        s.config.roots[1].filing = Filing(mode: .inPlace, layout: "{yyyy-mm-dd}/{category}")
        let u = try s.write(s.desktop, "Screenshot 2026-10-05 at 22.43.48.png", "png")
        let d = s.classify(u, root: "desktop")
        XCTAssertTrue(d.destination!.hasPrefix(s.desktop.path + "/"))
        XCTAssertTrue(d.destination!.hasSuffix("/Screenshots"))
    }

    func testCredentialsLeaveInPlaceFolders() throws {
        s.config.roots[1].filing = Filing(mode: .inPlace)
        let d = s.classify(try s.write(s.desktop, "client_secret_9.json", #"{"client_secret":"x"}"#), root: "desktop")
        XCTAssertEqual(d.destination, s.lib("_Sensitive"))
    }

    func testLibraryFilingIsUnchanged() throws {
        let d = s.classify(try s.write(s.downloads, "Screenshot 2026-10-05 at 22.43.48.png", "png"))
        XCTAssertTrue(d.destination!.hasPrefix(s.lib("Screenshots")))
    }

    // MARK: Learning rules

    func testTwoCorrectionsProposeAParticipantRule() throws {
        let text = tactiqHeader.replacingOccurrences(of: "Alex Rivera, Jordan Patel, Pat Owner, Casey Morgan",
                                                     with: "Pat Owner, Riley Chen")
        let a = Inspector.full(try s.write(s.library, "Clients/Acme/Meetings/a.txt", text))!
        let b = Inspector.full(try s.write(s.library, "Clients/Acme/Meetings/b.txt", text.replacingOccurrences(of: "Product Call", with: "Risk review")))!
        let p = RuleLearner.propose(corrected: [a, b], folder: s.lib("Clients/Acme/Meetings"), config: s.config)
        XCTAssertEqual(p?.rule.participantsAny, ["Riley Chen"])
        XCTAssertEqual(p?.rule.to, "Clients/Acme/Meetings")
    }

    func testCommonOriginProposesDomainRule() throws {
        var a = Inspector.full(try s.write(s.library, "Personal/Vehicles/a.pdf", "x"))!
        var b = Inspector.full(try s.write(s.library, "Personal/Vehicles/b.pdf", "y"))!
        a.origins = ["https://www.kawasaki.com/manuals/1"]
        b.origins = ["https://www.kawasaki.com/manuals/2"]
        let p = RuleLearner.propose(corrected: [a, b], folder: s.lib("Personal/Vehicles"), config: s.config)
        XCTAssertNotNil(p?.rule.originRegex)
        XCTAssertTrue("https://www.kawasaki.com/x".matches(p!.rule.originRegex!))
    }

    func testAppendRuleKeepsTheRestOfTheConfig() throws {
        let url = s.base.appendingPathComponent("config.json")
        try Data(#"{"mode": "auto", "custom": 1}"#.utf8).write(to: url)
        try Config.appendRule(RuleConfig(name: "R", nameRegex: "x", to: "Y"), at: url)
        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        XCTAssertEqual(obj["mode"] as? String, "auto")
        XCTAssertEqual(obj["custom"] as? Int, 1)
        XCTAssertEqual((obj["rules"] as? [Any])?.count, 1)
    }

    // MARK: Claude

    func testAIAnswersAreValidatedAndCapped() throws {
        let f = Inspector.full(try s.write(s.downloads, "manual.pdf", "x"))!
        XCTAssertThrowsError(try AIAdvisor.validated(folder: "../etc", rename: "", confidence: 0.9, reason: "", f: f, config: s.config))
        XCTAssertThrowsError(try AIAdvisor.validated(folder: "_Sensitive", rename: "", confidence: 0.9, reason: "", f: f, config: s.config))
        XCTAssertThrowsError(try AIAdvisor.validated(folder: "Dev/x", rename: "", confidence: 0.9, reason: "", f: f, config: s.config))
        let d = try AIAdvisor.validated(folder: "Personal/Vehicles", rename: "Vulcan 800 manual", confidence: 0.99, reason: "bike", f: f, config: s.config)
        XCTAssertEqual(d.destination, s.lib("Personal/Vehicles"))
        XCTAssertEqual(d.newName, "Vulcan 800 manual.pdf")
        XCTAssertLessThan(d.confidence, s.config.autoThreshold, "AI suggestions never act on their own")
    }

    func testSecretsAreNeverSentToClaude() throws {
        let f = Inspector.full(try s.write(s.downloads, "notes.txt", "-----BEGIN RSA PRIVATE KEY-----\nabc"))!
        XCTAssertNotNil(AIAdvisor.blockReason(f, decision: nil))
        let resume = Decision(action: .move, confidence: 0.8, rule: "resume", reason: "", flags: ["sensitive", "noAI"])
        XCTAssertNotNil(AIAdvisor.blockReason(Inspector.full(try s.write(s.downloads, "cv.txt", "Jo"))!, decision: resume))
    }

    func testAIPromptHasExcerptNotWholeFile() throws {
        let long = String(repeating: "lorem ipsum ", count: 2000)
        let p = AIAdvisor.prompt(for: Inspector.full(try s.write(s.downloads, "essay.txt", long))!, config: s.config)
        XCTAssertLessThan(p.count, 4000)
        XCTAssertTrue(p.contains("essay.txt"))
    }

    // MARK: Search

    func testSearchFindsContentButNeverSecrets() throws {
        let e = try s.engine()
        try s.write(s.downloads, "Product Call.txt", tactiqHeader)
        try s.write(s.downloads, "client_secret_1.json", #"{"client_secret": "installer portal"}"#)
        e.scanNow()
        let hits = e.ledger.searchContent("installer portal")
        XCTAssertEqual(hits.map(\.item.name), ["Product Call.txt"])
        XCTAssertTrue(hits[0].snippet.contains("«"))
    }

    // MARK: Expiry

    func testStaleDownloadsExpireToTrashInAuto() throws {
        s.config.mode = .auto
        s.config.roots[0].expireDays = 30
        let e = try s.engine()
        let lunch = try s.write(s.downloads, "notes about lunch.txt", "tacos")
        setLastUsed(lunch, daysAgo: 40)
        e.scanNow()
        let id = e.ledger.search("lunch").first!.id
        XCTAssertEqual(e.ledger.item(id)?.status, "held")
        e.ledger.update(id, ["first_seen": Date().addingTimeInterval(-40 * 86400)])
        XCTAssertEqual(e.expireStale(), [id])
        XCTAssertEqual(e.ledger.item(id)?.status, "trashed")
        // and it's undoable
        _ = try e.undo(id)
        XCTAssertEqual(e.ledger.item(id)?.status, "kept")
    }

    func testKeptItemsNeverExpire() throws {
        s.config.mode = .auto
        s.config.roots[0].expireDays = 30
        let e = try s.engine()
        setLastUsed(try s.write(s.downloads, "keepsake.txt", "x"), daysAgo: 40)
        e.scanNow()
        let id = e.ledger.search("keepsake").first!.id
        try e.keep(id)
        e.ledger.update(id, ["first_seen": Date().addingTimeInterval(-40 * 86400)])
        XCTAssertTrue(e.expireStale().isEmpty)
    }
}

final class SmartFilingTests: XCTestCase {
    var s: Sandbox!

    override func setUpWithError() throws {
        s = try Sandbox()
        setenv("ANTHROPIC_API_KEY", "sk-ant-test-key-for-eligibility-only", 1)
    }

    override func tearDown() { unsetenv("ANTHROPIC_API_KEY") }

    func engine(scope: AIConfig.Scope, enabled: Bool = true) throws -> Engine {
        s.config.ai.enabled = enabled
        s.config.ai.scope = scope
        return try s.engine()
    }

    func facts(_ name: String, _ text: String, in dir: URL? = nil) throws -> ItemFacts {
        Inspector.full(try s.write(dir ?? s.downloads, name, text))!
    }

    func testOffByDefault() throws {
        XCTAssertFalse(Config.standard.ai.enabled)
        let e = try engine(scope: .documents, enabled: false)
        let f = try facts("memo.txt", "Quarterly plan for the lender portal")
        XCTAssertFalse(e.smartFilingApplies(f, Classifier(config: s.config).classify(f, root: s.config.roots[0])))
    }

    func testUnsureScopeOnlyReadsUnplacedItems() throws {
        let e = try engine(scope: .unsure)
        let unsure = try facts("notes about lunch.txt", "tacos and a plan")
        let sure = try facts("Product Call.txt", tactiqHeader)
        let c = Classifier(config: s.config)
        XCTAssertTrue(e.smartFilingApplies(unsure, c.classify(unsure, root: s.config.roots[0])))
        XCTAssertFalse(e.smartFilingApplies(sure, c.classify(sure, root: s.config.roots[0])))
    }

    func testDocumentsScopeReadsConfidentDocumentsToo() throws {
        let e = try engine(scope: .documents)
        let sure = try facts("Product Call.txt", tactiqHeader)
        XCTAssertTrue(e.smartFilingApplies(sure, Classifier(config: s.config).classify(sure, root: s.config.roots[0])))
    }

    func testFirmRulesAlwaysWin() throws {
        let e = try engine(scope: .documents)
        let c = Classifier(config: s.config)
        for (name, text) in [("client_secret_1.json", #"{"client_secret":"x"}"#), ("Untitled.md", "x"),
                             ("Screenshot 2026-10-13 at 10.14.43.png", "png"), ("Jo.vcf", "BEGIN:VCARD")] {
            let f = try facts(name, text)
            XCTAssertFalse(e.smartFilingApplies(f, c.classify(f, root: s.config.roots[0])), name)
        }
        s.config.rules = [RuleConfig(name: "Mine", nameRegex: "lunch", to: "Personal")]
        let e2 = try s.engine()
        let f = try facts("notes about lunch.txt", "tacos")
        XCTAssertFalse(e2.smartFilingApplies(f, Classifier(config: s.config).classify(f, root: s.config.roots[0])), "your rules win")
    }

    func testSuggestionsStayBelowAutoUnlessAllowed() throws {
        let f = try facts("manual.pdf", "x")
        let suggestion = try AIAdvisor.validated(folder: "Personal", rename: "", confidence: 0.99, reason: "", f: f, config: s.config)
        XCTAssertLessThan(suggestion.confidence, s.config.autoThreshold)
        let allowed = try AIAdvisor.validated(folder: "Personal", rename: "", confidence: 0.99, reason: "", f: f,
                                              config: s.config, ceiling: AIAdvisor.autoCeiling)
        XCTAssertGreaterThanOrEqual(allowed.confidence, s.config.autoThreshold)
    }

    func testPromptCarriesClientAliasesButNotPeople() throws {
        let p = AIAdvisor.prompt(for: try facts("memo.txt", "hello"), config: s.config)
        XCTAssertTrue(p.contains("Acme [Clients/Acme], also called Roadrunner"))
        XCTAssertFalse(p.contains("Jordan Patel"))
    }

    func testExcerptLengthIsConfigurable() throws {
        s.config.ai.excerptChars = 4000
        let long = String(repeating: "word ", count: 3000)
        let p = AIAdvisor.prompt(for: try facts("essay.txt", long), config: s.config)
        XCTAssertGreaterThan(p.count, 4000)
        XCTAssertLessThan(p.count, 6500)
    }
}
