import AppKit
import LandfallCore

/// NSMenuItem that runs a closure.
final class ActionItem: NSMenuItem {
    private var handler: (() -> Void)?

    init(_ title: String, _ handler: (() -> Void)? = nil) {
        super.init(title: title, action: handler == nil ? nil : #selector(fire), keyEquivalent: "")
        self.handler = handler
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc func fire() { handler?() }
}

/// The menu bar timeline: what landed, where it went, what needs a decision.
final class MenuBarController: NSObject, NSMenuDelegate {
    let engine: Engine
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    init(engine: Engine) {
        self.engine = engine
        super.init()
        statusItem.button?.image = NSImage(systemSymbolName: "tray.and.arrow.down", accessibilityDescription: "Landfall")
        statusItem.button?.imagePosition = .imageLeading
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        engine.onChange = { [weak self] in self?.refreshBadge() }
        refreshBadge()
    }

    func refreshBadge() {
        let n = engine.ledger.count(status: "proposed")
        statusItem.button?.title = n > 0 ? " \(n)" : ""
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let e = engine
        menu.addItem(ActionItem("Landfall — \(e.config.mode.rawValue) mode"))
        menu.addItem(.separator())

        let review = e.ledger.items(statuses: ["proposed"]).filter { fileExists($0.path) }
        if !review.isEmpty {
            let header = ActionItem("Needs a decision (\(review.count))")
            let sub = NSMenu()
            sub.addItem(ActionItem("Apply all \(review.count)") { [weak self] in
                for it in review { _ = try? e.apply(it.id) }
                self?.refreshBadge()
            })
            sub.addItem(.separator())
            for it in review.prefix(25) { sub.addItem(reviewItem(it)) }
            header.submenu = sub
            menu.addItem(header)
            menu.addItem(.separator())
        }

        let recent = e.ledger.recent(since: Date().addingTimeInterval(-7 * 86400)).prefix(15)
        menu.addItem(ActionItem(recent.isEmpty ? "Nothing landed this week" : "Recently landed"))
        for it in recent { menu.addItem(recentItem(it)) }
        menu.addItem(.separator())

        let modes = ActionItem("Mode")
        let modeMenu = NSMenu()
        for m in Mode.allCases {
            let mi = ActionItem(m.rawValue) {
                try? Config.set("mode", m.rawValue)
                if let c = try? Config.load() { e.reload(c) }
            }
            mi.state = e.config.mode == m ? .on : .off
            modeMenu.addItem(mi)
        }
        modes.submenu = modeMenu
        menu.addItem(modes)
        let held = e.ledger.items(statuses: ["held"]).filter { fileExists($0.path) && $0.decision?.rule == "fallback" }
        if !held.isEmpty && Keychain.apiKey() != nil {
            menu.addItem(ActionItem("Ask Claude about \(held.count) unplaced item\(held.count == 1 ? "" : "s")") {
                for it in held { Task { @MainActor in _ = try? await e.askAI(it.id) } }
            })
        }
        let secrets = e.ledger.items(statuses: ["proposed", "held", "filed", "kept"])
            .filter { $0.decision?.rule == "credential" && fileExists($0.path) }
        if !secrets.isEmpty {
            menu.addItem(ActionItem("Import \(secrets.count) credential file\(secrets.count == 1 ? "" : "s") to 1Password…") {
                let alert = NSAlert()
                alert.messageText = "Import \(secrets.count) credential files to 1Password?"
                alert.informativeText = secrets.map(\.name).joined(separator: "\n")
                    + "\n\nEach becomes a Document item; the originals go to the Trash."
                    + (OnePassword.cli == nil ? "\n\n" + OnePassword.installHint : "")
                alert.addButton(withTitle: "Cancel")
                alert.addButton(withTitle: "Import")
                NSApp.activate(ignoringOtherApps: true)
                guard alert.runModal() == .alertSecondButtonReturn else { return }
                let failures = secrets.compactMap { it -> String? in
                    do { try e.vault(it.id); return nil } catch { return "\(it.name): \(error)" }
                }
                notify("Landfall · 1Password", failures.isEmpty ? "Imported \(secrets.count) items." : failures.joined(separator: "\n"))
            })
        }
        menu.addItem(ActionItem("Scan now") { e.scanNow() })
        menu.addItem(ActionItem("Space report") { Agent.shared?.weeklySpaceReport(force: true) })
        menu.addItem(ActionItem("Undo last action") { [weak self] in
            if let id = e.ledger.lastAppliedOverall()?.itemId { _ = try? e.undo(id) }
            self?.refreshBadge()
        })
        menu.addItem(ActionItem("Settings…") { Agent.shared?.openSettings() })
        menu.addItem(ActionItem("Open log") { NSWorkspace.shared.open(Paths.logURL) })
        menu.addItem(.separator())
        menu.addItem(ActionItem("Quit Landfall") { NSApp.terminate(nil) })
    }

    func recentItem(_ it: Item) -> NSMenuItem {
        let mark: String
        switch it.status {
        case "filed": mark = "✓"
        case "proposed": mark = "?"
        case "trashed": mark = "🗑"
        case "held": mark = "…"
        default: mark = "·"
        }
        let warn = it.decision?.flags.contains("sensitive") == true ? " ⚠️" : ""
        let mi = ActionItem("\(mark)  \(it.name)\(warn)  —  \(ago(it.firstSeen))")
        mi.toolTip = it.decision?.reason
        let sub = NSMenu()
        sub.addItem(ActionItem(Paths.pretty(it.path)))
        sub.addItem(.separator())
        let url = URL(fileURLWithPath: it.path)
        if fileExists(it.path) {
            sub.addItem(ActionItem("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) })
            sub.addItem(ActionItem("Open") { NSWorkspace.shared.open(url) })
        }
        if engine.ledger.lastApplied(it.id) != nil {
            sub.addItem(ActionItem("Undo") { [weak self] in _ = try? self?.engine.undo(it.id) })
        }
        mi.submenu = sub
        return mi
    }

    func reviewItem(_ it: Item) -> NSMenuItem {
        let d = it.decision
        let target = d?.action == .trash ? "Trash" : (d?.destination.map { Paths.pretty($0) } ?? "?")
        let mi = ActionItem("\(it.name)  →  \(target)")
        mi.toolTip = d.map { "\($0.reason) (\($0.rule), \(String(format: "%.2f", $0.confidence)))" }
        let sub = NSMenu()
        sub.addItem(ActionItem(d?.reason ?? ""))
        sub.addItem(.separator())
        sub.addItem(ActionItem("Apply") { [weak self] in _ = try? self?.engine.apply(it.id); self?.refreshBadge() })
        sub.addItem(ActionItem("Keep where it is") { [weak self] in try? self?.engine.keep(it.id); self?.refreshBadge() })
        sub.addItem(ActionItem("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: it.path)])
        })
        mi.submenu = sub
        return mi
    }
}
