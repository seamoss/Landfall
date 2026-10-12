import Foundation

/// Arrival pipeline: observe → settle → inspect → classify → act → record.
public final class Engine: ClassifierContext {
    public private(set) var config: Config
    public let ledger: Ledger
    public var onChange: (() -> Void)?
    /// A new arrival finished downloading/copying (only for live events, never the startup catalog).
    public var onSettled: ((Int64, URL, RootConfig) -> Void)?
    /// Landfall moved or trashed something on its own (auto mode).
    public var onAutoAction: ((Item) -> Void)?
    public var clock: () -> Date = Date.init
    /// Paths that shouldn't announce themselves (e.g. a folder Landfall just unzipped).
    public var quiet: Set<String> = []
    /// Calendar access (app only).
    public weak var meetingProvider: MeetingProvider?
    /// You've corrected the same kind of filing twice; here's a rule for it.
    public var onRuleProposal: ((RuleLearner.Proposal) -> Void)?
    /// Claude came back with a suggestion for an item.
    public var onAISuggestion: ((Item) -> Void)?

    struct Pending {
        var root: RootConfig
        var itemId: Int64
        var signature: String
        var stableSince: Date
        var firstSeen: Date
        var announce = false
    }

    var pending: [String: Pending] = [:]

    public init(config: Config, ledger: Ledger) {
        self.config = config
        self.ledger = ledger
    }

    public func reload(_ c: Config) { config = c }

    public var pendingCount: Int { pending.count }

    var classifier: Classifier { Classifier(config: config, context: self, now: clock()) }

    public func existingCopy(ofHash hash: String, excluding path: String) -> String? {
        ledger.items(withHash: hash).first { $0.path != path && !$0.path.contains("/.Trash/") && fileExists($0.path) }?.path
    }

    // MARK: - Locating

    /// Which root a path belongs to, its top-level item, and how deep the path is.
    public func locate(_ rawPath: String) -> (root: RootConfig, top: URL, depth: Int)? {
        let path = normalize(rawPath)
        for r in config.roots {
            let rp = r.url.path
            guard path.hasPrefix(rp + "/") else { continue }
            let rel = path.dropFirst(rp.count + 1).split(separator: "/")
            guard let first = rel.first else { continue }
            return (r, URL(fileURLWithPath: rp).appendingPathComponent(String(first)), rel.count)
        }
        return nil
    }

    /// File-system events in; top-level items out.
    public func handle(paths: [String]) {
        var tops = Set<String>()
        for p in paths {
            guard let loc = locate(p) else { continue }
            if loc.root.role == .library && loc.depth > 1 { continue }
            tops.insert(loc.top.path)
        }
        for t in tops { observe(URL(fileURLWithPath: t), announce: true) }
    }

    /// Register every top-level item in every root (startup and `scan`).
    public func catalog(root name: String? = nil) {
        for r in config.roots where name == nil || r.name == name {
            guard let kids = try? FileManager.default.contentsOfDirectory(at: r.url, includingPropertiesForKeys: nil) else {
                Log.warn("can't read \(r.path) — grant Landfall access in System Settings › Privacy & Security › Files and Folders")
                continue
            }
            for k in kids { observe(k) }
        }
    }

    // MARK: - Arrivals

