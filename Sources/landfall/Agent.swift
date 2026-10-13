import AppKit
import EventKit
import LandfallCore
import ServiceManagement
import UserNotifications

/// The long-running side: watcher, timers, menu bar, toasts, notifications, URL scheme.
final class Agent: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    static var shared: Agent!

    let engine: Engine
    let menubar: Bool
    var watcher: Watcher?
    var bar: MenuBarController?
    var toaster: Toaster?
    var settings: SettingsWindowController?
    let calendar = CalendarProvider()
    var timers: [DispatchSourceTimer] = []
    var configStamp: Date?
    var lastDigestDay = ""

    var inBundle: Bool { Bundle.main.bundleIdentifier != nil }

    init(engine: Engine, menubar: Bool) {
        self.engine = engine
        self.menubar = menubar
    }

    static func start(menubar: Bool, catalog: Bool) -> Never {
        Log.echo = isatty(2) != 0
        let e = makeEngine()
        let agent = Agent(engine: e, menubar: menubar)
        shared = agent
        agent.boot(catalog: catalog)
        if menubar {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            app.delegate = agent
            app.run()
        } else {
            dispatchMain()
        }
        exit(0)
    }

    func boot(catalog: Bool) {
        let e = engine
        if e.config.useCalendar { e.meetingProvider = calendar }
        watcher = Watcher(paths: e.config.roots.map { $0.url.path }) { e.handle(paths: $0) }
        watcher?.start()
        if catalog { e.catalog() }
        e.reconcile()
        e.refreshShelf()
        if e.ledger.meta("indexed") == nil { e.reindex(async: true) { Log.info("indexed \($0) items for search") } }
        Log.info("watching \(e.config.roots.map { Paths.pretty($0.url.path) }.joined(separator: ", ")) in \(e.config.mode.rawValue) mode")

        every(5) { e.tick() }
        every(900) { e.reconcile() }
        every(3600) { [weak self] in
            e.recheckHeld()
            e.expireStale()
            self?.weeklySpaceReport()
        }
        configStamp = stamp()
        every(10) { [weak self] in self?.reloadConfigIfChanged() }
        every(600) { [weak self] in self?.dailyDigest() }
    }

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        Updater.shared.start()
        bar = MenuBarController(engine: engine)
        let toaster = Toaster(engine: engine)
        self.toaster = toaster
        let e = engine

        e.onSettled = { id, url, _ in
            guard e.config.toasts else { return }
            // With Smart Filing on, read the file first so the toast shows Claude's pick.
            if e.smartFilingReady, var f = Inspector.full(url) {
                e.enrich(&f)
                if let rules = e.locate(url.path).map({ Classifier(config: e.config).classify(f, root: $0.root) }),
                   e.smartFilingApplies(f, rules) {
                    Task { @MainActor in
                        _ = await e.smartFile(id, facts: f, rulesDecision: rules)
                        if let m = e.toastModel(for: url, itemId: id, editorLookup: editorInstalled) { toaster.enqueue(m) }
                    }
                    return
                }
            }
            if let m = e.toastModel(for: url, itemId: id, editorLookup: editorInstalled) { toaster.enqueue(m) }
        }
        e.onAutoAction = { it in
            guard e.config.toasts else { return }
            toaster.enqueue(receiptToast(it))
        }
        e.onAISuggestion = { it in toaster.enqueue(aiToast(it, engine: e)) }
        e.onRuleProposal = { p in toaster.enqueue(ruleToast(p)) }

        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURL(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass),
                                                     andEventID: AEEventID(kAEGetURL))
        if inBundle {
            UNUserNotificationCenter.current().delegate = self
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
            notifyHandler = { title, body in
                let content = UNMutableNotificationContent()
                content.title = title
                content.body = body
                UNUserNotificationCenter.current()
                    .add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
            }
            firstRunSetup()
        }
    }

    /// Show notifications even while a Landfall toast is up.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return true
    }

    /// First launch from the bundle: register as a login item and retire the old LaunchAgent.
    func firstRunSetup() {
        guard engine.ledger.meta("first-run") == nil else { return }
        engine.ledger.setMeta("first-run", formatDate(Date(), "yyyy-MM-dd"))
        if SMAppService.mainApp.status != .enabled { try? SMAppService.mainApp.register() }
        if engine.config.useCalendar { calendar.requestAccess { _ in } }
        openSettings()
    }

    // MARK: - URL scheme: landfall://settings, scan, review, toast?path=, file?path=, ask?path=

    @objc func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let s = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let comps = URLComponents(string: s) else { return }
        let path = comps.queryItems?.first { $0.name == "path" }?.value.map { normalize($0) }
        let e = engine
        switch comps.host ?? "" {
        case "settings": openSettings()
        case "scan": e.scanNow()
        case "space": weeklySpaceReport(force: true)
        case "review": bar?.statusItem.button?.performClick(nil)
        case "toast":
            if let path, let m = e.toastModel(for: URL(fileURLWithPath: path), itemId: e.ledger.activeItem(atPath: path)?.id,
                                              editorLookup: editorInstalled) {
                toaster?.show(m)
            }
        case "file":
            if let path {
                e.observe(URL(fileURLWithPath: path))
                if let id = e.ledger.activeItem(atPath: path)?.id { _ = try? e.fileNow(id) }
            }
        case "ask":
            if let path {
                e.observe(URL(fileURLWithPath: path))
                if let id = e.ledger.activeItem(atPath: path)?.id { Task { _ = try? await e.askAI(id) } }
            }
        default: Log.warn("unknown URL \(s)")
        }
    }

    // MARK: - Windows

    func openSettings() {
        if settings == nil { settings = SettingsWindowController(engine: engine, agent: self) }
        NSApp.activate(ignoringOtherApps: true)
        settings?.showWindow(nil)
        settings?.window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Timers

    func every(_ seconds: Double, _ f: @escaping () -> Void) {
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + seconds, repeating: seconds)
        t.setEventHandler(handler: f)
        t.resume()
        timers.append(t)
    }

    func stamp() -> Date? {
        (try? Paths.configURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    func reloadConfigIfChanged() {
        let s = stamp()
        guard s != configStamp else { return }
        configStamp = s
        applyConfig()
    }

    /// Reload config.json and react to what changed.
    func applyConfig() {
        do {
            let before = engine.config
            engine.reload(try Config.load())
            engine.meetingProvider = engine.config.useCalendar ? calendar : nil
            if before.roots != engine.config.roots {
                watcher?.stop()
                watcher = Watcher(paths: engine.config.roots.map { $0.url.path }) { [engine] in engine.handle(paths: $0) }
                watcher?.start()
            }
            Log.info("config reloaded (mode: \(engine.config.mode.rawValue))")
            if before.mode != engine.config.mode { engine.scanNow(recheck: true) }
            engine.onChange?()
        } catch {
            Log.error("\(error)")
            notify("Landfall config error", "\(error)")
        }
    }

    func dailyDigest() {
        let now = Date()
        let day = formatDate(now, "yyyy-MM-dd")
        guard engine.config.notify, Calendar.current.component(.hour, from: now) >= 17, day != lastDigestDay else { return }
        lastDigestDay = day
        let text = Report.digest(engine.ledger, config: engine.config, since: Calendar.current.startOfDay(for: now))
        if !text.hasPrefix("Nothing") { notify("Landfall · today", text) }
    }

    /// Monday from 9am, once a week: what could be reclaimed.
    func weeklySpaceReport(force: Bool = false) {
        let now = Date()
        let cal = Calendar.current
        let week = "\(cal.component(.yearForWeekOfYear, from: now))-\(cal.component(.weekOfYear, from: now))"
        if !force {
            guard engine.config.spaceReport, cal.component(.weekday, from: now) == 2, cal.component(.hour, from: now) >= 9,
                  engine.ledger.meta("space-week") != week else { return }
        }
        engine.ledger.setMeta("space-week", week)
        let roots = engine.config.spaceRoots.map { URL(fileURLWithPath: normalize($0)) }
        let idle = engine.config.spaceIdleDays
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let hits = Space.scan(roots).filter { $0.bytes > 1 << 20 }
            DispatchQueue.main.async { self?.showSpaceReport(hits, idle: idle) }
        }
    }

    func showSpaceReport(_ hits: [SpaceHit], idle: Double) {
        let total = hits.reduce(0) { $0 + $1.bytes }
        let eligible = hits.filter { !$0.reportOnly && ($0.idleDays ?? .infinity) >= idle }
        let reclaim = eligible.reduce(0) { $0 + $1.bytes }
        let report = Paths.logURL.deletingLastPathComponent().appendingPathComponent("space-report.txt")
        let lines = ["Landfall space report — \(formatDate(Date(), "yyyy-MM-dd HH:mm"))",
                     "\(formatBytes(total)) rebuildable · \(formatBytes(reclaim)) in projects idle ≥ \(Int(idle))d", ""]
            + hits.map { h in
                "\(formatBytes(h.bytes).padding(toLength: 10, withPad: " ", startingAt: 0)) \(h.kind.padding(toLength: 16, withPad: " ", startingAt: 0)) "
                    + "\((h.idleDays.map { "idle \(Int($0))d" } ?? "no git").padding(toLength: 10, withPad: " ", startingAt: 0)) \(Paths.pretty(h.path))"
                    + (h.reportOnly ? "  (report only)" : "")
            }
        try? lines.joined(separator: "\n").write(to: report, atomically: true, encoding: .utf8)
        guard total > 1 << 30 else { return }
        let biggest = hits.first.map { " — biggest: \(Paths.pretty($0.path)) (\(formatBytes($0.bytes)))" } ?? ""
        var trust = TrustInfo()
        trust.notes = ["\(eligible.count) folders in idle projects"]
        var actions: [FileAction] = []
        if reclaim > 0 {
            actions.append(FileAction(.cleanSpace, "Clean idle (\(formatBytes(reclaim)))",
                                      confirm: "Moves \(eligible.count) rebuildable folders (node_modules, .venv, .next, .turbo, cargo target) from projects untouched for \(Int(idle))+ days to the Trash. Rebuild them with your package manager when you return to a project."))
        }
        actions.append(FileAction(.showReport, "Show report"))
        var m = ToastModel(itemId: nil, url: report, name: "\(formatBytes(total)) reclaimable in Dev",
                           kind: .folder, subtitle: "Weekly space report" + biggest, trust: trust,
                           suggestion: nil, actions: actions, decision: nil, editor: nil)
        m.paths = eligible.map(\.path)
        toaster?.show(m)
    }
}

