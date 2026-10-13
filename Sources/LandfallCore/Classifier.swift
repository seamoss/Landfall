import Foundation

public struct Decision: Codable, Equatable {
    public enum Action: String, Codable {
        case move, trash, hold, ignore
    }

    public var action: Action
    /// Absolute destination folder for `.move`.
    public var destination: String?
    public var newName: String?
    public var confidence: Double
    public var rule: String
    public var reason: String
    /// alert: notify loudly · sensitive: secrets or someone else's personal data · noAI: never send to a model
    public var flags: [String] = []

    public var json: String {
        (try? JSONEncoder().encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    public static func from(json: String) -> Decision? {
        try? JSONDecoder().decode(Decision.self, from: Data(json.utf8))
    }

    public func target(for name: String) -> String? {
        destination.map { $0 + "/" + (newName ?? name) }
    }
}

public protocol ClassifierContext: AnyObject {
    /// A tracked file with this hash that still exists somewhere other than `path`.
    func existingCopy(ofHash hash: String, excluding path: String) -> String?
}

public struct ClientMatch {
    public let client: ClientConfig
    public let score: Int
    public let why: String
    /// Matched by name, title, participants or download domain rather than body text alone.
    public var strong: Bool { score >= 2 }
}

public struct Transcript: Equatable {
    public var title: String
    public var date: Date?
    public var participants: [String]

    /// Recognizes Tactiq-style exports: `# Title`, `Meeting started: M/D/YYYY`, `Participants: a, b`.
    public static func parse(_ text: String) -> Transcript? {
        let head = String(text.prefix(4000))
        guard head.contains("Meeting started:") else { return nil }
        let title = head.captures("^\\s*#\\s+(.+?)\\s*$")?[1] ?? ""
        var date: Date?
        if let c = head.captures("Meeting started:\\s*(\\d{1,2})/(\\d{1,2})/(\\d{4})(?:,\\s*(\\d{1,2}):(\\d{2})(?::\\d{2})?\\s*([AP]M))?"),
           let mo = Int(c[1]), let d = Int(c[2]), let y = Int(c[3]) {
            var hour = 12, minute = 0
            if let h = Int(c[4]), let m = Int(c[5]) {
                hour = h % 12 + (c[6] == "PM" ? 12 : 0)
                minute = m
            }
            date = Calendar.current.date(from: DateComponents(year: y, month: mo, day: d, hour: hour, minute: minute))
        }
        let people = head.captures("Participants:\\s*([^\\n]+)")?[1]
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty } ?? []
        return Transcript(title: title, date: date, participants: people)
    }
}

public struct Classifier {
    public var config: Config
    public weak var context: ClassifierContext?
    public var now: Date

    public init(config: Config, context: ClassifierContext? = nil, now: Date = Date()) {
        self.config = config
        self.context = context
        self.now = now
    }

    static let partialExts: Set<String> = ["crdownload", "download", "part", "partial", "tmp", "opdownload"]
    static let secretExts: Set<String> = ["p12", "pfx", "pem", "key", "jks", "keystore", "ovpn", "kdbx", "env", "p8", "ppk"]
    static let installerExts: Set<String> = ["dmg", "pkg", "mpkg"]
    static let fontExts: Set<String> = ["woff2", "woff", "ttf", "otf", "ttc", "eot"]
    static let audioExts: Set<String> = ["mp3", "wav", "aif", "aiff", "flac", "m4a", "alac", "ogg", "als", "logicx", "ptx"]
    static let videoExts: Set<String> = ["mp4", "mov", "m4v", "avi", "mkv", "webm"]
    public static let imageExts: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "svg", "tiff"]
    static let designExts: Set<String> = ["psd", "ai", "fig", "sketch", "xd"]
    static let makerExts: Set<String> = ["stl", "3mf", "obj", "gcode", "step", "stp", "f3d", "scad"]
    static let dataExts: Set<String> = ["csv", "tsv", "xlsx", "xls", "numbers", "parquet", "json", "sqlite", "db"]