    public func observe(_ url: URL, announce: Bool = false) {
        let path = normalize(url.path)
        guard let loc = locate(path), pending[path] == nil else { return }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else {
            departed(path)
            return
        }
        let fileURL = URL(fileURLWithPath: path)
        if classifier.ignoreReason(fileURL, isDir: isDir.boolValue, root: loc.root) != nil { return }
        guard let q = Inspector.quick(fileURL) else { return }
        let now = clock()
        let id: Int64
        var isNew = false

        if let it = ledger.activeItem(atPath: path) {
            guard it.status == "pending" else { return }
            id = it.id
        } else if let prior = ledger.items(withInode: Int64(q.inode)).first(where: { $0.path != path && !fileExists($0.path) }) {
            id = prior.id
            if ["filed", "kept", "elsewhere"].contains(prior.status) {
                // You pulled it back out of the library: respect that.
                ledger.update(id, ["path": path, "root": loc.root.name, "status": "kept", "name": q.name])
                ledger.addEvent(id, "corrected", src: prior.path, dst: path, rule: prior.decision?.rule,
                                reason: "you moved it back to \(loc.root.name) — leaving it there")
                onChange?()
                return
            }
            ledger.update(id, ["path": path, "root": loc.root.name, "status": "pending", "name": q.name])
            ledger.addEvent(id, "relocated", src: prior.path, dst: path, reason: "you moved it to \(loc.root.name)")
        } else {
            id = ledger.insertItem(name: q.name, kind: q.isDir ? "dir" : "file", root: loc.root.name, path: path,
                                   inode: Int64(q.inode), size: q.size, firstSeen: q.added ?? now,
                                   bookmark: Mover.bookmark(path))
            ledger.addEvent(id, "arrived", dst: path, reason: "landed in \(loc.root.name)")
            isNew = true
        }
        let shouldAnnounce = announce && isNew && quiet.remove(path) == nil
        pending[path] = Pending(root: loc.root, itemId: id, signature: signature(q), stableSince: now,
                                firstSeen: q.added ?? now, announce: shouldAnnounce)
        onChange?()
    }

    /// Something left a root. Work out where it went.
    func departed(_ path: String) {
        pending[path] = nil
        guard let it = ledger.activeItem(atPath: path) else { return }
        guard let b = it.bookmark, let now = Mover.resolve(b), now != path else {
            ledger.update(it.id, ["status": "gone"])
            ledger.addEvent(it.id, "gone", src: path, reason: "disappeared")
            return
        }
        if now.contains("/.Trash/") {
            ledger.update(it.id, ["status": "trashed", "path": now])
            ledger.addEvent(it.id, "trashed", src: path, dst: now, reason: "you trashed it")
        } else if locate(now) == nil || (locate(now)!.root.role == .library && locate(now)!.depth > 1) {
            ledger.update(it.id, ["status": "elsewhere", "path": now])
            ledger.addEvent(it.id, "relocated", src: path, dst: now, reason: "you filed it yourself")
        }
        // Otherwise it moved into another root's top level; observe() links it by inode.
        onChange?()
    }

    /// Advance pending items that have settled and outlived their grace period.
    public func tick() {
        let now = clock()
        for (path, e) in pending {
            let url = URL(fileURLWithPath: path)
            guard let q = Inspector.quick(url) else {
                departed(path)
                continue
            }
            let sig = signature(q)
            if sig != e.signature {
                pending[path]?.signature = sig
                pending[path]?.stableSince = now
                continue
            }
            if now.timeIntervalSince(e.stableSince) < config.settleSeconds { continue }
            if e.announce {
                pending[path]?.announce = false
                onSettled?(e.itemId, url, e.root)
                guard pending[path] != nil else { continue }  // acted on from the toast
            }
            var start = e.firstSeen
            if e.root.useLastUsed, let used = Inspector.lastUsed(url), used > start { start = used }
            if now.timeIntervalSince(start) < e.root.graceSeconds { continue }
            pending[path] = nil
            process(itemId: e.itemId, url: url, root: e.root)
        }
    }

    /// Process everything now, ignoring grace periods. Returns what was decided.
    @discardableResult
    public func scanNow(root: String? = nil, recheck: Bool = false) -> [(name: String, decision: Decision, status: String)] {
        catalog(root: root)
        var work: [(Int64, URL, RootConfig)] = pending.compactMap { path, e in
            guard root == nil || e.root.name == root else { return nil }
            return (e.itemId, URL(fileURLWithPath: path), e.root)
        }
        for (path, e) in pending where root == nil || e.root.name == root { _ = e; pending[path] = nil }
        if recheck {
            for it in ledger.items(statuses: ["proposed", "held"]) where fileExists(it.path) {
                guard let loc = locate(it.path), root == nil || loc.root.name == root else { continue }
                work.append((it.id, URL(fileURLWithPath: it.path), loc.root))
            }
        }
        var out: [(String, Decision, String)] = []
        for (id, url, r) in work.sorted(by: { $0.1.lastPathComponent < $1.1.lastPathComponent }) {
            if let d = process(itemId: id, url: url, root: r) {
                out.append((url.lastPathComponent, d, ledger.item(id)?.status ?? "?"))
            }
        }
        return out
    }

