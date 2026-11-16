import AppKit
import SwiftUI
import LandfallCore
import QuickLookThumbnailing

// MARK: - Carrying out actions

enum Performer {
    static let fm = FileManager.default

    /// Returns a short result line for the toast, or throws.
    static func perform(_ a: FileAction, _ m: ToastModel, engine: Engine) throws -> String? {
        let url = m.url
        switch a.kind {
        case .open:
            NSWorkspace.shared.open(url)
        case .preview:
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
            p.arguments = ["-p", url.path]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run()  // Quick Look is sandboxed; don't wait for it to close
        case .reveal:
            NSWorkspace.shared.activateFileViewerSelecting([url])
        case .fileNow, .moveToSensitive:
            guard let id = m.itemId else { throw LandfallError.action("not tracked") }
            let it = try engine.fileNow(id)
            return it.status == "trashed" ? "Moved to Trash" : "Filed to \(Paths.pretty((it.path as NSString).deletingLastPathComponent))"
        case .keep:
            guard let id = m.itemId else { return nil }
            try engine.keep(id)
            return "Leaving it here"
        case .undo:
            guard let id = m.itemId else { return nil }
            return "Back at \(Paths.pretty(try engine.undo(id)))"
        case .unzip:
            let dest = Mover.uniqueURL(dir: url.deletingLastPathComponent(), name: url.deletingPathExtension().lastPathComponent)
            engine.quiet.insert(normalize(dest.path))
            let out = try Unarchiver.extract(url)
            NSWorkspace.shared.activateFileViewerSelecting([out])
            return "Unpacked to \(out.lastPathComponent)/"
        case .installFont where !Capabilities.installFontsDirectly:
            try open(url, withBundle: "com.apple.FontBook")
            return "Opened in Font Book"
        case .installFont:
            let fonts = URL(fileURLWithPath: Paths.home).appendingPathComponent("Library/Fonts")
            try fm.createDirectory(at: fonts, withIntermediateDirectories: true)
            let dst = Mover.uniqueURL(dir: fonts, name: url.lastPathComponent)
            try fm.copyItem(at: url, to: dst)
            return "Installed \(dst.lastPathComponent)"
        case .addToCalendar:
            try open(url, withBundle: "com.apple.iCal")
        case .addContact:
            try open(url, withBundle: "com.apple.AddressBook")
        case .openInEditor:
            guard let e = m.editor else { throw LandfallError.action("no editor found") }
            try open(url, withBundle: e.bundleId)
        case .viewSource:
            run("/usr/bin/open", ["-t", url.path])  // default plain-text editor, never executes
        case .runInTerminal:
            let cmd = "cd \(shellQuote(url.deletingLastPathComponent().path)) && \(interpreterCommand(for: url))"
            let script = "tell application \"Terminal\"\nactivate\ndo script \"\(cmd.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\"\nend tell"
            let r = run("/usr/bin/osascript", ["-e", script], stderr: true)
            if r.status != 0 { throw LandfallError.action("Terminal refused: \(r.out)") }
        case .moveToApplications:
            var apps = URL(fileURLWithPath: "/Applications")
            if !fm.isWritableFile(atPath: apps.path) {
                apps = URL(fileURLWithPath: Paths.home).appendingPathComponent("Applications")
            }
            if fileExists(apps.appendingPathComponent(url.lastPathComponent).path) {
                throw LandfallError.action("\(url.lastPathComponent) is already in \(Paths.pretty(apps.path))")
            }
            let dst = try Mover.move(url, toDir: apps)
            NSWorkspace.shared.activateFileViewerSelecting([dst])
            return "Moved to \(Paths.pretty(apps.path))"
        case .openInstaller:
            try open(url, withBundle: "com.apple.installer")
        case .mountImage:
            NSWorkspace.shared.open(url)
        case .openPasswordManager:
            if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.1password.1password")
                ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.agilebits.onepassword7") {
                NSWorkspace.shared.open(app)
            } else {
                throw LandfallError.action("1Password isn't installed")
            }
        case .copyImage:
            guard let img = NSImage(contentsOf: url) else { throw LandfallError.action("not an image") }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([img])
            return "Copied"
        case .openLink:
            guard let t = Trust.linkTarget(url), let target = URL(string: t) else { throw LandfallError.action("no link inside") }
            NSWorkspace.shared.open(target)
        case .importTo1Password:
            guard let id = m.itemId else { throw LandfallError.action("not tracked") }
            try engine.vault(id)
            return "Imported to 1Password; original in the Trash"
        case .askAI:
            guard let id = m.itemId else { throw LandfallError.action("not tracked") }
            Task { @MainActor in
                do { try await engine.askAI(id) } catch { notify("Landfall · Claude", "\(m.name): \(error)") }
            }
            return "Asking Claude…"
        case .addRule:
            guard let p = m.proposal else { return nil }
            try engine.acceptRule(p)
            return "Rule added — edit it in Settings"
        case .declineRule:
            if let p = m.proposal { engine.declineRule(p) }
            return "Won't ask about this again"
        case .dismiss:
            return nil
        case .undoAll:
            var n = 0
            for id in m.relatedIds where (try? engine.undo(id)) != nil { n += 1 }
            return "Undid \(n) of \(m.relatedIds.count)"
        case .cleanSpace:
            var freed = 0
            for p in m.paths where (try? engine.guardNeverTouch(p)) != nil && (try? Mover.trash(URL(fileURLWithPath: p))) != nil { freed += 1 }
            return "Moved \(freed) folders to the Trash"
        case .showReport:
            if let agent = Agent.shared { agent.showSpaceWindow() } else { run("/usr/bin/open", ["-t", url.path]) }
        }
        return nil
    }

    static func open(_ url: URL, withBundle id: String) throws {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else {
            throw LandfallError.action("app \(id) isn't installed")
        }
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// Run visibly in Terminal with the obvious interpreter — never via `chmod +x`.
    static func interpreterCommand(for url: URL) -> String {
        let q = shellQuote(url.path)
        switch url.pathExtension.lowercased() {
        case "py": return "python3 \(q)"
        case "rb": return "ruby \(q)"
        case "pl": return "perl \(q)"
        case "zsh": return "zsh \(q)"
        case "fish": return "fish \(q)"
        case "ps1": return "pwsh \(q)"
        case "scpt", "applescript": return "osascript \(q)"
        case "jxa": return "osascript -l JavaScript \(q)"
        case "jar": return "java -jar \(q)"
        case "workflow": return "automator \(q)"
        case "sh", "bash", "command", "tool": return "bash \(q)"
        default: return FileManager.default.isExecutableFile(atPath: url.path) ? q : "bash \(q)"
        }
    }
}

