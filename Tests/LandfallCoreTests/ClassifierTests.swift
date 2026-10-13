import XCTest
@testable import LandfallCore

final class ClassifierTests: XCTestCase {
    var s: Sandbox!

    override func setUpWithError() throws { s = try Sandbox() }

    func testParsesTactiqTranscript() {
        let t = Transcript.parse(tactiqHeader)
        XCTAssertEqual(t?.title, "Product Call")
        XCTAssertEqual(t?.participants.count, 4)
        XCTAssertEqual(t.flatMap { $0.date }.map { formatDate($0, "yyyy-MM-dd") }, "2026-09-21")
    }

    func testTranscriptFiledUnderClientByParticipants() throws {
        let u = try s.write(s.downloads, "Product Call.txt", tactiqHeader)
        let d = s.classify(u)
        XCTAssertEqual(d.rule, "transcript")
        XCTAssertEqual(d.destination, s.lib("Meetings/Acme/2026-09"))
        XCTAssertEqual(d.newName, "2026-09-21 Product Call.txt")
        XCTAssertGreaterThanOrEqual(d.confidence, 0.9)
    }

    func testTranscriptTitleWithSlashIsSanitized() throws {
        let text = tactiqHeader.replacingOccurrences(of: "# Product Call", with: "# Demo/Q&A")
        let d = s.classify(try s.write(s.downloads, "x.txt", text))
        XCTAssertEqual(d.newName, "2026-09-21 Demo-Q&A.txt")
    }