    /// Held items get another look once an hour (installers get opened, repos get committed).
    public func recheckHeld() {
        let cutoff = clock().addingTimeInterval(-3600)
        for it in ledger.items(statuses: ["held"]) where it.updated < cutoff && fileExists(it.path) {
            guard let loc = locate(it.path) else { continue }
            process(itemId: it.id, url: URL(fileURLWithPath: it.path), root: loc.root)
        }
    }

    @discardableResult
    func process(itemId: Int64, url: URL, root: RootConfig) -> Decision? {
        guard var f = Inspector.full(url) else {
            departed(normalize(url.path))
            return nil
        }
        enrich(&f, firstSeen: ledger.item(itemId)?.firstSeen)
        ledger.update(itemId, ["hash": f.hash, "size": f.size, "uti": f.uti, "origin": f.origins.first,
                               "inode": Int64(f.inode)])
        let d = classifier.classify(f, root: root)
        indexContent(itemId, f, d)
        decide(itemId, path: normalize(url.path), d)
        if d.rule == "fallback" && config.ai.auto && AIAdvisor.blockReason(f, decision: d) == nil && Keychain.apiKey() != nil {
            Task { @MainActor in _ = try? await self.askAI(itemId) }
        }
        return d
    }

    func decide(_ id: Int64, path: String, _ d: Decision) {
        let name = (path as NSString).lastPathComponent
        let alreadyAlerted = ledger.item(id)?.decision?.flags.contains("alert") == true
        switch d.action {
        case .ignore:
            ledger.update(id, ["status": "ignored", "decision": d.json])
        case .hold:
            let prior = ledger.item(id)
            ledger.update(id, ["status": "held", "decision": d.json])
            if prior?.status != "held" || prior?.decision?.reason != d.reason {
                ledger.addEvent(id, "held", src: path, rule: d.rule, confidence: d.confidence, reason: d.reason)
            }
        case .move, .trash:
            if shouldExecute(d) {
                do {
                    try execute(id, path: path, d)
                    if let it = ledger.item(id) { onAutoAction?(it) }
                } catch {
                    Log.error("couldn't act on \(name): \(error.localizedDescription)")
                    ledger.update(id, ["status": "held", "decision": d.json])
                    ledger.addEvent(id, "error", src: path, rule: d.rule, reason: error.localizedDescription)
                }
            } else {
                let prior = ledger.item(id)
                ledger.update(id, ["status": "proposed", "decision": d.json])
                if prior?.status != "proposed" || prior?.decision != d {
                    ledger.addEvent(id, "proposed", src: path, dst: d.action == .trash ? "Trash" : d.target(for: name),
                                    rule: d.rule, confidence: d.confidence, reason: d.reason)
                    Log.info("proposed \(name): \(d.action.rawValue) [\(d.rule) \(d.confidence)] \(d.reason)")
                }
            }
        }
        if d.flags.contains("alert") && !alreadyAlerted && config.notify {
            notify("Landfall ⚠️ \(name)", d.reason)
        }
        onChange?()
    }

    func shouldExecute(_ d: Decision) -> Bool {
        guard config.mode == .auto else { return false }
        switch d.action {
        case .trash: return d.confidence >= config.trashThreshold
        case .move: return d.confidence >= config.autoThreshold
        default: return false
        }
    }

    // MARK: - Actions