// MARK: - Calendar

final class CalendarProvider: MeetingProvider {
    let store = EKEventStore()

    var authorized: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }

    func requestAccess(_ done: @escaping (Bool) -> Void) {
        store.requestFullAccessToEvents { ok, _ in DispatchQueue.main.async { done(ok) } }
    }

    /// Events running at `date` (from 10 minutes before they start to 20 minutes after they end).
    func meetings(around date: Date) -> [Meeting] {
        guard authorized else { return [] }
        let pred = store.predicateForEvents(withStart: date.addingTimeInterval(-6 * 3600),
                                            end: date.addingTimeInterval(3600), calendars: nil)
        return store.events(matching: pred)
            .filter { !$0.isAllDay && $0.startDate.addingTimeInterval(-600) <= date && date <= $0.endDate.addingTimeInterval(1200) }
            .map { ev in
                let people = (ev.attendees ?? []).flatMap { p -> [String] in
                    var out: [String] = []
                    if let n = p.name { out.append(n) }
                    if p.url.scheme == "mailto" { out.append(p.url.absoluteString.replacingOccurrences(of: "mailto:", with: "")) }
                    return out
                }
                return Meeting(title: ev.title ?? "", attendees: people)
            }
    }
}

// MARK: - Toast builders

/// "Filed X → Y" with Undo, after Landfall acts on its own.
func receiptToast(_ it: Item) -> ToastModel {
    let url = URL(fileURLWithPath: it.path)
    let trashed = it.status == "trashed"
    let kind = Inspector.quick(url).map { FileKind.detect($0, decision: it.decision) } ?? .other
    var actions = [FileAction(.undo, "Undo")]
    if !trashed { actions += [FileAction(.open, "Open"), FileAction(.reveal, "Show in Finder")] }
    var m = ToastModel(itemId: it.id, url: url, name: it.name, kind: kind,
                       subtitle: trashed ? "Moved to Trash" : "Filed to \(Paths.pretty((it.path as NSString).deletingLastPathComponent))",
                       trust: TrustInfo(), suggestion: it.decision?.reason, actions: actions,
                       decision: it.decision, editor: nil)
    m.isReceipt = true
    return m
}

