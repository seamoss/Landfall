import AppKit
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
            for p in m.paths where (try? Mover.trash(URL(fileURLWithPath: p))) != nil { freed += 1 }
            return "Moved \(freed) folders to the Trash"
        case .showReport:
            run("/usr/bin/open", ["-t", url.path])
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
    private let status = NSTextField(labelWithString: "")
    private let bar = CountdownBar()
    private var buttons: [NSControl] = []

    static let width: CGFloat = 380

    init(model: ToastModel, engine: Engine, seconds: Double) {
        self.model = model
        self.engine = engine
        self.seconds = seconds
        remaining = seconds
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
        buttons = []
        let content = Toast.makeView(model, target: self, status: status, bar: bar, buttons: &buttons, live: true) { [weak self] inside in
            self?.paused = inside
            self?.updateStatus()
        }
        let top = panel.frame.maxY
        panel.contentView = content
        let size = NSSize(width: Toast.width, height: content.fittingSize.height)
        panel.setFrame(NSRect(x: panel.frame.minX, y: top - size.height, width: size.width, height: size.height), display: true)
        updateStatus()
    }

    func show(at origin: NSPoint) {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        panel.setFrameOrigin(reduceMotion ? origin : NSPoint(x: origin.x + 40, y: origin.y))
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
        bar.progress = max(0, remaining / seconds)
        updateStatus()
        if remaining <= 0 { timedOut() }
    }

    private func updateStatus() {
        bar.progress = max(0, remaining / seconds)
        bar.tint = model.autoFile ? .controlAccentColor : .tertiaryLabelColor
        guard model.autoFile else { return }
        status.textColor = .secondaryLabelColor
        status.stringValue = paused ? "Paused — move away to continue" : "Files in \(max(1, Int(remaining.rounded(.up))))s"
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
            status.stringValue = "\(error)"
            status.textColor = .systemRed
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
                buttons.forEach { $0.isEnabled = false }
                status.stringValue = msg ?? "Done"
                status.textColor = .secondaryLabelColor
                restart(2.5)
            } else {
                // Looking at it (Preview, Copy, Open…) buys a fresh countdown.
                if let msg { status.stringValue = msg }
                restart(seconds)
            }
        } catch {
            status.stringValue = "\(error)"
            status.textColor = .systemRed
            restart(max(remaining, 6))
        }
    }

    // MARK: Layout

    static let cornerRadius: CGFloat = 20

    static func makeView(_ m: ToastModel, target: Toast?, status: NSTextField, bar: CountdownBar,
                         buttons: inout [NSControl], live: Bool, onHover: ((Bool) -> Void)? = nil) -> NSView {
        // Everything is laid out in `content`; the outer view supplies the material.
        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false

        // Thumbnail (file icon until Quick Look has one).
        let thumb = NSImageView(image: NSWorkspace.shared.icon(forFile: m.url.path))
        thumb.imageScaling = .scaleProportionallyUpOrDown
        thumb.wantsLayer = true
        thumb.layer?.cornerRadius = 8
        thumb.layer?.cornerCurve = .continuous
        thumb.layer?.masksToBounds = true
        thumb.translatesAutoresizingMaskIntoConstraints = false
        thumb.widthAnchor.constraint(equalToConstant: 44).isActive = true
        thumb.heightAnchor.constraint(equalToConstant: 44).isActive = true
        thumb.setAccessibilityElement(false)
        Thumbnail.load(m.url, size: 88) { if let img = $0 { thumb.image = img } }

        let title = NSTextField(labelWithString: m.name)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.lineBreakMode = .byTruncatingMiddle
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        var lines: [NSView] = [title, label(m.subtitle, .secondaryLabelColor)]
        // Trust only when it says something: caution, danger, or a signature.
        if m.trust.level != .trusted || m.trust.signer != nil {
            let symbol = m.trust.level == .trusted ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"
            lines.append(symbolLabel(symbol, m.trust.summary,
                                     m.trust.level == .trusted ? .secondaryLabelColor : trustColor(m.trust.level)))
        }
        if let dest = m.destinationLabel {
            let d = symbolLabel(m.isReceipt ? "checkmark.circle.fill" : "arrow.turn.down.right", dest, .labelColor,
                                weight: .medium, symbolColor: m.isReceipt ? .systemGreen : .secondaryLabelColor)
            d.toolTip = m.suggestion
            lines.append(d)
        } else if let s = m.suggestion {
            lines.append(label(s, .labelColor, lines: 2))
        }
        let text = NSStackView(views: lines)
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let header = NSStackView(views: [thumb, text])
        header.alignment = .top
        header.spacing = 10

        // Three buttons at most; everything else lives under ⋯.
        var row: [NSView] = []
        let visibleCount = m.actions.count > 3 ? 3 : m.actions.count
        for (i, a) in m.actions.prefix(visibleCount).enumerated() {
            let b: NSButton
            if i == 0 {
                // The primary action stays in accent color even though toasts never become the key window.
                b = PrimaryButton(title: a.title, fill: a.confirm == nil ? .controlAccentColor : .systemOrange,
                                  target: target, action: #selector(Toast.buttonClicked(_:)))
            } else {
                b = NSButton(title: a.title, target: target, action: #selector(Toast.buttonClicked(_:)))
                styleSecondary(b)
                if a.confirm != nil { b.contentTintColor = .systemOrange }
            }
            b.tag = i
            buttons.append(b)
            row.append(b)
        }
        if m.actions.count > visibleCount {
            let more = NSPopUpButton(frame: .zero, pullsDown: true)
            styleSecondary(more)
            (more.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
            more.setAccessibilityLabel("More actions")
            let head = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            head.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "More")
            more.menu?.addItem(head)
            for (i, a) in m.actions.enumerated().dropFirst(visibleCount) {
                let item = NSMenuItem(title: a.title, action: #selector(Toast.menuPicked(_:)), keyEquivalent: "")
                item.target = target
                item.tag = i
                item.image = symbol(for: a.kind).flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
                more.menu?.addItem(item)
            }
            buttons.append(more)
            row.append(more)
        }
        let buttonRow = NSStackView(views: row)
        buttonRow.spacing = 8

        status.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        let footer = NSStackView(views: [buttonRow, NSView(), status])
        footer.alignment = .centerY
        footer.distribution = .fill

        let stack = NSStackView(views: [header, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 20, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false

        // ✕ sits in the corner, outside the layout, so it never pushes the text around.
        let close = closeButton(target: target)
        close.translatesAutoresizingMaskIntoConstraints = false
        bar.translatesAutoresizingMaskIntoConstraints = false

        if let onHover {
            let hover = HoverView(frame: .zero)
            hover.onHover = onHover
            hover.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(hover)
            NSLayoutConstraint.activate([
                hover.leadingAnchor.constraint(equalTo: content.leadingAnchor), hover.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                hover.topAnchor.constraint(equalTo: content.topAnchor), hover.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            ])
        }
        content.addSubview(stack)
        content.addSubview(bar)
        content.addSubview(close)
        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(equalToConstant: width),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28 - 16),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
            close.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
            close.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
            // Countdown: an inset capsule under the buttons, clear of the rounded corners.
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            bar.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8),
            bar.heightAnchor.constraint(equalToConstant: 3),
        ])

        let tintBorder = m.trust.level == .trusted ? nil : trustColor(m.trust.level).withAlphaComponent(0.7)
        let outer = wrap(content, live: live, border: tintBorder)
        // The glass view must not grow past the content's width (it would hang off-screen).
        outer.translatesAutoresizingMaskIntoConstraints = false
        outer.widthAnchor.constraint(equalToConstant: width).isActive = true
        return outer
    }

    /// Liquid Glass on macOS 26; vibrant material before; solid when Reduce Transparency is on.
    static func wrap(_ content: NSView, live: Bool, border: NSColor?) -> NSView {
        let solid = !live || NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        let outer: NSView
        if !solid, #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = cornerRadius
            glass.contentView = content
            outer = glass
        } else {
            let base: NSView
            if solid {
                base = NSView()
                base.wantsLayer = true
                base.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            } else {
                let fx = NSVisualEffectView()
                fx.material = .popover
                fx.state = .active
                fx.blendingMode = .behindWindow
                base = fx
            }
            base.wantsLayer = true
            base.layer?.cornerRadius = cornerRadius
            base.layer?.cornerCurve = .continuous
            base.layer?.masksToBounds = true
            base.addSubview(content)
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: base.leadingAnchor), content.trailingAnchor.constraint(equalTo: base.trailingAnchor),
                content.topAnchor.constraint(equalTo: base.topAnchor), content.bottomAnchor.constraint(equalTo: base.bottomAnchor),
            ])
            outer = base
        }
        outer.wantsLayer = true
        if let border {
            outer.layer?.cornerRadius = cornerRadius
            outer.layer?.cornerCurve = .continuous
            outer.layer?.borderWidth = 1.5
            outer.layer?.borderColor = border.cgColor
        } else if solid || NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast {
            outer.layer?.borderWidth = 1
            outer.layer?.borderColor = NSColor.separatorColor.cgColor
        }
        return outer
    }

    /// Glass capsules on macOS 26, rounded bezels before.
    static func styleSecondary(_ b: NSButton) {
        b.controlSize = .regular
        b.font = .systemFont(ofSize: 12)
        if #available(macOS 26.0, *) {
            b.bezelStyle = .glass
            b.borderShape = .capsule
        } else {
            b.bezelStyle = .rounded
        }
    }

    static func closeButton(target: Toast?) -> NSButton {
        let image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")!
        let b = NSButton(image: image, target: target, action: #selector(Toast.close))
        b.setAccessibilityLabel("Close")
        if #available(macOS 26.0, *) {
            b.bezelStyle = .glass
            b.borderShape = .circle
            b.controlSize = .mini
            b.symbolConfiguration = .init(pointSize: 8, weight: .bold)
        } else {
            b.isBordered = false
            b.contentTintColor = .tertiaryLabelColor
            b.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
            b.widthAnchor.constraint(equalToConstant: 16).isActive = true
            b.heightAnchor.constraint(equalToConstant: 16).isActive = true
        }
        return b
    }

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

    /// An SF Symbol followed by text, on one line.
    static func symbolLabel(_ symbol: String, _ text: String, _ color: NSColor, weight: NSFont.Weight = .regular,
                            symbolColor: NSColor? = nil) -> NSTextField {
        let font = NSFont.systemFont(ofSize: weight == .regular ? 11 : 12, weight: weight)
        let attachment = NSTextAttachment()
        let config = NSImage.SymbolConfiguration(pointSize: font.pointSize - 1, weight: .semibold)
            .applying(.init(paletteColors: [symbolColor ?? color]))
        attachment.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        let s = NSMutableAttributedString(attachment: attachment)
        s.append(NSAttributedString(string: "  " + text, attributes: [.font: font, .foregroundColor: color]))
        let l = NSTextField(labelWithAttributedString: s)
        l.lineBreakMode = .byTruncatingTail
        l.maximumNumberOfLines = 1
        l.preferredMaxLayoutWidth = textWidth
        l.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return l
    }

    static let textWidth: CGFloat = width - 28 - 44 - 10 - 16

    static func label(_ s: String, _ color: NSColor, lines: Int = 1) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: s)
        l.font = .systemFont(ofSize: 11)
        l.textColor = color
        l.maximumNumberOfLines = lines
        l.lineBreakMode = lines == 1 ? .byTruncatingTail : .byWordWrapping
        l.cell?.truncatesLastVisibleLine = true
        l.preferredMaxLayoutWidth = textWidth
        return l
    }

    static func trustColor(_ l: TrustInfo.Level) -> NSColor {
        switch l {
        case .trusted: return .systemGreen
        case .caution: return .systemOrange
        case .danger: return .systemRed
        }
    }

    /// Render a toast to PNG without showing it (for checking layouts).
    static func snapshot(_ m: ToastModel, to url: URL, dark: Bool, progress: Double = 0.6, status text: String? = nil) throws {
        NSApplication.shared.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        var unused: [NSControl] = []
        let status = NSTextField(labelWithString: text ?? (m.autoFile ? "Files in 12s" : ""))
        let bar = CountdownBar()
        bar.progress = progress
        bar.tint = m.autoFile ? .controlAccentColor : .tertiaryLabelColor
        let view = makeView(m, target: nil, status: status, bar: bar, buttons: &unused, live: false)
        view.appearance = NSApplication.shared.appearance
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))  // let the thumbnail arrive
        view.setFrameSize(view.fittingSize)
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw LandfallError.action("render failed") }
        NSApplication.shared.appearance?.performAsCurrentDrawingAppearance {
            view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            view.cacheDisplay(in: view.bounds, to: rep)
        }
        guard let png = rep.representation(using: .png, properties: [:]) else { throw LandfallError.action("encode failed") }
        try png.write(to: url)
    }
}

