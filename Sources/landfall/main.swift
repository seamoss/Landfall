import AppKit
import Foundation
import LandfallCore
import ServiceManagement

let usage = """
landfall — watches Downloads, Desktop and Documents and files what lands there.

  landfall init [--force]              write the starter config (~/.config/landfall/config.json)
  landfall scan [--root R] [--recheck] classify everything now (respects mode)
  landfall watch [--menubar]           run the watcher (what the login agent runs)
  landfall recent [--since 7d] [--root R]
  landfall where <query>               where did that file go?
  landfall why <query|#id>             the full history and reasoning for one item
  landfall review                      proposals waiting for you
  landfall apply <#id…> | --all        carry out proposals
  landfall keep <#id>                  leave an item where it is
  landfall undo [<#id>]                reverse the last move/trash (of one item, or overall)
  landfall mode [shadow|review|auto]
  landfall status
  landfall digest [--since 7d] [--notify]
  landfall suggest                     rules learned from your corrections
  landfall space [path…] [--trash --idle 30 --yes]
  landfall search <words>              names, document text and text in screenshots
  landfall reindex                     rebuild the search index for everything tracked
  landfall ai <#id|query> [--dry-run] | --held   ask Claude where it belongs (a proposal)
  landfall ai-key [--remove]           store your Anthropic API key in the keychain
  landfall vault <#id> | --all         import credentials into 1Password, trash the originals
  landfall expire                      trash downloads untouched past their expiry (auto mode)
  landfall login-item on|off|status    start Landfall.app at login
  (recent, where, review and search accept --json)
  landfall toast <file> [--snapshot out.png] [--dark]   preview the toast for a file
  landfall install | uninstall         how to install the app · stop it and remove the login item
"""

Log.echo = false
var args = Array(CommandLine.arguments.dropFirst()).filter { !$0.hasPrefix("-psn") }
// Opened from Finder or as a login item (no terminal): run the menu bar agent.
let command = args.isEmpty ? (isatty(0) == 0 ? "app" : "help") : args.removeFirst()

func flag(_ n: String) -> Bool {
    guard let i = args.firstIndex(of: n) else { return false }
    args.remove(at: i)
    return true
}

func option(_ n: String) -> String? {
    guard let i = args.firstIndex(of: n), i + 1 < args.count else { return nil }
    let v = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return v
}

let tty = isatty(1) != 0
func c(_ code: String, _ s: String) -> String { tty ? "\u{1b}[\(code)m\(s)\u{1b}[0m" : s }
func dim(_ s: String) -> String { c("2", s) }
func bold(_ s: String) -> String { c("1", s) }

func die(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("landfall: \(msg)\n".utf8))
    exit(1)
}

func makeEngine() -> Engine {
    do {
        return Engine(config: try Config.load(), ledger: try Ledger(path: Paths.ledgerURL))
    } catch {
        die("\(error)")
    }
}

func pad(_ s: String, _ n: Int) -> String {
    s.count >= n ? String(s.prefix(n - 1)) + "…" : s + String(repeating: " ", count: n - s.count)
}

func statusLabel(_ s: String) -> String {
    switch s {
    case "filed": return c("32", pad(s, 9))
    case "proposed": return c("33", pad(s, 9))
    case "held": return c("35", pad(s, 9))
    case "trashed": return c("31", pad(s, 9))
    default: return dim(pad(s, 9))
    }
}

func describe(_ d: Decision, name: String) -> String {
    switch d.action {
    case .move: return "→ " + Paths.pretty(d.target(for: name) ?? "?")
    case .trash: return "→ Trash"
    case .hold: return "stay"
    case .ignore: return "ignore"
    }
}

func itemLine(_ it: Item) -> String {
    let origin = it.origin.flatMap { URL(string: $0)?.host }.map { dim(" ⇣\($0)") } ?? ""
    let flags = (it.decision?.flags.contains("sensitive") == true) ? " ⚠️" : ""
    return "\(dim(pad("#\(it.id)", 6)))\(pad(ago(it.firstSeen), 9))\(dim(pad(it.root, 10)))\(statusLabel(it.status))"
        + "\(bold(it.name))\(flags)\(origin)\n" + String(repeating: " ", count: 34)
        + dim(it.status == "proposed" || it.status == "held"
            ? (it.decision.map { describe($0, name: it.name) + "  (\($0.reason))" } ?? "")
            : Paths.pretty(it.path))
}