    /// Items Landfall never records at all.
    public func ignoreReason(_ url: URL, isDir: Bool, root: RootConfig) -> String? {
        let name = url.lastPathComponent
        let path = normalize(url.path)
        if name.hasPrefix(".") { return "hidden file" }
        if name == "Icon\r" { return "folder icon" }
        if Self.partialExts.contains(url.pathExtension.lowercased()) { return "download in progress" }
        if root.neverTouch.contains(name) { return "listed in neverTouch" }
        if let shelf = config.recentShelf, normalize(shelf) == path { return "recent shelf" }
        if path == config.libraryURL.path { return "the library itself" }
        if root.role == .library && isDir { return "library folder" }
        if isDir && Inspector.xattr(path, Self.cabinetMarker) != nil { return "Landfall filing folder" }
        if isDir && root.filing.mode == .inPlace, let base = root.filing.folder, normalize(base) == path { return "filing folder" }
        return nil
    }

    public func classify(_ f: ItemFacts, root: RootConfig) -> Decision {
        if let why = ignoreReason(f.url, isDir: f.isDir, root: root) {
            return Decision(action: .ignore, confidence: 1, rule: "ignore", reason: why)
        }
        if f.tags.contains(where: { $0.caseInsensitiveCompare("Keep") == .orderedSame }) {
            return Decision(action: .ignore, confidence: 1, rule: "ignore", reason: "tagged Keep")
        }
        let transcript = f.textHead.flatMap(Transcript.parse)
        let steps: [() -> Decision?] = [
            { credential(f) },
            { userRule(f, root, transcript) },
            { duplicate(f) },
            { archiveTwin(f) },
            { junk(f) },
            { installer(f) },
            { codeProject(f) },
            { meeting(f, transcript) },
            { staleCapture(f) },
            { screenshot(f) },
            { fonts(f) },
            { resume(f) },
            { contactCard(f) },
            { maker(f) },
            { contract(f) },
            { media(f) },
            { clientHome(f) },
            { image(f) },
        ]
        for step in steps {
            if var d = step() {
                if d.action == .move, d.newName == nil, !f.isDir, d.rule != "credential" {
                    d.newName = Renamer.suggest(f)
                }
                return localize(d, f, root)
            }
        }
        return hold(0.3, "fallback", "no confident home yet")
    }

    // MARK: - Handlers

    func credential(_ f: ItemFacts) -> Decision? {
        guard !f.isDir else { return nil }
        var why: String?
        if Self.secretExts.contains(f.ext) {
            why = ".\(f.ext) key/certificate file"
        } else if f.name.matches("(?i)^id_(rsa|ed25519|ecdsa|dsa)$") {
            why = "SSH private key"
        } else if f.name.matches("(?i)^(client_secret|credentials|service[-_ ]?account).*\\.json$") {
            why = "OAuth/service-account credentials"
        } else if f.name.matches("(?i)(backup[-_ ]?codes?|recovery[-_ ]?(codes?|key|phrase)|seed[-_ ]?phrase|2fa|passwords?)") {
            why = "looks like recovery codes or passwords"
        } else if let t = f.textHead {
            let patterns: [(String, String)] = [
                ("\"private_key\"\\s*:", "contains a private key"),
                ("-----BEGIN [A-Z ]*PRIVATE KEY-----", "contains a private key"),
                ("\"client_secret\"\\s*:", "contains an OAuth client secret"),
                ("sk-ant-[A-Za-z0-9_-]{20,}", "contains an Anthropic API key"),
                ("AKIA[0-9A-Z]{16}", "contains an AWS access key"),
                ("xox[bpas]-[A-Za-z0-9-]{10,}", "contains a Slack token"),
                ("gh[pousr]_[A-Za-z0-9]{30,}", "contains a GitHub token"),
                ("(?m)^\\s*(export\\s+)?[A-Z0-9_]*(SECRET|API_KEY|TOKEN|PASSWORD)[A-Z0-9_]*\\s*=\\s*\\S{8,}", "contains secrets"),
            ]
            why = patterns.first { t.matches($0.0) }?.1
        }
        guard let why else { return nil }
        return moveTo(config.folders.sensitive, 0.99, "credential",
                      "\(why) — store it in 1Password, then trash it",
                      flags: ["alert", "sensitive", "noAI"])
    }