/// A filled, always-accent button: the system draws default buttons grey in non-key windows like toasts.
final class PrimaryButton: NSButton {
    private let fill: NSColor

    init(title: String, fill: NSColor, target: AnyObject?, action: Selector) {
        self.fill = fill
        super.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
        isBordered = false
        focusRingType = .none
        wantsLayer = true
        layer?.cornerCurve = .continuous
        attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: NSColor.white,
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
        ])
        updateLayer()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Same height as the neighboring system buttons (glass capsules on macOS 26).
    static let height: CGFloat = {
        let probe = NSButton(title: "Keep", target: nil, action: nil)
        Toast.styleSecondary(probe)
        return max(22, probe.intrinsicContentSize.height)
    }()

    override var intrinsicContentSize: NSSize {
        let text = attributedTitle.size()
        return NSSize(width: ceil(text.width) + 28, height: Self.height)
    }

    override func layout() {
        super.layout()
        if #available(macOS 26.0, *) {
            layer?.cornerRadius = bounds.height / 2  // capsule, like Tahoe's buttons
        } else {
            layer?.cornerRadius = 6
        }
    }

    override var isEnabled: Bool { didSet { needsDisplay = true } }
    override var isHighlighted: Bool { didSet { needsDisplay = true } }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            var color = fill.usingColorSpace(.deviceRGB) ?? fill
            if isHighlighted { color = color.blended(withFraction: 0.18, of: .black) ?? color }
            layer?.backgroundColor = color.withAlphaComponent(isEnabled ? 1 : 0.45).cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