    func testServiceAccountKeyIsSensitive() throws {
        let u = try s.write(s.desktop, "g2i-data-warehouse-493da0a44e21.json",
                            #"{"type": "service_account", "private_key": "-----BEGIN PRIVATE KEY-----\nabc"}"#)
        let d = s.classify(u, root: "desktop")
        XCTAssertEqual(d.rule, "credential")
        XCTAssertEqual(d.destination, s.lib("_Sensitive"))
        XCTAssertTrue(d.flags.contains("alert"))
        XCTAssertTrue(d.flags.contains("noAI"))
    }

    func testClientSecretByName() throws {
        let u = try s.write(s.downloads, "client_secret_2_5276.apps.googleusercontent.com.json", "{}")
        XCTAssertEqual(s.classify(u).rule, "credential")
    }

    func testP12IsSensitive() throws {
        XCTAssertEqual(s.classify(try s.write(s.library, "apple.p12", "binary"), root: "documents").rule, "credential")
    }

    func testRecoveryCodesAreSensitive() throws {
        XCTAssertEqual(s.classify(try s.write(s.downloads, "stripe_backup_code.txt", "1234 5678")).rule, "credential")
    }

    func testContactCardIsPersonalData() throws {
        let d = s.classify(try s.write(s.downloads, "Patrick Severs.vcf", "BEGIN:VCARD"))
        XCTAssertEqual(d.destination, s.lib("Personal/Contacts"))
        XCTAssertTrue(d.flags.contains("noAI"))
    }

    func testTranscriptWithOnlyContentMatchNeedsReview() throws {
        let text = tactiqHeader
            .replacingOccurrences(of: "Alex Rivera, Jordan Patel, Pat Owner, Casey Morgan", with: "Pat Owner, Riley Chen")
            .replacingOccurrences(of: "rocket portal", with: "the Acme rollout")
        let d = s.classify(try s.write(s.downloads, "Meeting Transcription.txt", text))
        XCTAssertEqual(d.destination, s.lib("Meetings/Acme/2026-09"))
        XCTAssertLessThan(d.confidence, s.config.autoThreshold)
    }

    func testTranscriptTitleNamesClient() throws {
        let text = tactiqHeader
            .replacingOccurrences(of: "# Product Call", with: "# Globex Weekly touch base")
            .replacingOccurrences(of: "Alex Rivera, Jordan Patel, Pat Owner, Casey Morgan", with: "Pat Owner")
        let d = s.classify(try s.write(s.downloads, "notes.txt", text))
        XCTAssertEqual(d.destination, s.lib("Meetings/Globex/2026-09"))
    }

    func testBrowserDuplicateIsTrashed() throws {
        try s.write(s.downloads, "127.0.0.1_5174___foundation.png", "same bytes")
        let dup = try s.write(s.downloads, "127.0.0.1_5174___foundation (3).png", "same bytes")
        let d = s.classify(dup)
        XCTAssertEqual(d.action, .trash)
        XCTAssertEqual(d.rule, "duplicate")
    }

    func testDifferentNumberedCopyIsNotDuplicate() throws {
        try s.write(s.downloads, "127.0.0.1_5174___foundation.png", "v1")
        let v2 = try s.write(s.downloads, "127.0.0.1_5174___foundation (1).png", "v2")
        let d = s.classify(v2)
        XCTAssertEqual(d.rule, "dev-capture")
        XCTAssertEqual(d.destination, s.lib("Screenshots/Dev Captures/port-5174"))
    }

    func testZipWithUnzippedTwinIsTrashed() throws {
        let dir = s.downloads.appendingPathComponent("High Res Files")
        try s.write(dir, "a.png", "a")
        try s.write(dir, "sub/b.png", "b")
        let zip = s.downloads.appendingPathComponent("High Res Files.zip")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        p.currentDirectoryURL = s.downloads
        p.arguments = ["-qr", zip.path, "High Res Files"]
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        let d = s.classify(zip)
        XCTAssertEqual(d.rule, "archive-twin")
        XCTAssertEqual(d.action, .trash)
    }

    func testScreenshotByName() throws {
        let d = s.classify(try s.write(s.desktop, "Screenshot 2026-10-05 at 22.43.48.png", "png"), root: "desktop")
        XCTAssertEqual(d.rule, "screenshot")
        XCTAssertTrue(d.destination!.hasPrefix(s.lib("Screenshots/")))
    }

    func testUntitledScratchFileIsJunk() throws {
        let d = s.classify(try s.write(s.desktop, "Untitled.md", "# Test\n\ngfy\n"), root: "desktop")
        XCTAssertEqual(d.action, .trash)
        XCTAssertEqual(d.rule, "junk")
    }

    func testContractWithClientInName() throws {
        let d = s.classify(try s.write(s.downloads, "GLOBEX CTO Agreement - Draft.txt", "terms"))
        XCTAssertEqual(d.rule, "contract")
        XCTAssertEqual(d.destination, s.lib("Clients/Globex/Contracts"))
    }

    func testOwnResumeGoesToPersonal() throws {
        let d = s.classify(try s.write(s.downloads, "Another Resu,e.txt", "Pat Owner\nHead of Architecture"))
        XCTAssertEqual(d.destination, s.lib("Personal"))
    }

    func testSomeoneElsesResumeIsSensitive() throws {
        let d = s.classify(try s.write(s.downloads, "04-Taylor_Resume_2026.txt", "Taylor\nEngineer"))
        XCTAssertEqual(d.destination, s.lib("Personal/Hiring"))
        XCTAssertTrue(d.flags.contains("noAI"))
    }

    func testFontFile() throws {
        XCTAssertEqual(s.classify(try s.write(s.downloads, "IoskeleyMono-Bold.woff2", "font")).rule, "font")
    }

    func testAudio() throws {
        XCTAssertEqual(s.classify(try s.write(s.downloads, "05 Vosturan Mastered.mp3", "id3")).destination, s.lib("Music"))
    }

    func testClientDataByName() throws {
        let d = s.classify(try s.write(s.downloads, "acme-loans.csv", "a,b\n1,2"))
        XCTAssertEqual(d.destination, s.lib("Clients/Acme/Data"))
    }

    func testDotfilesAndPartialDownloadsIgnored() throws {
        XCTAssertEqual(s.classify(try s.write(s.downloads, ".DS_Store", "x")).action, .ignore)
        XCTAssertEqual(s.classify(try s.write(s.downloads, "big.zip.crdownload", "x")).action, .ignore)
    }

    func testLibraryFoldersIgnored() throws {
        let dir = s.library.appendingPathComponent("Clients")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        XCTAssertEqual(s.classify(dir, root: "documents").action, .ignore)
    }

    func testUserRuleWins() throws {
        s.config.rules = [RuleConfig(name: "Carb manuals", nameRegex: "(?i)carburetor", to: "Personal/Vehicles")]
        let d = s.classify(try s.write(s.downloads, "1995 Vulcan 800 Carburetor.txt", "manual"))
        XCTAssertEqual(d.rule, "rule:Carb manuals")
        XCTAssertEqual(d.destination, s.lib("Personal/Vehicles"))
    }

    func testUnknownThingIsHeld() throws {
        let d = s.classify(try s.write(s.downloads, "notes about lunch.txt", "tacos"))
        XCTAssertEqual(d.action, .hold)
    }

    func testWordMatchingRespectsBoundaries() {
        XCTAssertTrue("GLOBEX_CTO Agreement".containsWord("Globex"))
        XCTAssertFalse("Acmephere report".containsWord("Acme"))
    }
}