    public func execute(_ id: Int64, path: String, _ d: Decision) throws {
        let src = URL(fileURLWithPath: path)
        switch d.action {
        case .move:
            guard let dir = d.destination else { throw LandfallError.action("no destination") }
            let dst = try Mover.move(src, toDir: URL(fileURLWithPath: dir), name: d.newName)
            let np = normalize(dst.path)
            markCabinet(containing: np)
            ledger.update(id, ["path": np, "status": "filed", "decision": d.json, "bookmark": Mover.bookmark(np),
                               "name": dst.lastPathComponent])
            ledger.addEvent(id, "moved", src: path, dst: np, rule: d.rule, confidence: d.confidence, reason: d.reason,
                            applied: true)
            Log.info("filed \(src.lastPathComponent) → \(Paths.pretty(np)) [\(d.rule)]")
        case .trash:
            let dst = try Mover.trash(src)
            ledger.update(id, ["path": dst.path, "status": "trashed", "decision": d.json])
            ledger.addEvent(id, "trashed", src: path, dst: dst.path, rule: d.rule, confidence: d.confidence,
                            reason: d.reason, applied: true)
            Log.info("trashed \(src.lastPathComponent) [\(d.rule)] \(d.reason)")
        default:
            return
        }
        refreshShelf()
        onChange?()
    }

    /// Carry out a proposal.
    public func apply(_ id: Int64) throws -> Item {
        guard let it = ledger.item(id) else { throw LandfallError.action("no item #\(id)") }
        guard it.status == "proposed" || it.status == "held", let d = it.decision, d.action == .move || d.action == .trash else {
            throw LandfallError.action("#\(id) has nothing to apply (status: \(it.status))")
        }
        guard fileExists(it.path) else { throw LandfallError.action("#\(id) is no longer at \(Paths.pretty(it.path))") }
        try execute(id, path: it.path, d)
        return ledger.item(id)!
    }

    /// Calendar meetings and OCR text — the context a file arrived in.
    public func enrich(_ f: inout ItemFacts, firstSeen: Date? = nil) {
        if config.useCalendar, let provider = meetingProvider {
            let transcriptTime = f.textHead.flatMap(Transcript.parse)?.date
            let when = transcriptTime ?? firstSeen ?? f.added ?? clock()
            f.meetings = provider.meetings(around: when)
        }
        if !f.isDir && Classifier.imageExts.contains(f.ext) && f.ext != "svg" {
            f.ocrText = OCR.text(f.url)
        }
    }

    /// Make it searchable — unless it's private.
    func indexContent(_ id: Int64, _ f: ItemFacts, _ d: Decision) {
        guard !d.flags.contains("sensitive"), !d.flags.contains("noAI"), d.rule != "credential" else {
            ledger.unindex(id)
            return
        }
        let body = [f.title, f.textHead.map { String($0.prefix(16000)) }, f.ocrText].compactMap { $0 }.joined(separator: "\n")
        ledger.index(id, name: f.name, body: body)
    }

    /// Tag the top-level folder an in-place filing landed in, so it's never mistaken for a new arrival.
    func markCabinet(containing path: String) {
        guard let loc = locate(path), loc.depth > 1, loc.root.role != .library else { return }
        let top = loc.top.path
        _ = "1".withCString { setxattr(top, Classifier.cabinetMarker, $0, 1, 0, 0) }
        pending[top] = nil
        if let it = ledger.activeItem(atPath: top), it.status == "pending" { ledger.update(it.id, ["status": "ignored"]) }
    }