/// A thin draining bar along the bottom edge.
final class CountdownBar: NSView {
    private let fill = CALayer()
    var progress: Double = 1 { didSet { needsLayout = true; layoutFill() } }
    var tint: NSColor = .controlAccentColor { didSet { updateColors() } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(fill)
        layer?.cornerRadius = 1.5
        layer?.masksToBounds = true
        fill.cornerRadius = 1.5
        updateColors()
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        layoutFill()
    }

    override func viewDidChangeEffectiveAppearance() { updateColors() }

    private func layoutFill() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.frame = NSRect(x: 0, y: 0, width: bounds.width * CGFloat(max(0, min(1, progress))), height: bounds.height)
        CATransaction.commit()
    }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.35).cgColor
            fill.backgroundColor = tint.withAlphaComponent(0.9).cgColor
        }
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

final class HoverView: NSView {
    var onHover: ((Bool) -> Void)?

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }  // never swallow clicks
}

// MARK: - Stacking and bursts

/// Stacks toasts in the top-right corner; a burst of arrivals becomes one summary toast.
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
        let t = Toast(model: m, engine: engine, seconds: engine.config.toastSeconds)
        t.onResize = { [weak self] in self?.layout() }
        t.onClose = { [weak self] closed in
            self?.toasts.removeAll { $0 === closed }
            self?.layout()
        }
        toasts.append(t)
        t.show(at: origin(for: toasts.count - 1, height: t.height))
        layout()
    }

    /// The display the pointer is on (like notifications), inset from the top-right of its usable area.
    private var screenFrame: NSRect {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens.first
        return screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    }

    private func origin(for index: Int, height: CGFloat) -> NSPoint {
        let screen = screenFrame
        var y = screen.maxY - 12
        for t in toasts.prefix(index) { y -= t.height + 10 }
        let w = index < toasts.count ? toasts[index].panel.frame.width : Toast.width
        return NSPoint(x: screen.maxX - min(w, screen.width - 24) - 12, y: max(screen.minY + 12, y - height))
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
