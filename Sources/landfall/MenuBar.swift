import AppKit
import LandfallCore

/// NSMenuItem that runs a closure, with an optional SF Symbol and shortcut.
final class ActionItem: NSMenuItem {
    private var handler: (() -> Void)?

    init(_ title: String, symbol: String? = nil, key: String = "", _ handler: (() -> Void)? = nil) {
        super.init(title: title, action: handler == nil ? nil : #selector(fire), keyEquivalent: key)
        self.handler = handler
        target = self
        if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
    }

    required init(coder: NSCoder) { fatalError() }

    @objc func fire() { handler?() }

    /// Second line under the title (macOS 14.4+).
    func detail(_ text: String?) -> Self {
        if #available(macOS 14.4, *), let text { subtitle = text }
        return self
    }
}

/// The menu bar timeline: what landed, where it went, what needs a decision.
final class MenuBarController: NSObject, NSMenuDelegate {
    let engine: Engine
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    init(engine: Engine) {
        self.engine = engine
        super.init()
        statusItem.button?.image = Self.glyph
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.setAccessibilityTitle("Landfall")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        engine.onChange = { [weak self] in self?.refreshBadge() }
        Updater.shared.onChange = { [weak self] in self?.refreshBadge() }
        refreshBadge()
    }

    /// The app icon's idea in a template glyph: an arrow touching down on a shoreline.
    static let glyph: NSImage = {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            NSColor.black.set()
            let arrow = NSBezierPath()
            arrow.move(to: NSPoint(x: 7.6, y: 1.5))
            arrow.line(to: NSPoint(x: 10.4, y: 1.5))
            arrow.line(to: NSPoint(x: 10.4, y: 7.5))
            arrow.line(to: NSPoint(x: 13.6, y: 7.5))
            arrow.line(to: NSPoint(x: 9, y: 13))
            arrow.line(to: NSPoint(x: 4.4, y: 7.5))
            arrow.line(to: NSPoint(x: 7.6, y: 7.5))
            arrow.close()
            arrow.lineJoinStyle = .round
            arrow.lineWidth = 1
            arrow.fill()
            arrow.stroke()
            let shore = NSBezierPath()
            shore.move(to: NSPoint(x: 1.5, y: 16.2))
            shore.curve(to: NSPoint(x: 16.5, y: 16.2), controlPoint1: NSPoint(x: 6, y: 13.4), controlPoint2: NSPoint(x: 12, y: 13.4))
            shore.lineWidth = 1.6
            shore.lineCapStyle = .round
            shore.stroke()
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "Landfall"
        return img
    }()