    /// Backfill search for items tracked before indexing existed. Text extraction and OCR run off the
    /// main thread; the ledger is only touched on the calling thread.
    public func reindex(async: Bool, done: ((Int) -> Void)? = nil) {
        let items = ledger.items(statuses: ["filed", "kept", "held", "proposed", "elsewhere", "pending"])
            .filter { fileExists($0.path) }
            .filter { d in !(d.decision?.flags.contains("sensitive") ?? false) && !(d.decision?.flags.contains("noAI") ?? false) && d.decision?.rule != "credential" }
            .map { ($0.id, $0.path, $0.name) }
        let work = { () -> [(Int64, String, String)] in
            items.compactMap { id, path, name in
                guard var f = Inspector.full(URL(fileURLWithPath: path), hash: false), !f.isDir else { return nil }
                if Classifier.imageExts.contains(f.ext) && f.ext != "svg" { f.ocrText = OCR.text(f.url) }
                if Classifier(config: self.config).credential(f) != nil { return nil }
                let body = [f.title, f.textHead.map { String($0.prefix(16000)) }, f.ocrText].compactMap { $0 }.joined(separator: "\n")
                return (id, name, body)
            }
        }
        let write = { (rows: [(Int64, String, String)]) in
            for (id, name, body) in rows { self.ledger.index(id, name: name, body: body) }
            self.ledger.setMeta("indexed", "v1")
            done?(rows.count)
        }
        if async {
            DispatchQueue.global(qos: .utility).async {
                let rows = work()
                DispatchQueue.main.async { write(rows) }
            }
        } else {
            write(work())
        }
    }

    /// Ask Claude where something belongs; the answer becomes a proposal you approve.
    @discardableResult
    public func askAI(_ id: Int64) async throws -> Decision {
        guard let it = ledger.item(id), fileExists(it.path) else { throw LandfallError.action("#\(id) isn't where Landfall last saw it") }
        guard var f = Inspector.full(URL(fileURLWithPath: it.path)) else { throw LandfallError.action("can't read \(it.name)") }
        enrich(&f, firstSeen: it.firstSeen)
        var d = try await AIAdvisor.suggest(f, decision: it.decision, config: config)
        if let root = locate(it.path)?.root { d = classifier.localize(d, f, root) }
        await MainActor.run {
            ledger.update(id, ["status": "proposed", "decision": d.json])
            ledger.addEvent(id, "proposed", src: it.path, dst: d.target(for: it.name), rule: d.rule,
                            confidence: d.confidence, reason: d.reason)
            Log.info("ai: \(it.name) → \(d.destination ?? "?") (\(d.confidence))")
            if let fresh = ledger.item(id) { onAISuggestion?(fresh) }
            onChange?()
        }
        return d
    }

    /// Send a credential file to 1Password, then move it to the Trash.
    public func vault(_ id: Int64) throws {
        guard let it = ledger.item(id), fileExists(it.path) else { throw LandfallError.action("#\(id) isn't where Landfall last saw it") }
        try OnePassword.importDocument(URL(fileURLWithPath: it.path), vault: config.onePasswordVault)
        let trashed = try Mover.trash(URL(fileURLWithPath: it.path))
        pending[it.path] = nil
        ledger.update(id, ["status": "trashed", "path": trashed.path])
        ledger.addEvent(id, "trashed", src: it.path, dst: trashed.path, rule: "1password",
                        reason: "imported to 1Password, original moved to Trash", applied: true)
        ledger.unindex(id)
        onChange?()
    }

    /// Downloads nobody filed or opened for `expireDays` go to the Trash (in auto mode; proposed otherwise).
    @discardableResult
    public func expireStale() -> [Int64] {
        var done: [Int64] = []
        let now = clock()
        for r in config.roots {
            guard let days = r.expireDays, days > 0 else { continue }
            let cutoff = now.addingTimeInterval(-days * 86400)
            for it in ledger.items(statuses: ["proposed", "held", "pending"]) where it.root == r.name && it.firstSeen < cutoff {
                let url = URL(fileURLWithPath: it.path)
                guard fileExists(it.path), locate(it.path)?.root.name == r.name else { continue }
                if let used = Inspector.lastUsed(url), used > cutoff { continue }
                pending[it.path] = nil
                let d = Decision(action: .trash, confidence: 0.9, rule: "expired",
                                 reason: "untouched in \(r.name) for \(Int(days)) days")
                decide(it.id, path: it.path, d)
                done.append(it.id)
            }
        }
        return done
    }

