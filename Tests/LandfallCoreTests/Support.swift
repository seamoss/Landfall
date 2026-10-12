import Foundation
import XCTest
@testable import LandfallCore

/// A throwaway world: library, downloads and desktop roots inside a temp dir.
final class Sandbox {
    let base: URL
    let library: URL
    let downloads: URL
    let desktop: URL
    var config: Config

    init() throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("landfall-tests-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        library = base.appendingPathComponent("Documents")
        downloads = base.appendingPathComponent("Downloads")
        desktop = base.appendingPathComponent("Desktop")
        for d in [library, downloads, desktop] {
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
        // Keep the log (and any default paths) out of the real ~/Library.
        setenv("LANDFALL_HOME", base.path, 1)
        Log.echo = false
        config = Config.seeded()
        config.library = library.path
        config.recentShelf = nil
        config.notify = false
        config.settleSeconds = 0
        config.roots = [
            RootConfig(name: "downloads", path: downloads.path, role: .intake, graceSeconds: 0),
            RootConfig(name: "desktop", path: desktop.path, role: .shelf, graceSeconds: 0),
            RootConfig(name: "documents", path: library.path, role: .library, graceSeconds: 0, neverTouch: ["Dev"]),
        ]
    }

    deinit { try? FileManager.default.removeItem(at: base) }

    @discardableResult
    func write(_ dir: URL, _ name: String, _ text: String) throws -> URL {
        let u = dir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: u)
        return u
    }

    func engine() throws -> Engine {
        Engine(config: config, ledger: try Ledger(path: base.appendingPathComponent("ledger.sqlite")))
    }

    func classify(_ url: URL, root: String = "downloads", context: ClassifierContext? = nil) -> Decision {
        let f = Inspector.full(url)!
        return Classifier(config: config, context: context).classify(f, root: config.root(named: root)!)
    }

    func lib(_ rel: String) -> String { library.appendingPathComponent(rel).path }
}

let tactiqHeader = """
# Product Call

  Meeting started: 9/21/2026, 11:00:53 AM
  Duration: 43 minutes
  Participants: Alex Rivera, Jordan Patel, Pat Owner, Casey Morgan

  ## Highlights
  > 01:39 Jordan: let's look at the installer portal.
"""