    func refreshBadge() {
        let n = engine.ledger.count(status: "proposed")
        statusItem.button?.title = n > 0 ? "\(n)" : ""
        statusItem.button?.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        statusItem.button?.setAccessibilityValue(n > 0 ? "\(n) waiting for a decision" : nil)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let e = engine

        // Status
        let modeInfo: (String, String) = {
            switch e.config.mode {
            case .shadow: return ("Watching only", "eye")
            case .review: return ("Suggesting — you approve", "checklist")
            case .auto: return ("Filing automatically", "bolt.fill")
            }
        }()
        let folders = e.config.roots.map { $0.name.capitalized }.joined(separator: ", ")
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        menu.addItem(ActionItem(modeInfo.0, symbol: modeInfo.1)
            .detail("Watching \(folders)" + (version.map { " · Landfall \($0)" } ?? "")))

        // Needs a decision
        let review = e.ledger.items(statuses: ["proposed"]).filter { fileExists($0.path) }
        if !review.isEmpty {
            menu.addItem(.separator())
            menu.addItem(.sectionHeader(title: "Needs a Decision"))
            for it in review.prefix(8) { menu.addItem(reviewItem(it)) }
            if review.count > 8 {
                let more = ActionItem("\(review.count - 8) more…", symbol: "ellipsis.circle")
                let sub = NSMenu()
                for it in review.dropFirst(8).prefix(40) { sub.addItem(reviewItem(it)) }
                more.submenu = sub
                menu.addItem(more)
            }
            let all = ActionItem("Apply All", symbol: "checkmark.circle") { [weak self] in
                for it in review { _ = try? e.apply(it.id) }
                self?.refreshBadge()
            }
            all.badge = NSMenuItemBadge(count: review.count)
            menu.addItem(all)
        }

        // Recently landed
        menu.addItem(.separator())
        let recent = e.ledger.recent(since: Date().addingTimeInterval(-7 * 86400)).prefix(10)
        menu.addItem(.sectionHeader(title: recent.isEmpty ? "Nothing Landed This Week" : "Recently Landed"))
        for it in recent { menu.addItem(recentItem(it)) }

        // Tools
        menu.addItem(.separator())
        let held = e.ledger.items(statuses: ["held"]).filter { fileExists($0.path) && $0.decision?.rule == "fallback" }
        if !held.isEmpty && Keychain.apiKey() != nil {
            let ask = ActionItem("Smart File Unplaced Items", symbol: "sparkles") {
                for it in held { Task { @MainActor in _ = try? await e.askAI(it.id) } }
            }
            ask.badge = NSMenuItemBadge(count: held.count)
            menu.addItem(ask)
        }
        let secrets = e.ledger.items(statuses: ["proposed", "held", "filed", "kept"])
            .filter { $0.decision?.rule == "credential" && fileExists($0.path) }
        if !secrets.isEmpty {
            let vault = ActionItem("Import Credentials to 1Password…", symbol: "key") { importSecrets(secrets, engine: e) }
            vault.badge = NSMenuItemBadge(count: secrets.count)
            menu.addItem(vault)
        }
        menu.addItem(ActionItem("Scan Now", symbol: "arrow.clockwise", key: "r") { e.scanNow() })
        menu.addItem(ActionItem("Space Report", symbol: "internaldrive") { Agent.shared?.weeklySpaceReport(force: true) })
        let undo = ActionItem("Undo Last Action", symbol: "arrow.uturn.backward", key: "z") { [weak self] in
            if let id = e.ledger.lastAppliedOverall()?.itemId { _ = try? e.undo(id) }
            self?.refreshBadge()
        }
        if let last = e.ledger.lastAppliedOverall(), let it = e.ledger.item(last.itemId) { _ = undo.detail(it.name) }
        menu.addItem(undo)

        // App
        menu.addItem(.separator())
        let modes = ActionItem("Mode", symbol: "dial.medium")
        let modeMenu = NSMenu()
        for (m, title, symbol) in [(Mode.shadow, "Watch Only", "eye"), (.review, "Suggest — I Approve", "checklist"),
                                   (.auto, "File Automatically", "bolt")] {
            let mi = ActionItem(title, symbol: symbol) {
                try? Config.set("mode", m.rawValue)
                if let c = try? Config.load() { e.reload(c) }
            }
            mi.state = e.config.mode == m ? .on : .off
            modeMenu.addItem(mi)
        }
        modes.submenu = modeMenu
        menu.addItem(modes)
        menu.addItem(ActionItem("Settings…", symbol: "gearshape", key: ",") { Agent.shared?.openSettings() })
        if Updater.shared.isRunning {
            if let v = Updater.shared.availableVersion {
                let up = ActionItem("Update to \(v)…", symbol: "arrow.down.circle.fill") { Updater.shared.checkForUpdates() }
                up.badge = NSMenuItemBadge(string: "New")
                menu.addItem(up)
            } else {
                menu.addItem(ActionItem("Check for Updates…", symbol: "arrow.down.circle") { Updater.shared.checkForUpdates() })
            }
        }
        menu.addItem(ActionItem("Open Log", symbol: "doc.text.magnifyingglass") { NSWorkspace.shared.open(Paths.logURL) })
        menu.addItem(.separator())
        menu.addItem(ActionItem("Quit Landfall", key: "q") { NSApp.terminate(nil) })
    }

    // MARK: - Rows

    static func fileIcon(_ path: String) -> NSImage {
        let icon = NSWorkspace.shared.icon(forFile: path)
        icon.size = NSSize(width: 16, height: 16)
        return icon
    }