// MARK: - The toast

final class ToastPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class Toast: NSObject {
    let engine: Engine
    private(set) var model: ToastModel
    let panel: ToastPanel
    var onClose: ((Toast) -> Void)?
    /// Called when the toast changes height (e.g. becomes a receipt) so the stack can re-lay out.
    var onResize: (() -> Void)?
    private var seconds: Double
    private var remaining: Double
    private var ticker: Timer?
    private var paused = false
    private var closing = false
    private let state: ToastState

    static let width: CGFloat = ToastCard.width

    init(model: ToastModel, engine: Engine, seconds: Double) {
        self.model = model
        self.engine = engine
        self.seconds = seconds
        remaining = seconds
        state = ToastState(model: model)
        panel = ToastPanel(contentRect: NSRect(x: 0, y: 0, width: Toast.width, height: 120),
                           styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        super.init()
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        build()
    }

    var height: CGFloat { panel.frame.height }

    private func build() {
        state.model = model
        state.enabled = true
        let card = ToastCard(state: state, live: true,
                             onAction: { [weak self] a in self?.trigger(a) },
                             onDismiss: { [weak self] in self?.close() },
                             onHover: { [weak self] inside in
                                 self?.paused = inside
                                 self?.updateStatus()
                             })
        let hosting = FirstClickHostingView(rootView: card)
        let top = panel.frame.maxY
        panel.contentView = hosting
        let size = NSSize(width: Toast.width, height: hosting.fittingSize.height)
        panel.setFrame(NSRect(x: panel.frame.minX, y: top - size.height, width: size.width, height: size.height), display: true)
        panel.invalidateShadow()
        updateStatus()
    }

    func show(at origin: NSPoint) {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        // Drop down from under the menu bar.
        panel.setFrameOrigin(reduceMotion ? origin : NSPoint(x: origin.x, y: origin.y + 24))
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = reduceMotion ? 0.2 : 0.35
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)  // quick out, soft settle
            panel.animator().alphaValue = 1
            panel.animator().setFrameOrigin(origin)
        }
        announce()
        startTicking()
    }

    /// VoiceOver hears what landed and what will happen, without the toast taking focus.
    private func announce() {
        var text = "Landfall: \(model.name)"
        if let dest = model.destinationLabel { text += model.autoFile ? ", files to \(dest) in \(Int(seconds)) seconds" : ", \(dest)" }
        panel.setAccessibilityLabel(text)
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    func move(to origin: NSPoint) {
        NSAnimationContext.runAnimationGroup { $0.duration = 0.18; panel.animator().setFrameOrigin(origin) }
    }

    // MARK: Countdown

    private func startTicking() {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
    }

    private func restart(_ s: Double) {
        seconds = s
        remaining = s
        updateStatus()
    }

    private func tick() {
        guard !paused, !closing else { return }
        remaining -= 0.1
        updateStatus()
        if remaining <= 0 { timedOut() }
    }

    private func updateStatus() {
        state.progress = max(0, remaining / seconds)
        guard model.autoFile, !state.statusIsError else { return }
        state.status = paused ? "paused" : "files in \(max(1, Int(remaining.rounded(.up))))s"
    }

    private func showStatus(_ text: String, error: Bool = false) {
        state.status = text
        state.statusIsError = error
    }

    /// The default behavior: file it (confident, ordinary moves only), otherwise just go away.
    private func timedOut() {
        guard model.autoFile, let id = model.itemId else { return close() }
        model.autoFile = false
        do {
            let it = try engine.fileNow(id)
            Log.info("toast: auto-filed \(model.name)")
            becomeReceipt(it)
        } catch {
            showStatus("\(error)", error: true)
            restart(4)
        }
    }

    /// "Filed → Desktop › 2026-10-12" with Undo, for a few seconds.
    private func becomeReceipt(_ it: Item) {
        var r = model
        let filedTo = it.status == "trashed" ? "Trash"
            : (it.path as NSString).deletingLastPathComponent.replacingOccurrences(of: Paths.home + "/", with: "")
                .split(separator: "/").joined(separator: " › ")
        r.name = it.name
        r.url = URL(fileURLWithPath: it.path)
        r.subtitle = it.status == "trashed" ? "Moved to Trash" : "Filed"
        r.destinationLabel = filedTo
        r.suggestion = it.decision?.reason
        r.autoFile = false
        r.isReceipt = true
        r.actions = [FileAction(.undo, "Undo")] + (it.status == "trashed" ? [] : [FileAction(.reveal, "Show in Finder")])
        model = r
        showStatus("")
        build()
        restart(6)
        onResize?()
    }

    @objc func close() {
        guard !closing else { return }
        closing = true
        ticker?.invalidate()
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.15; panel.animator().alphaValue = 0 }) {
            self.panel.orderOut(nil)
            self.onClose?(self)
        }
    }

    // MARK: Actions

    @objc func buttonClicked(_ sender: NSButton) {
        guard sender.tag < model.actions.count else { return }
        trigger(model.actions[sender.tag])
    }

    @objc func menuPicked(_ sender: NSMenuItem) {
        guard sender.tag < model.actions.count else { return }
        trigger(model.actions[sender.tag])
    }

    func trigger(_ a: FileAction) {
        if let warning = a.confirm {
            paused = true
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "\(a.title.replacingOccurrences(of: "…", with: "")) \(model.name)?"
            alert.informativeText = warning + "\n\n" + model.trust.summary
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: a.title.replacingOccurrences(of: "…", with: ""))
            let ok = alert.runModal() == .alertSecondButtonReturn
            paused = false
            guard ok else { return }
        }
        if a.kind == .dismiss { return close() }
        do {
            if a.kind == .fileNow, let id = model.itemId {
                model.autoFile = false
                becomeReceipt(try engine.fileNow(id))
                return
            }
            let msg = try Performer.perform(a, model, engine: engine)
            Log.info("toast: \(a.kind.rawValue) \(model.name)")
            let ends: Set<FileAction.Kind> = [.keep, .undo, .moveToSensitive, .moveToApplications, .unzip, .importTo1Password,
                                              .addRule, .declineRule, .undoAll, .cleanSpace]
            if ends.contains(a.kind) {
                model.autoFile = false
                state.model = model
                state.enabled = false
                showStatus(msg ?? "Done")
                restart(2.5)
            } else {
                // Looking at it (Preview, Copy, Open…) buys a fresh countdown.
                if let msg { showStatus(msg) }
                restart(seconds)
            }
        } catch {
            showStatus("\(error)", error: true)
            restart(max(remaining, 6))
        }
    }

    // MARK: Snapshot

    static func symbol(for kind: FileAction.Kind) -> String? {
        switch kind {
        case .open, .openInEditor: return "arrow.up.forward.app"
        case .preview: return "eye"
        case .reveal: return "folder"
        case .copyImage: return "doc.on.doc"
        case .keep: return "pin"
        case .fileNow, .moveToSensitive: return "tray.and.arrow.down"
        case .askAI: return "sparkles"
        case .unzip: return "archivebox"
        case .importTo1Password, .openPasswordManager: return "key"
        case .runInTerminal: return "terminal"
        case .viewSource: return "chevron.left.forwardslash.chevron.right"
        case .undo, .undoAll: return "arrow.uturn.backward"
        case .installFont: return "textformat"
        case .addToCalendar: return "calendar.badge.plus"
        case .addContact: return "person.crop.circle.badge.plus"
        default: return nil
        }
    }

    /// Render a toast to PNG without showing it (for checking layouts).
    /// `dark` nil follows the Mac's light/dark setting.
    static func snapshot(_ m: ToastModel, to url: URL, dark: Bool? = nil, progress: Double = 0.6, status text: String? = nil) throws {
        if let dark { NSApplication.shared.appearance = NSAppearance(named: dark ? .darkAqua : .aqua) }
        let state = ToastState(model: m)
        state.progress = progress
        state.status = text ?? (m.autoFile ? "files in 12s" : "")
        let view = NSHostingView(rootView: ToastCard(state: state, live: false))
        view.appearance = NSApplication.shared.effectiveAppearance
        view.setFrameSize(view.fittingSize)
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw LandfallError.action("render failed") }
        NSApplication.shared.effectiveAppearance.performAsCurrentDrawingAppearance {
            view.cacheDisplay(in: view.bounds, to: rep)
        }
        guard let png = rep.representation(using: .png, properties: [:]) else { throw LandfallError.action("encode failed") }
        try png.write(to: url)
    }
}