func findItem(_ e: Engine, _ q: String) -> Item? {
    if let id = Int64(q.trimmingCharacters(in: CharacterSet(charactersIn: "#"))), let it = e.ledger.item(id) { return it }
    return e.ledger.search(q).first
}

func ids() -> [Int64] {
    args.compactMap { Int64($0.trimmingCharacters(in: CharacterSet(charactersIn: "#"))) }
}

let launchLabel = "dev.landfall.agent"
var agentPlist: URL {
    URL(fileURLWithPath: Paths.home).appendingPathComponent("Library/LaunchAgents/\(launchLabel).plist")
}

func agentRunning() -> Bool {
    let me = ProcessInfo.processInfo.processIdentifier
    let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.noisebeard.Landfall")
        .contains { $0.processIdentifier != me }
    return app || run("/bin/launchctl", ["print", "gui/\(getuid())/\(launchLabel)"]).status == 0
}

var keepAlive: [AnyObject] = []

func every(_ seconds: Double, _ f: @escaping () -> Void) {
    let t = DispatchSource.makeTimerSource(queue: .main)
    t.schedule(deadline: .now() + seconds, repeating: seconds)
    t.setEventHandler(handler: f)
    t.resume()
    keepAlive.append(t)
}

switch command {
case "init":
    if fileExists(Paths.configURL.path) && !flag("--force") {
        die("\(Paths.pretty(Paths.configURL.path)) already exists (use --force to overwrite)")
    }
    do { try Config.seeded().save() } catch { die("\(error)") }
    print("Wrote \(Paths.pretty(Paths.configURL.path)) (mode: shadow). Next: `landfall scan` to see what it would do.")

case "scan":
    let e = makeEngine()
    let root = option("--root")
    let results = e.scanNow(root: root, recheck: flag("--recheck"))
    let shown = results.filter { $0.decision.action != .ignore }
    if shown.isEmpty { print("Nothing new to classify.") }
    for r in shown {
        let conf = String(format: "%.2f", r.decision.confidence)
        print("\(statusLabel(r.status))\(bold(r.name))")
        print("         \(describe(r.decision, name: r.name))  \(dim("[\(r.decision.rule) \(conf)] \(r.decision.reason)"))")
    }
    if e.config.mode == .shadow {
        print(dim("\nShadow mode: nothing was moved. `landfall mode auto` to let it act, or `landfall apply` per item."))
    }

case "search":
    let json = flag("--json")
    guard !args.isEmpty else { die("usage: landfall search <words>") }
    let e = makeEngine()
    let hits = e.ledger.searchContent(args.joined(separator: " "))
    if json { printJSON(hits.map { itemJSON($0.item, snippet: $0.snippet) }) } else {
        if hits.isEmpty { print("Nothing matches.") }
        for h in hits {
            print(itemLine(h.item))
            if !h.snippet.isEmpty { print(String(repeating: " ", count: 34) + dim(h.snippet)) }
        }
    }

case "settings":
    if let out = option("--snapshot") {
        _ = NSApplication.shared
        do { try snapshotSettings(tab: Int(option("--tab") ?? "0") ?? 0, to: URL(fileURLWithPath: out)) } catch { die("\(error)") }
        print("wrote \(out)")
    } else {
        run("/usr/bin/open", ["landfall://settings"])
    }

case "reindex":
    let e = makeEngine()
    e.reindex(async: false) { print("Indexed \($0) items (names, document text, text in images).") }

case "ai":
    let e = makeEngine()
    let dry = flag("--dry-run")
    let targets: [Item] = flag("--held")
        ? e.ledger.items(statuses: ["held"]).filter { fileExists($0.path) && $0.decision?.rule == "fallback" }
        : (args.isEmpty ? [] : [findItem(e, args.joined(separator: " "))].compactMap { $0 })
    if targets.isEmpty { die("usage: landfall ai <#id|query> [--dry-run] | --held") }
    for it in targets {
        guard let f = Inspector.full(URL(fileURLWithPath: it.path)) else { continue }
        if let why = AIAdvisor.blockReason(f, decision: it.decision) { print("– \(it.name): not sent (\(why))"); continue }
        if dry {
            print(bold("── would send for \(it.name) ──"))
            print(AIAdvisor.prompt(for: f, config: e.config))
            continue
        }
        var result: Result<Decision, Error>?
        Task { @MainActor in
            do { result = .success(try await e.askAI(it.id)) } catch { result = .failure(error) }
        }
        while result == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        switch result! {
        case .success(let d):
            print("✓ #\(it.id) \(bold(it.name))\n    \(describe(d, name: it.name))  \(dim("[\(String(format: "%.2f", d.confidence))] \(d.reason)"))")
        case .failure(let err): print("✗ #\(it.id) \(it.name): \(err)")
        }
    }
    if !dry { print(dim("\nThese are proposals — `landfall apply #id` to accept.")) }

case "ai-key":
    if flag("--remove") {
        do { try Keychain.setAPIKey(nil); print("Removed the API key from the keychain.") } catch { die("\(error)") }
    } else {
        guard let raw = getpass("Anthropic API key (input hidden): ") else { die("no key entered") }
        let key = String(cString: raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.hasPrefix("sk-ant-") else { die("that doesn't look like an Anthropic API key") }
        do { try Keychain.setAPIKey(key); print("Saved to the login keychain (service “dev.landfall”).") } catch { die("\(error)") }
    }

case "vault":
    let e = makeEngine()
    let targets = flag("--all")
        ? e.ledger.items(statuses: ["proposed", "held", "filed", "kept"]).filter { $0.decision?.rule == "credential" && fileExists($0.path) }.map(\.id)
        : ids()
    if targets.isEmpty { die("usage: landfall vault <#id> | --all") }
    if OnePassword.cli == nil { die(OnePassword.installHint) }
    for id in targets {
        let name = e.ledger.item(id)?.name ?? "#\(id)"
        do { try e.vault(id); print("🔐 \(name) → 1Password (original in the Trash)") } catch { print("✗ \(name): \(error)") }
    }

case "expire":
    let e = makeEngine()
    let done = e.expireStale()
    print(done.isEmpty ? "Nothing has expired." : "\(done.count) stale item(s) " + (e.config.mode == .auto ? "moved to the Trash." : "proposed for the Trash."))

case "login-item":
    guard Bundle.main.bundleIdentifier != nil else { die("run this from Landfall.app (e.g. /Applications/Landfall.app/Contents/MacOS/Landfall login-item on)") }
    switch args.first ?? "status" {
    case "on": do { try SMAppService.mainApp.register() } catch { die("\(error)") }
    case "off": do { try SMAppService.mainApp.unregister() } catch { die("\(error)") }
    default: break
    }
    print("Login item: \(SMAppService.mainApp.status == .enabled ? "on" : "off")")

case "watch":
    Agent.start(menubar: flag("--menubar"), catalog: !flag("--no-catalog"))

case "app":
    Agent.start(menubar: true, catalog: true)

case "recent":
    let e = makeEngine()
    e.reconcile()
    let since = Date().addingTimeInterval(-(parseDuration(option("--since") ?? "7d") ?? 7 * 86400))
    let items = e.ledger.recent(since: since, root: option("--root"))
    if flag("--json") { printJSON(items.map { itemJSON($0) }) } else {
        if items.isEmpty { print("Nothing landed in that window.") }
        for it in items { print(itemLine(it)) }
    }

case "where":
    guard !args.isEmpty else { die("usage: landfall where <query>") }
    let e = makeEngine()
    e.reconcile()
    let asJSON = flag("--json")
    let hits = e.ledger.search(args.joined(separator: " "))
    if asJSON { printJSON(hits.map { itemJSON($0) }); exit(0) }
    if hits.isEmpty { print("No tracked item matches “\(args.joined(separator: " "))”.") }
    for it in hits { print(itemLine(it)) }

case "why":
    guard !args.isEmpty else { die("usage: landfall why <query|#id>") }
    let e = makeEngine()
    guard let it = findItem(e, args.joined(separator: " ")) else { die("no tracked item matches") }
    print("\(bold(it.name))  \(dim("#\(it.id)"))  \(statusLabel(it.status))")
    print("  now at   \(Paths.pretty(it.path))")
    print("  arrived  \(formatDate(it.firstSeen, "yyyy-MM-dd HH:mm")) in \(it.root)  · \(formatBytes(it.size))")
    if let o = it.origin { print("  from     \(o)") }
    if let d = it.decision {
        print("  verdict  \(describe(d, name: it.name))  [\(d.rule) \(String(format: "%.2f", d.confidence))] \(d.reason)")
        if !d.flags.isEmpty { print("  flags    \(d.flags.joined(separator: ", "))") }
    }
    print("  history")
    for ev in e.ledger.events(for: it.id) {
        var line = "    \(dim(formatDate(ev.ts, "MM-dd HH:mm")))  \(pad(ev.type, 10))"
        if let d = ev.dst { line += "→ \(Paths.pretty(d))  " }
        if let r = ev.reason { line += dim(r) }
        if ev.undone { line += dim(" (undone)") }
        print(line)
    }

case "review":
    let e = makeEngine()
    let items = e.ledger.items(statuses: ["proposed", "held"]).filter { fileExists($0.path) }
    if flag("--json") { printJSON(items.map { itemJSON($0) }); exit(0) }
    if items.isEmpty { print("Nothing waiting for review.") }
    for it in items { print(itemLine(it)) }
    if !items.isEmpty { print(dim("\n`landfall apply #id` · `landfall apply --all` · `landfall keep #id`")) }

case "apply":
    let e = makeEngine()
    let targets = flag("--all")
        ? e.ledger.items(statuses: ["proposed"]).filter { fileExists($0.path) }.map(\.id)
        : ids()
    if targets.isEmpty { die("usage: landfall apply <#id…> | --all") }
    for id in targets {
        do {
            let it = try e.apply(id)
            print("✓ #\(id) \(it.name) \(dim(it.status == "trashed" ? "→ Trash" : "→ " + Paths.pretty(it.path)))")
        } catch { print("✗ #\(id): \(error)") }
    }

case "keep":
    let e = makeEngine()
    for id in ids() {
        do { try e.keep(id); print("✓ #\(id) stays put") } catch { print("✗ \(error)") }
    }

case "undo":
    let e = makeEngine()
    let target = ids().first ?? e.ledger.lastAppliedOverall()?.itemId
    guard let id = target else { die("nothing to undo") }
    do { print("↩︎ #\(id) back at \(Paths.pretty(try e.undo(id)))") } catch { die("\(error)") }

case "mode":
    if let m = args.first {
        guard let mode = Mode(rawValue: m) else { die("mode must be shadow, review or auto") }
        do { try Config.set("mode", mode.rawValue) } catch { die("\(error)") }
        print("Mode: \(mode.rawValue)" + (agentRunning() ? dim(" (the running agent picks this up within 10s)") : ""))
    } else {
        print((try? Config.load().mode.rawValue) ?? "shadow")
    }

case "status":
    let e = makeEngine()
    print("\(bold("Landfall"))  mode \(e.config.mode.rawValue) · agent \(agentRunning() ? c("32", "running") : c("31", "not running"))")
    print("library  \(Paths.pretty(e.config.libraryURL.path))")
    for r in e.config.roots {
        print("watching \(pad(r.name, 10)) \(pad(Paths.pretty(r.url.path), 16)) \(r.role.rawValue), grace \(Int(r.graceSeconds / 60))m\(r.useLastUsed ? " after last use" : "")")
    }
    let counts = ["filed", "proposed", "held", "kept", "trashed", "elsewhere"].map { "\($0) \(e.ledger.count(status: $0))" }
    print("ledger   " + counts.joined(separator: " · "))
    print(dim("config \(Paths.pretty(Paths.configURL.path)) · log \(Paths.pretty(Paths.logURL.path))"))

case "digest":
    let e = makeEngine()
    let since = Date().addingTimeInterval(-(parseDuration(option("--since") ?? "7d") ?? 7 * 86400))
    let text = Report.digest(e.ledger, config: e.config, since: since)
    print(text)
    if flag("--notify") { notify("Landfall digest", text) }

case "suggest":
    let e = makeEngine()
    e.reconcile()
    let s = Report.suggestions(e.ledger, config: e.config)
    if s.isEmpty { print("No patterns yet — rules are suggested after you re-file the same kind of thing twice.") }
    for x in s {
        let rel = x.folder.hasPrefix(e.config.libraryURL.path + "/")
            ? String(x.folder.dropFirst(e.config.libraryURL.path.count + 1)) : x.folder
        print("\(bold(x.rule)) items moved by you to \(Paths.pretty(x.folder)) ×\(x.count)  \(dim(x.examples.joined(separator: ", ")))")
        print(dim("  add to \"rules\": {\"name\": \"…\", \"nameRegex\": \"…\", \"to\": \"\(rel)\"}"))
    }

case "space":
    let doTrash = flag("--trash")
    let yes = flag("--yes")
    let idle = Double(option("--idle") ?? "30") ?? 30
    let roots = args.isEmpty ? [URL(fileURLWithPath: Paths.home + "/Documents/Dev")] : args.map { URL(fileURLWithPath: Paths.expand($0)) }
    print(dim("Scanning \(roots.map { Paths.pretty($0.path) }.joined(separator: ", "))…"))
    let hits = Space.scan(roots).filter { $0.bytes > 1 << 20 }
    var total: Int64 = 0
    var eligible: [SpaceHit] = []
    for h in hits {
        let idleText = h.idleDays.map { "idle \(Int($0))d" } ?? "no git"
        let ok = !h.reportOnly && (h.idleDays ?? .infinity) >= idle
        if ok { eligible.append(h) }
        total += h.bytes
        print("\(pad(formatBytes(h.bytes), 10))\(pad(h.kind, 18))\(dim(pad(idleText, 10)))\(Paths.pretty(h.path))\(h.reportOnly ? dim("  (report only)") : "")")
    }
    let reclaim = eligible.reduce(0) { $0 + $1.bytes }
    print("\n\(bold(formatBytes(total))) rebuildable · \(bold(formatBytes(reclaim))) in projects idle ≥ \(Int(idle))d")
    if doTrash {
        guard yes else { die("add --yes to move those \(eligible.count) folders to the Trash") }
        for h in eligible {
            do { _ = try Mover.trash(URL(fileURLWithPath: h.path)); print("🗑  \(Paths.pretty(h.path))") } catch { print("✗ \(h.path): \(error)") }
        }
    }

case "install":
    print("""
    Landfall installs as an app now:
      1. ./scripts/package.sh      build + sign dist/Landfall.app (and notarize, if set up)
      2. ./scripts/install.sh      copy to /Applications, put `landfall` on PATH, retire the old agent, launch
    Or open dist/Landfall-<version>.dmg and drag Landfall to Applications.
    """)

case "toast":
    guard let path = args.first else { die("usage: landfall toast <file> [--snapshot out.png] [--dark]") }
    let snapshot = option("--snapshot")
    let dark = flag("--dark")
    let e = makeEngine()
    let url = URL(fileURLWithPath: normalize(args.first ?? path))
    guard fileExists(url.path) else { die("no such file: \(path)") }
    if e.ledger.activeItem(atPath: url.path) == nil { e.observe(url) }  // as if it had just landed
    let tracked = e.ledger.activeItem(atPath: url.path)?.id
    guard let m = e.toastModel(for: url, itemId: tracked, editorLookup: editorInstalled) else { die("that item is ignored") }
    if let snapshot {
        do { try Toast.snapshot(m, to: URL(fileURLWithPath: snapshot), dark: dark) } catch { die("\(error)") }
        print("kind     \(m.kind.label)\ntrust    \(m.trust.level.rawValue) — \(m.trust.summary)")
        print("dest     \(m.destinationLabel ?? "—")\nauto     \(m.autoFile ? "files when the countdown ends" : "no — just closes")")
        print("actions  " + m.actions.map { $0.confirm == nil ? $0.title : "\($0.title) [confirm]" }.joined(separator: " · "))
        print("wrote    \(snapshot)")
    } else {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let toaster = Toaster(engine: e)
        keepAlive.append(toaster)
        toaster.show(m)
        toaster.toasts.first?.onClose = { _ in exit(0) }
        app.run()
    }

case "uninstall":
    run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(launchLabel)"])
    try? FileManager.default.removeItem(at: agentPlist)
    if Bundle.main.bundleIdentifier != nil { try? SMAppService.mainApp.unregister() }
    NSRunningApplication.runningApplications(withBundleIdentifier: "com.noisebeard.Landfall")
        .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }.forEach { $0.terminate() }
    print("Stopped Landfall and removed it from login items. Drag /Applications/Landfall.app to the Trash to finish; config and history stay in ~/.config/landfall and ~/Library/Application Support/Landfall.")

default:
    print(usage)
}

func itemJSON(_ it: Item, snippet: String? = nil) -> [String: Any] {
    var o: [String: Any] = ["id": it.id, "name": it.name, "status": it.status, "root": it.root, "path": it.path,
                            "firstSeen": ISO8601DateFormatter().string(from: it.firstSeen), "size": it.size]
    if let origin = it.origin { o["origin"] = origin }
    if let d = it.decision {
        var dj: [String: Any] = ["action": d.action.rawValue, "rule": d.rule, "confidence": d.confidence, "reason": d.reason]
        if let t = d.target(for: it.name) { dj["target"] = t }
        o["decision"] = dj
    }
    if let snippet { o["snippet"] = snippet }
    return o
}

func printJSON(_ value: Any) {
    let data = (try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data("[]".utf8)
    print(String(decoding: data, as: UTF8.self))
}