    /// Look for a pattern in your corrections that should become a rule.
    func learn(fromCorrectionInto folder: String) {
        let lib = config.libraryURL.path + "/"
        guard folder.hasPrefix(lib) else { return }
        let ids = Set(ledger.events(since: Date(timeIntervalSince1970: 0), types: ["corrected"])
            .filter { ($0.dst as NSString?)?.deletingLastPathComponent == folder }.map(\.itemId))
        let facts = ids.compactMap { ledger.item($0) }.filter { fileExists($0.path) }
            .compactMap { Inspector.full(URL(fileURLWithPath: $0.path), hash: false) }
        guard let p = RuleLearner.propose(corrected: facts, folder: folder, config: config),
              ledger.meta("rule:" + p.key) == nil else { return }
        onRuleProposal?(p)
    }

    public func acceptRule(_ p: RuleLearner.Proposal) throws {
        try Config.appendRule(p.rule)
        config.rules.append(p.rule)
        ledger.setMeta("rule:" + p.key, "added")
        Log.info("rule added: \(p.rule.name)")
    }

    public func declineRule(_ p: RuleLearner.Proposal) {
        ledger.setMeta("rule:" + p.key, "declined")
    }

    /// File (or trash) an item right now, whatever the mode — you asked for it.
    public func fileNow(_ id: Int64) throws -> Item {
        guard let it = ledger.item(id), fileExists(it.path), let loc = locate(it.path) else {
            throw LandfallError.action("#\(id) is no longer where Landfall last saw it")
        }
        pending[it.path] = nil
        guard var f = Inspector.full(URL(fileURLWithPath: it.path)) else { throw LandfallError.action("can't read \(it.name)") }
        enrich(&f, firstSeen: it.firstSeen)
        var d = classifier.classify(f, root: loc.root)
        if d.action == .hold, let prior = it.decision, prior.action == .move || prior.action == .trash { d = prior }
        guard d.action == .move || d.action == .trash else {
            throw LandfallError.action("no confident home for \(it.name) — file it by hand")
        }
        try execute(id, path: it.path, d)
        return ledger.item(id)!
    }

    /// Everything a toast needs about one file.
    public func toastModel(for url: URL, itemId: Int64?, editorLookup: (String) -> Bool = { _ in false }) -> ToastModel? {
        guard var f = Inspector.full(url) else { return nil }
        enrich(&f, firstSeen: itemId.flatMap { ledger.item($0)?.firstSeen })
        let root = locate(url.path)?.root
        let d = root.map { classifier.classify(f, root: $0) }
        guard d?.action != .ignore else { return nil }
        let kind = FileKind.detect(f, decision: d)
        let trust = Trust.assess(f, kind: kind)
        let editor = Editor.installed(lookup: editorLookup)
        var actions = ActionPlanner.plan(f, kind: kind, trust: trust, decision: d, config: config, editor: editor)
        if itemId == nil { actions.removeAll { $0.kind == .fileNow || $0.kind == .keep } }
        let from = trust.originHost.map { " · from \($0)" } ?? ""
        var m = ToastModel(itemId: itemId, url: url, name: f.name, kind: kind,
                           subtitle: "\(kind.label) · \(formatBytes(f.size))\(from)", trust: trust,
                           suggestion: d.map(\.reason), actions: actions, decision: d, editor: editor)
        m.destinationLabel = d.flatMap(ActionPlanner.label(forDestination:))
        m.autoFile = itemId != nil && ActionPlanner.mayAutoFile(d, kind: kind, trust: trust, config: config)
        if m.autoFile {
            // Countdown toasts lead with the default, then Keep, then the most useful thing for this kind.
            let file = m.actions.first { $0.kind == .fileNow }.map { FileAction(.fileNow, "File now", confirm: $0.confirm) }
            let keep = m.actions.first { $0.kind == .keep }.map { FileAction(.keep, "Keep", confirm: $0.confirm) }
            let rest = m.actions.filter { $0.kind != .fileNow && $0.kind != .keep }
            m.actions = [file, keep].compactMap { $0 } + rest
        }
        return m
    }