    func userRule(_ f: ItemFacts, _ root: RootConfig, _ t: Transcript?) -> Decision? {
        for r in config.rules where r.hasConditions {
            if let rr = r.root, rr != root.name { continue }
            if let e = r.extensions, !e.map({ $0.lowercased() }).contains(f.ext) { continue }
            if let p = r.nameRegex, !f.name.matches(p) { continue }
            if let p = r.contentRegex, !(f.textHead ?? "").matches(p) { continue }
            if let p = r.originRegex, !f.origins.contains(where: { $0.matches(p) }) { continue }
            if let wanted = r.participantsAny {
                let hit = t?.participants.contains { p in wanted.contains { $0.caseInsensitiveCompare(p) == .orderedSame } }
                if hit != true { continue }
            }
            let conf = r.confidence ?? 0.95
            let rule = "rule:\(r.name)"
            let reason = "matched your rule “\(r.name)”"
            switch (r.action ?? "move").lowercased() {
            case "ignore": return Decision(action: .ignore, confidence: conf, rule: rule, reason: reason)
            case "trash": return trash(conf, rule, reason)
            case "hold": return hold(conf, rule, reason)
            default:
                guard let to = r.to else { continue }
                let client = matchClient(f, people: t?.participants ?? [])?.client.name
                let date = t?.date ?? when(f)
                return moveTo(expand(to, date: date, client: client), conf, rule, reason,
                              rename: r.rename.map { renamed($0, f, t) })
            }
        }
        return nil
    }

    func duplicate(_ f: ItemFacts) -> Decision? {
        guard !f.isDir, f.size > 0, let h = f.hash else { return nil }
        if let other = context?.existingCopy(ofHash: h, excluding: normalize(f.url.path)) {
            return trash(0.95, "duplicate", "identical copy already at \(Paths.pretty(other))")
        }
        // Browser-style "name (2).ext" next to an identical "name.ext"
        if let c = f.base.captures("^(.+?) ?\\((\\d+)\\)$") {
            let origName = c[1] + (f.url.pathExtension.isEmpty ? "" : "." + f.url.pathExtension)
            let orig = f.url.deletingLastPathComponent().appendingPathComponent(origName)
            if fileExists(orig.path), Inspector.sha256(orig) == h {
                return trash(0.95, "duplicate", "browser duplicate of \(origName)")
            }
        }
        return nil
    }