    static func place(_ path: String) -> String {
        let dir = (path as NSString).deletingLastPathComponent
        let home = Paths.home + "/"
        return (dir.hasPrefix(home) ? String(dir.dropFirst(home.count)) : dir).split(separator: "/").joined(separator: " › ")
    }

    func recentItem(_ it: Item) -> NSMenuItem {
        let status: String
        switch it.status {
        case "filed": status = "Filed → \(Self.place(it.path))"
        case "proposed": status = "Waiting for you"
        case "trashed": status = "Moved to Trash"
        case "held": status = "Staying put"
        case "kept": status = "Kept in place"
        case "elsewhere": status = "You moved it → \(Self.place(it.path))"
        default: status = it.status.capitalized
        }
        let sensitive = it.decision?.flags.contains("sensitive") == true ? "  ·  Private" : ""
        let mi = ActionItem(it.name).detail("\(status) · \(ago(it.firstSeen))\(sensitive)")
        mi.image = fileExists(it.path) ? Self.fileIcon(it.path)
            : NSImage(systemSymbolName: it.status == "trashed" ? "trash" : "questionmark.folder", accessibilityDescription: nil)
        mi.toolTip = it.decision?.reason
        let sub = NSMenu()
        let url = URL(fileURLWithPath: it.path)
        if fileExists(it.path) {
            sub.addItem(ActionItem("Open", symbol: "arrow.up.forward.app") { NSWorkspace.shared.open(url) })
            sub.addItem(ActionItem("Show in Finder", symbol: "folder") { NSWorkspace.shared.activateFileViewerSelecting([url]) })
        }
        if engine.ledger.lastApplied(it.id) != nil {
            sub.addItem(ActionItem("Undo", symbol: "arrow.uturn.backward") { [weak self] in _ = try? self?.engine.undo(it.id) })
        }
        if sub.items.isEmpty { sub.addItem(ActionItem(Paths.pretty(it.path))) }
        mi.submenu = sub
        return mi
    }

    func reviewItem(_ it: Item) -> NSMenuItem {
        let d = it.decision
        let target = d?.action == .trash ? "Move to Trash"
            : (d?.destination.map { "→ " + Self.place($0 + "/x") } ?? "?")
        let mi = ActionItem(it.name).detail("\(target) · \(d?.reason ?? "")")
        mi.image = Self.fileIcon(it.path)
        let sub = NSMenu()
        sub.addItem(ActionItem(d?.action == .trash ? "Move to Trash" : "Apply", symbol: d?.action == .trash ? "trash" : "checkmark") { [weak self] in
            _ = try? self?.engine.apply(it.id)
            self?.refreshBadge()
        })
        sub.addItem(ActionItem("Keep Where It Is", symbol: "pin") { [weak self] in
            try? self?.engine.keep(it.id)
            self?.refreshBadge()
        })
        sub.addItem(ActionItem("Show in Finder", symbol: "folder") {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: it.path)])
        })
        mi.submenu = sub
        return mi
    }
}

func importSecrets(_ secrets: [Item], engine e: Engine) {
    let alert = NSAlert()
    alert.messageText = "Import \(secrets.count) credential file\(secrets.count == 1 ? "" : "s") to 1Password?"
    alert.informativeText = secrets.map(\.name).joined(separator: "\n")
        + "\n\nEach becomes a Document item; the originals go to the Trash."
        + (OnePassword.cli == nil ? "\n\n" + OnePassword.installHint : "")
    alert.addButton(withTitle: "Import")
    alert.addButton(withTitle: "Cancel")
    alert.icon = NSImage(systemSymbolName: "key.fill", accessibilityDescription: nil)
    NSApp.activate(ignoringOtherApps: true)
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    let failures = secrets.compactMap { it -> String? in
        do { try e.vault(it.id); return nil } catch { return "\(it.name): \(error)" }
    }
    notify("Landfall · 1Password", failures.isEmpty ? "Imported \(secrets.count) items." : failures.joined(separator: "\n"))
}