    /// Tell Landfall to leave an item where it is.
    public func keep(_ id: Int64) throws {
        guard ledger.item(id) != nil else { throw LandfallError.action("no item #\(id)") }
        if let it = ledger.item(id) { pending[it.path] = nil }
        ledger.update(id, ["status": "kept"])
        ledger.addEvent(id, "kept", reason: "you chose to keep it here")
        onChange?()
    }

    /// Reverse the last move or trash of an item and pin it in place.
    public func undo(_ id: Int64) throws -> String {
        guard let it = ledger.item(id) else { throw LandfallError.action("no item #\(id)") }
        guard let ev = ledger.lastApplied(id), let src = ev.src else {
            throw LandfallError.action("nothing to undo for #\(id)")
        }
        guard fileExists(it.path) else {
            throw LandfallError.action("can't find it at \(Paths.pretty(it.path)) — was the Trash emptied?")
        }
        let srcURL = URL(fileURLWithPath: src)
        let dst = try Mover.move(URL(fileURLWithPath: it.path), toDir: srcURL.deletingLastPathComponent(),
                                 name: srcURL.lastPathComponent)
        let np = normalize(dst.path)
        ledger.markUndone(ev.id)
        ledger.update(id, ["path": np, "status": "kept", "bookmark": Mover.bookmark(np), "name": dst.lastPathComponent])
        ledger.addEvent(id, "undo", src: it.path, dst: np, reason: "undid \(ev.type)", applied: true)
        refreshShelf()
        onChange?()
        return np
    }

    /// Follow filed items via bookmarks so `where` stays right after you move things yourself.
    public func reconcile() {
        for it in ledger.items(statuses: ["filed", "elsewhere"]) {
            guard let b = it.bookmark else { continue }
            guard let now = Mover.resolve(b) else {
                if !fileExists(it.path) {
                    ledger.update(it.id, ["status": "gone"])
                    ledger.addEvent(it.id, "gone", src: it.path, reason: "no longer found")
                }
                continue
            }
            guard now != it.path else { continue }
            if now.contains("/.Trash/") {
                ledger.update(it.id, ["status": "trashed", "path": now])
                ledger.addEvent(it.id, "trashed", src: it.path, dst: now, reason: "you trashed it")
            } else {
                let corrected = it.status == "filed"
                ledger.update(it.id, ["path": now, "name": (now as NSString).lastPathComponent])
                ledger.addEvent(it.id, corrected ? "corrected" : "relocated", src: it.path, dst: now,
                                rule: it.decision?.rule,
                                reason: corrected ? "you moved it after Landfall filed it" : "you moved it")
                if corrected { learn(fromCorrectionInto: (now as NSString).deletingLastPathComponent) }
            }
        }
    }

    // MARK: - Recent shelf

    static let shelfMarker = "dev.landfall.shelf"

    /// Keep a folder of Finder aliases to everything filed in the last `recentDays`.
    public func refreshShelf() {
        guard let s = config.recentShelf else { return }
        let dir = URL(fileURLWithPath: normalize(s))
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for u in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        where Inspector.xattr(u.path, Self.shelfMarker) != nil {
            try? fm.removeItem(at: u)  // only aliases Landfall created
        }
        let since = clock().addingTimeInterval(-config.recentDays * 86400)
        for it in ledger.recent(since: since) where it.status == "filed" && fileExists(it.path) {
            guard let data = try? URL(fileURLWithPath: it.path)
                .bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil)
            else { continue }
            let alias = Mover.uniqueURL(dir: dir, name: it.name)
            guard (try? URL.writeBookmarkData(data, to: alias)) != nil else { continue }
            _ = "1".withCString { setxattr(alias.path, Self.shelfMarker, $0, 1, 0, 0) }
        }
    }

    func signature(_ q: ItemFacts) -> String {
        "\(q.size)|\(q.modified?.timeIntervalSince1970 ?? 0)"
    }
}