    func archiveTwin(_ f: ItemFacts) -> Decision? {
        guard f.ext == "zip", let entries = f.entries else { return nil }
        let twin = f.url.deletingPathExtension()
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: twin.path, isDirectory: &isDir), isDir.boolValue else { return nil }
        let zipFiles = entries
            .filter { !$0.hasSuffix("/") && !$0.hasPrefix("__MACOSX") && !$0.hasSuffix(".DS_Store") }
            .map { $0.precomposedStringWithCanonicalMapping }
        guard !zipFiles.isEmpty else { return nil }
        let have = Set(Inspector.listFiles(twin, limit: 200_000))
        let prefix = f.base.precomposedStringWithCanonicalMapping + "/"
        let stripped = zipFiles.map { $0.hasPrefix(prefix) ? String($0.dropFirst(prefix.count)) : $0 }
        guard Set(zipFiles).isSubset(of: have) || Set(stripped).isSubset(of: have) else { return nil }
        return trash(0.95, "archive-twin", "already unzipped next to it (\(twin.lastPathComponent)/ has all \(zipFiles.count) files)")
    }

    func junk(_ f: ItemFacts) -> Decision? {
        guard !f.isDir else { return nil }
        if f.size < 64 && f.base.matches("(?i)^untitled") {
            return trash(0.9, "junk", "near-empty scratch file (\(f.size) bytes)")
        }
        if f.size == 0 { return trash(0.85, "junk", "empty file") }
        return nil
    }

    func installer(_ f: ItemFacts) -> Decision? {
        guard Self.installerExts.contains(f.ext) else { return nil }
        if let used = f.lastUsed, now.timeIntervalSince(used) > 86400 {
            return trash(0.9, "installer", "installer opened \(ago(used, now: now)) — install is done")
        }
        if now.timeIntervalSince(when(f)) > 14 * 86400 {
            return trash(0.7, "installer", "installer never opened in two weeks")
        }
        return hold(0.5, "installer", "waiting until you've installed it")
    }

    func codeProject(_ f: ItemFacts) -> Decision? {
        guard f.isDir, !f.isPackage else { return nil }
        let markers = ["package.json", "pyproject.toml", "Cargo.toml", "go.mod", "Package.swift", "Gemfile"]
        let hasMarker = (f.entries ?? []).contains { markers.contains($0) }
        guard f.isGitRepo || hasMarker else { return nil }
        if fileExists(dir(config.folders.dev) + "/" + f.name) {
            return hold(0.5, "code", "\(config.folders.dev)/\(f.name) already exists — merge by hand")
        }
        if f.gitDirty { return hold(0.5, "code", "repo has uncommitted changes — commit or stash first") }
        if f.gitUnknown { return hold(0.5, "code", "can't check this repo for uncommitted changes here — move it yourself") }
        return moveTo(config.folders.dev, f.isGitRepo ? 0.9 : 0.7, "code",
                      f.isGitRepo ? "git repository" : "code project (no git)")
    }

    func meeting(_ f: ItemFacts, _ t: Transcript?) -> Decision? {
        guard let t else { return nil }
        let date = t.date ?? when(f)
        let m = matchClient(f, people: t.participants, titles: [t.title])
        let folder = m.map { "\(config.folders.meetings)/\($0.client.name)/\(ym(date))" }
            ?? "\(config.folders.meetings)/\(ym(date))"
        let title = sanitize(t.title.isEmpty ? f.base : t.title)
        let rename = f.base.matches("^\\d{4}-\\d{2}-\\d{2}") ? nil : "\(ymd(date)) \(title).\(f.url.pathExtension)"
        let why = "meeting transcript · " + (m.map { "\($0.client.name) (\($0.why))" } ?? "no client match")
        let conf = m.map { $0.strong ? 0.92 : 0.8 } ?? 0.85
        return moveTo(folder, conf, "transcript", why, rename: rename)
    }

    /// Keep only the newest capture of each localhost page.
    func staleCapture(_ f: ItemFacts) -> Decision? {
        guard !f.isDir, Self.imageExts.contains(f.ext),
              let key = Self.captureKey(f.name), let mine = f.modified else { return nil }
        let dir = f.url.deletingLastPathComponent()
        let siblings = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let newer = siblings.filter { u in
            u.lastPathComponent != f.name && Self.captureKey(u.lastPathComponent) == key
                && ((try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) > mine
        }
        guard !newer.isEmpty else { return nil }
        return trash(0.75, "stale-capture", "older capture of \(key) — \(newer.count) newer one\(newer.count == 1 ? "" : "s") next to it")
    }

    /// "127.0.0.1_5174___foundation (3).png" → "localhost:5174/foundation"
    static func captureKey(_ name: String) -> String? {
        guard let c = name.captures("^(?:127\\.0\\.0\\.1|localhost|0\\.0\\.0\\.0)_(\\d+)_+(.*?)(?: ?\\(\\d+\\))?\\.[A-Za-z]+$") else { return nil }
        return "localhost:\(c[1])/\(c[2])"
    }

    func screenshot(_ f: ItemFacts) -> Decision? {
        guard !f.isDir else { return nil }
        if Self.imageExts.contains(f.ext), let c = f.name.captures("^(127\\.0\\.0\\.1|localhost|0\\.0\\.0\\.0)_(\\d+)_") {
            return moveTo("\(config.folders.devCaptures)/port-\(c[2])", 0.9, "dev-capture", "browser capture of localhost:\(c[2])")
        }
        let named = f.name.matches("^(Screen ?[Ss]hot|CleanShot|Screen Recording)[ _]")
        guard f.isScreenshot || named else { return nil }
        return moveTo("\(config.folders.screenshots)/\(ym(when(f)))", 0.95, "screenshot", "screenshot")
    }

    func fonts(_ f: ItemFacts) -> Decision? {
        if !f.isDir && Self.fontExts.contains(f.ext) {
            return moveTo(config.folders.fonts, 0.9, "font", "font file")
        }
        guard f.isDir || f.ext == "zip", let entries = f.entries else { return nil }
        let files = entries.filter { !$0.hasSuffix("/") && !$0.contains("__MACOSX") && !$0.hasSuffix(".DS_Store") }
        let n = files.filter { Self.fontExts.contains(($0 as NSString).pathExtension.lowercased()) }.count
        guard n >= 2, Double(n) >= 0.6 * Double(files.count) else { return nil }
        return moveTo(config.folders.fonts, 0.9, "font", "font pack (\(n) fonts)")
    }

    func resume(_ f: ItemFacts) -> Decision? {
        guard !f.isDir, f.name.matches("(?i)(r[eé]sum[eé]|resu.e\\b|\\bcv\\b|curriculum vitae)") else { return nil }
        let hay = f.name + "\n" + String((f.textHead ?? "").prefix(3000))
        if config.ownerNames.contains(where: { hay.containsWord($0) }) {
            return moveTo(config.folders.personal, 0.85, "resume", "your résumé")
        }
        guard f.textHead != nil else { return hold(0.5, "resume", "a résumé, but couldn't tell whose") }
        return moveTo(config.folders.hiring, 0.8, "resume", "someone else's résumé (personal data)",
                      flags: ["sensitive", "noAI"])
    }

    func contactCard(_ f: ItemFacts) -> Decision? {
        guard !f.isDir, f.ext == "vcf" else { return nil }
        return moveTo(config.folders.contacts, 0.85, "contact", "contact card (personal data)", flags: ["sensitive", "noAI"])
    }

    func maker(_ f: ItemFacts) -> Decision? {
        guard !f.isDir, Self.makerExts.contains(f.ext) else { return nil }
        return moveTo(config.folders.making, 0.85, "maker", "3D-print / CAD file")
    }

    func contract(_ f: ItemFacts) -> Decision? {
        guard !f.isDir else { return nil }
        let p = "(?i)\\b(agreement|contract|msa|sow|nda|statement of work|engagement letter|addendum|amendment)\\b"
        guard f.name.matches(p) || (f.title ?? "").matches(p) else { return nil }
        if let m = matchClient(f), m.strong {
            return moveTo("\(m.client.folderPath)/\(config.folders.contracts)", 0.9, "contract",
                          "contract · \(m.client.name) (\(m.why))")
        }
        return moveTo("\(config.folders.unassigned)/\(config.folders.contracts)", 0.65, "contract", "contract, client unknown")
    }

    func media(_ f: ItemFacts) -> Decision? {
        if !f.isDir && Self.audioExts.contains(f.ext) {
            return moveTo(config.folders.music, 0.85, "audio", "audio file")
        }
        if f.isDir || f.ext == "zip" {
            if f.name.matches("(?i)\\b(stems?|master(ed)?|mixdown|bounces?|multitracks?)\\b") {
                return moveTo(config.folders.music, 0.85, "audio", "audio project")
            }
            if let e = f.entries {
                let files = e.filter { !$0.hasSuffix("/") && !$0.contains("__MACOSX") }
                let n = files.filter { Self.audioExts.contains(($0 as NSString).pathExtension.lowercased()) }.count
                if n >= 2 && Double(n) >= 0.6 * Double(files.count) {
                    return moveTo(config.folders.music, 0.8, "audio", "audio collection (\(n) tracks)")
                }
            }
        }
        if !f.isDir && Self.videoExts.contains(f.ext) {
            let phone = f.name.matches("^(\\d{8}_\\d{6}|IMG_\\d+|VID_\\d+|PXL_\\d+|\\d{9,})")
            return moveTo("\(config.folders.personalMedia)/\(y(when(f)))", phone ? 0.85 : 0.6, "video",
                          phone ? "phone video" : "video")
        }
        return nil
    }

    func clientHome(_ f: ItemFacts) -> Decision? {
        guard let m = matchClient(f) else { return nil }
        let sub = Self.dataExts.contains(f.ext) ? "/" + config.folders.data : ""
        return moveTo(m.client.folderPath + sub, m.strong ? 0.85 : 0.65, "client", "\(m.client.name) (\(m.why))")
    }

    func image(_ f: ItemFacts) -> Decision? {
        guard !f.isDir else { return nil }
        if Self.designExts.contains(f.ext) {
            return moveTo(config.folders.designBrand, 0.7, "image", "design file")
        }
        guard Self.imageExts.contains(f.ext) else { return nil }
        if f.base.matches("(?i)(logo|wordmark|brand|icon|mark)") {
            return moveTo(config.folders.logos, 0.8, "image", "logo/brand asset")
        }
        return moveTo("\(config.folders.images)/\(ym(when(f)))", 0.65, "image", "image")
    }

    // MARK: - Per-folder filing

    public static let cabinetMarker = "dev.landfall.cabinet"

    /// For folders set to file in place, rewrite a library destination into the folder's own cabinet.
    /// Credentials still go to the library's _Sensitive.
    public func localize(_ d: Decision, _ f: ItemFacts, _ root: RootConfig) -> Decision {
        guard root.filing.mode == .inPlace, d.action == .move, let dest = d.destination,
              d.rule != "credential", !d.flags.contains("sensitive") || d.rule == "resume" || d.rule == "contact" else { return d }
        let lib = config.libraryURL.path + "/"
        let rel = dest.hasPrefix(lib) ? String(dest.dropFirst(lib.count)) : (dest as NSString).lastPathComponent
        let category = rel.split(separator: "/").first.map(String.init) ?? "Other"
        let date = f.added ?? f.modified ?? now
        let sub = root.filing.layout
            .replacingOccurrences(of: "{yyyy-mm-dd}", with: ymd(date))
            .replacingOccurrences(of: "{yyyy-mm}", with: ym(date))
            .replacingOccurrences(of: "{yyyy}", with: y(date))
            .replacingOccurrences(of: "{category}", with: category)
            .replacingOccurrences(of: "{path}", with: rel)
            .split(separator: "/").filter { $0 != ".." && !$0.isEmpty }.joined(separator: "/")
        let base = root.filing.folder.map(normalize) ?? root.url.path
        var out = d
        out.destination = sub.isEmpty ? base : base + "/" + sub
        return out
    }

    // MARK: - Clients

    public func matchClient(_ f: ItemFacts, people: [String] = [], titles: [String] = []) -> ClientMatch? {
        let hosts = f.origins.compactMap { URL(string: $0)?.host?.lowercased() }
        let body = String(((f.textHead ?? "") + "\n" + (f.ocrText ?? "")).prefix(8000))
        let others = people.filter { p in !config.ownerNames.contains { $0.caseInsensitiveCompare(p) == .orderedSame } }
        var best: ClientMatch?
        for c in config.clients {
            let names = ([c.name] + c.aliases).filter { !$0.isEmpty }
            var score = 0
            var why: [String] = []
            let labels = [f.name, f.title ?? ""] + titles
            if let a = names.first(where: { n in labels.contains { $0.containsWord(n) } }) {
                score += 3
                why.append("name mentions “\(a)”")
            } else if let a = names.first(where: { body.containsWord($0) }) {
                score += 1
                why.append("content mentions “\(a)”")
            }
            let ppl = others.filter { p in c.people.contains { $0.caseInsensitiveCompare(p) == .orderedSame } }
            if !ppl.isEmpty {
                score += 2 * ppl.count
                why.append("with " + ppl.joined(separator: ", "))
            }
            if let d = c.domains.first(where: { d in hosts.contains { $0 == d.lowercased() || $0.hasSuffix("." + d.lowercased()) } }) {
                score += 3
                why.append("from \(d)")
            }
            // The meeting you were in when it arrived.
            for m in f.meetings {
                let byTitle = names.contains { m.title.containsWord($0) }
                let byPeople = m.attendees.contains { a in
                    c.people.contains { $0.caseInsensitiveCompare(a) == .orderedSame }
                        || c.domains.contains { d in a.lowercased().hasSuffix("@" + d.lowercased()) || a.lowercased().hasSuffix("." + d.lowercased()) }
                }
                if byTitle || byPeople {
                    score += 3
                    why.append("during “\(m.title)”")
                    break
                }
            }
            if score > (best?.score ?? 0) {
                best = ClientMatch(client: c, score: score, why: why.joined(separator: ", "))
            }
        }
        return best
    }

    // MARK: - Helpers

    func dir(_ rel: String) -> String { config.libraryURL.appendingPathComponent(rel).path }

    func moveTo(_ rel: String, _ conf: Double, _ rule: String, _ reason: String,
                rename: String? = nil, flags: [String] = []) -> Decision {
        Decision(action: .move, destination: dir(rel), newName: rename, confidence: conf, rule: rule, reason: reason, flags: flags)
    }

    func trash(_ conf: Double, _ rule: String, _ reason: String) -> Decision {
        Decision(action: .trash, confidence: conf, rule: rule, reason: reason)
    }

    func hold(_ conf: Double, _ rule: String, _ reason: String, flags: [String] = []) -> Decision {
        Decision(action: .hold, confidence: conf, rule: rule, reason: reason, flags: flags)
    }

    func when(_ f: ItemFacts) -> Date { f.added ?? f.modified ?? now }
    func ymd(_ d: Date) -> String { formatDate(d, "yyyy-MM-dd") }
    func ym(_ d: Date) -> String { formatDate(d, "yyyy-MM") }
    func y(_ d: Date) -> String { formatDate(d, "yyyy") }

    func sanitize(_ s: String) -> String {
        s.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func expand(_ tpl: String, date: Date, client: String?) -> String {
        tpl.replacingOccurrences(of: "{yyyy-mm}", with: ym(date))
            .replacingOccurrences(of: "{yyyy}", with: y(date))
            .replacingOccurrences(of: "{mm}", with: formatDate(date, "MM"))
            .replacingOccurrences(of: "{client}", with: client ?? "_Unassigned")
    }

    func renamed(_ tpl: String, _ f: ItemFacts, _ t: Transcript?) -> String {
        let title = sanitize(t?.title.isEmpty == false ? t!.title : (f.title ?? f.base))
        var out = tpl.replacingOccurrences(of: "{date}", with: ymd(t?.date ?? when(f)))
            .replacingOccurrences(of: "{title}", with: title)
            .replacingOccurrences(of: "{name}", with: f.name)
            .replacingOccurrences(of: "{base}", with: f.base)
            .replacingOccurrences(of: "{ext}", with: f.url.pathExtension)
        if !f.url.pathExtension.isEmpty && !out.hasSuffix("." + f.url.pathExtension) {
            out += "." + f.url.pathExtension
        }
        return out
    }
}