/// Quick Look thumbnails, falling back to the Finder icon.
enum Thumbnail {
    static func load(_ url: URL, size: CGFloat, _ done: @escaping (NSImage?) -> Void) {
        let req = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: size, height: size),
                                               scale: NSScreen.main?.backingScaleFactor ?? 2, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { rep, _ in
            DispatchQueue.main.async { done(rep?.nsImage) }
        }
    }
}

// MARK: - Stacking and bursts

/// Stacks toasts centered under the menu bar; a burst of arrivals becomes one summary toast.
final class Toaster {
    let engine: Engine
    var toasts: [Toast] = []
    private var queue: [ToastModel] = []
    private var flushScheduled = false
    var onSummaryClick: (() -> Void)?
    static let maxVisible = 4

    init(engine: Engine) { self.engine = engine }

    func enqueue(_ m: ToastModel) {
        queue.append(m)
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.flush() }
    }

    private func flush() {
        flushScheduled = false
        let batch = queue
        queue = []
        let receipts = batch.filter(\.isReceipt)
        let others = batch.filter { !$0.isReceipt }
        if receipts.count > 3 { show(receiptSummary(receipts)) } else { receipts.forEach(show) }
        if others.count > 3 { show(summary(others)) } else { others.forEach(show) }
    }

    func show(_ m: ToastModel) {
        Log.info("toast shown: \(m.name) [\(m.kind.rawValue), \(m.trust.level.rawValue)] actions: \(m.actions.map(\.title).joined(separator: ", "))")
        if toasts.count >= Self.maxVisible { toasts.first?.close() }
        let seconds = m.autoFile ? engine.config.autoFileSeconds : engine.config.toastSeconds
        let t = Toast(model: m, engine: engine, seconds: max(3, seconds))
        t.onResize = { [weak self] in self?.layout() }
        t.onClose = { [weak self] closed in
            self?.toasts.removeAll { $0 === closed }
            self?.layout()
        }
        toasts.append(t)
        t.show(at: origin(for: toasts.count - 1, height: t.height))
        layout()
    }

    /// The display the pointer is on; toasts hang centered just under its menu bar.
    private var screenFrame: NSRect {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens.first
        return screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    }

    private func origin(for index: Int, height: CGFloat) -> NSPoint {
        let screen = screenFrame
        var y = screen.maxY - 16
        for t in toasts.prefix(index) { y -= t.height + 10 }
        let w = index < toasts.count ? toasts[index].panel.frame.width : Toast.width
        return NSPoint(x: (screen.midX - w / 2).rounded(), y: max(screen.minY + 12, y - height))
    }

    private func layout() {
        for (i, t) in toasts.enumerated() { t.move(to: origin(for: i, height: t.height)) }
    }

    private func receiptSummary(_ batch: [ToastModel]) -> ToastModel {
        let trashed = batch.filter { $0.subtitle == "Moved to Trash" }.count
        var m = ToastModel(itemId: nil, url: batch[0].url, name: "Landfall tidied \(batch.count) items",
                           kind: .folder, subtitle: "\(batch.count - trashed) filed · \(trashed) moved to Trash",
                           trust: TrustInfo(), suggestion: batch.prefix(3).map(\.name).joined(separator: ", ") + (batch.count > 3 ? "…" : ""),
                           actions: [FileAction(.undoAll, "Undo all")], decision: nil, editor: nil)
        m.relatedIds = batch.compactMap(\.itemId)
        return m
    }

    private func summary(_ batch: [ToastModel]) -> ToastModel {
        let kinds = Dictionary(grouping: batch, by: { $0.kind.label }).map { "\($0.value.count) \($0.key.lowercased())" }
        let risky = batch.filter { $0.trust.level != .trusted }.count
        var trust = TrustInfo()
        trust.level = risky > 0 ? .caution : .trusted
        trust.notes = [risky > 0 ? "\(risky) need care" : "nothing risky"]
        let folder = batch[0].url.deletingLastPathComponent()
        return ToastModel(itemId: nil, url: folder, name: "\(batch.count) items landed in \(folder.lastPathComponent)",
                          kind: .folder, subtitle: kinds.joined(separator: " · "), trust: trust,
                          suggestion: "Open the Landfall menu to review them one by one",
                          actions: [FileAction(.reveal, "Show in Finder")], decision: nil, editor: nil)
    }
}