func aiToast(_ it: Item, engine: Engine) -> ToastModel {
    let d = it.decision
    let dest = d?.destination.map { Paths.pretty($0) } ?? "?"
    var trust = TrustInfo()
    trust.notes = ["suggestion — nothing moved yet"]
    return ToastModel(itemId: it.id, url: URL(fileURLWithPath: it.path), name: it.name,
                      kind: Inspector.quick(URL(fileURLWithPath: it.path)).map { FileKind.detect($0, decision: d) } ?? .other,
                      subtitle: "Claude suggests \(dest)" + (d?.newName.map { " as “\($0)”" } ?? ""),
                      trust: trust, suggestion: d?.reason,
                      actions: [FileAction(.fileNow, "File there"), FileAction(.keep, "Keep here"), FileAction(.reveal, "Show in Finder")],
                      decision: d, editor: nil)
}

func ruleToast(_ p: RuleLearner.Proposal) -> ToastModel {
    var m = ToastModel(itemId: nil, url: Paths.configURL, name: "Make this a rule?", kind: .other,
                       subtitle: p.summary, trust: TrustInfo(),
                       suggestion: "Always file these to \(p.rule.to ?? "?")",
                       actions: [FileAction(.addRule, "Add rule"), FileAction(.dismiss, "Not now"), FileAction(.declineRule, "Never")],
                       decision: nil, editor: nil)
    m.proposal = p
    return m
}

func editorInstalled(_ bundleId: String) -> Bool {
    NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) != nil
}
