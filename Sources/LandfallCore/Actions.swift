import Foundation

// MARK: - What kind of thing landed

public enum FileKind: String {
    case application, installerPackage, diskImage, script, linkFile, configProfile
    case archive, font, calendar, contact, credential, transcript, screenshot
    case image, video, audio, pdf, document, macroDocument, web, codeFile, codeProject, model3D, folder, other

    static let scriptExts: Set<String> = [
        "sh", "command", "tool", "zsh", "bash", "fish", "py", "rb", "pl", "ps1",
        "scpt", "applescript", "jxa", "workflow", "jar", "terminal", "action",
    ]
    static let archiveExts: Set<String> = ["zip", "tar", "tgz", "gz", "bz2", "tbz", "xz", "txz", "7z", "rar"]
    static let docExts: Set<String> = ["doc", "docx", "rtf", "odt", "pages", "xls", "xlsx", "numbers", "ppt", "pptx", "key", "md", "txt", "csv", "tsv", "json", "epub"]
    static let macroExts: Set<String> = ["docm", "xlsm", "pptm", "dotm", "xltm", "xlam"]
    static let codeExts: Set<String> = ["swift", "ts", "tsx", "js", "jsx", "go", "rs", "java", "kt", "c", "h", "cpp", "css", "scss", "sql", "yaml", "yml", "toml", "ipynb"]
    static let linkExts: Set<String> = ["webloc", "inetloc", "url", "fileloc"]

    public static func detect(_ f: ItemFacts, decision: Decision?) -> FileKind {
        let e = f.ext
        if decision?.rule == "credential" { return .credential }
        if f.isDir {
            if e == "app" { return .application }
            if e == "pkg" || e == "mpkg" { return .installerPackage }
            if e == "workflow" || e == "action" { return .script }
            if f.isGitRepo || decision?.rule == "code" { return .codeProject }
            return .folder
        }
        switch e {
        case "pkg", "mpkg": return .installerPackage
        case "dmg", "iso", "sparseimage": return .diskImage
        case "mobileconfig": return .configProfile
        case "ics", "ical": return .calendar
        case "vcf": return .contact
        case "pdf": return .pdf
        case "html", "htm", "xhtml", "svg": return e == "svg" ? .image : .web
        default: break
        }
        if linkExts.contains(e) { return .linkFile }
        if scriptExts.contains(e) || isShebangExecutable(f) { return .script }
        if macroExts.contains(e) { return .macroDocument }
        if archiveExts.contains(e) { return .archive }
        if Classifier.fontExts.contains(e) { return .font }
        if decision?.rule == "transcript" { return .transcript }
        if decision?.rule == "screenshot" || decision?.rule == "dev-capture" || f.isScreenshot { return .screenshot }
        if Classifier.imageExts.contains(e) || Classifier.designExts.contains(e) { return .image }
        if Classifier.videoExts.contains(e) { return .video }
        if Classifier.audioExts.contains(e) { return .audio }
        if Classifier.makerExts.contains(e) { return .model3D }
        if codeExts.contains(e) { return .codeFile }
        if docExts.contains(e) { return .document }
        return .other
    }

    static func isShebangExecutable(_ f: ItemFacts) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: f.url.path) else { return false }
        if let t = f.textHead { return t.hasPrefix("#!") }
        guard let h = try? FileHandle(forReadingFrom: f.url), let d = try? h.read(upToCount: 2) else { return false }
        return d == Data("#!".utf8)
    }

    /// Things that can execute code or change the system when opened.
    public var canExecute: Bool {
        [.application, .installerPackage, .diskImage, .script, .linkFile, .configProfile, .macroDocument].contains(self)
    }

    public var label: String {
        switch self {
        case .application: return "App"
        case .installerPackage: return "Installer package"
        case .diskImage: return "Disk image"
        case .script: return "Script"
        case .linkFile: return "Link"
        case .configProfile: return "Configuration profile"
        case .archive: return "Archive"
        case .font: return "Font"
        case .calendar: return "Calendar invite"
        case .contact: return "Contact card"
        case .credential: return "Credential"
        case .transcript: return "Meeting transcript"
        case .screenshot: return "Screenshot"
        case .image: return "Image"
        case .video: return "Video"
        case .audio: return "Audio"
        case .pdf: return "PDF"
        case .document: return "Document"
        case .macroDocument: return "Office document with macros"
        case .web: return "Web page"
        case .codeFile: return "Source file"
        case .codeProject: return "Code project"
        case .model3D: return "3D model"
        case .folder: return "Folder"
        case .other: return "File"
        }
    }
}

// MARK: - Can it be trusted

public struct TrustInfo: Equatable {
    public enum Level: String { case trusted, caution, danger }
    public enum Gatekeeper: Equatable { case notApplicable, accepted(String), rejected }

    public var quarantined = false
    public var downloadedBy: String?
    public var originHost: String?
    public var gatekeeper: Gatekeeper = .notApplicable
    public var signer: String?
    public var notes: [String] = []
    public var level: Level = .trusted

    public init() {}

    public var summary: String {
        var parts: [String] = []
        switch gatekeeper {
        case .accepted(let source): parts.append(signer.map { "Signed · \($0)" } ?? source)
        case .rejected: parts.append("Rejected by Gatekeeper")
        case .notApplicable: break
        }
        if quarantined { parts.append("downloaded" + (originHost.map { " from \($0)" } ?? downloadedBy.map { " by \($0)" } ?? "")) }
        parts.append(contentsOf: notes)
        return parts.isEmpty ? "Local file" : parts.joined(separator: " · ")
    }
}

public enum Trust {
    public static func assess(_ f: ItemFacts, kind: FileKind) -> TrustInfo {
        var t = TrustInfo()
        if let q = Inspector.xattr(f.url.path, "com.apple.quarantine").map({ String(decoding: $0, as: UTF8.self) }) {
            t.quarantined = true
            let fields = q.split(separator: ";", omittingEmptySubsequences: false)
            if fields.count > 2, !fields[2].isEmpty { t.downloadedBy = String(fields[2]) }
        }
        t.originHost = f.origins.lazy.compactMap(host).first

        switch kind {
        case .application: gatekeeper(&t, ["--assess", "--type", "execute", "-vv", f.url.path])
        case .installerPackage: gatekeeper(&t, ["--assess", "--type", "install", "-vv", f.url.path])
        case .diskImage: gatekeeper(&t, ["--assess", "--type", "open", "--context", "context:primary-signature", "-vv", f.url.path])
        default: break
        }

        switch kind {
        case .configProfile:
            t.level = .danger
            t.notes.append("can change system settings")
        case .diskImage where t.gatekeeper == .rejected:
            // Most vendors sign the app inside, not the .dmg; Gatekeeper checks the app when it's opened.
            t.gatekeeper = .notApplicable
            t.notes.append("image isn't signed — the app inside is checked when opened")
            t.level = t.quarantined ? .caution : .trusted
        case .application, .installerPackage, .diskImage:
            if t.gatekeeper == .rejected { t.level = .danger }
            else if case .accepted = t.gatekeeper { t.level = .trusted }
            else { t.level = t.quarantined ? .caution : .trusted }
        case .script:
            t.level = .caution
            t.notes.append("runs with your permissions")
        case .linkFile:
            t.level = .caution
            if let target = linkTarget(f.url) { t.notes.append("opens \(target)") }
        case .macroDocument:
            t.level = .caution
            t.notes.append("contains macros")
        case .web:
            t.level = t.quarantined ? .caution : .trusted
        case .credential:
            t.level = .danger
            t.notes.append("contains secrets")
        default:
            t.level = .trusted
        }
        return t
    }

    static func gatekeeper(_ t: inout TrustInfo, _ args: [String]) {
        let r = run("/usr/sbin/spctl", args, stderr: true)
        if r.out.contains(": accepted") {
            let source = r.out.captures("source=(.+)")?[1] ?? "Accepted by Gatekeeper"
            t.gatekeeper = .accepted(source)
            t.signer = r.out.captures("origin=(?:Developer ID (?:Application|Installer): )?(.+)")?[1]
        } else if r.out.contains("rejected") {
            t.gatekeeper = .rejected
        }
    }

    static func host(_ s: String) -> String? {
        let cleaned = s.hasPrefix("blob:") ? String(s.dropFirst(5)) : s
        return URL(string: cleaned)?.host
    }

    /// The URL a .webloc/.inetloc/.fileloc/.url file would open.
    public static func linkTarget(_ url: URL) -> String? {
        if let d = try? Data(contentsOf: url),
           let p = try? PropertyListSerialization.propertyList(from: d, options: [], format: nil) as? [String: Any],
           let u = p["URL"] as? String {
            return u
        }
        if let s = try? String(contentsOf: url, encoding: .utf8) { return s.captures("(?m)^URL=(.+)$")?[1] }
        return nil
    }
}

// MARK: - What you can do about it

public struct FileAction: Equatable {
    public enum Kind: String {
        case open, preview, reveal, fileNow, keep, undo
        case unzip, installFont, addToCalendar, addContact, openInEditor
        case viewSource, runInTerminal, moveToApplications, openInstaller, mountImage
        case openPasswordManager, moveToSensitive, copyImage, openLink
        case importTo1Password, askAI, addRule, declineRule, dismiss, undoAll, cleanSpace, showReport
    }

    public var kind: Kind
    public var title: String
    /// When set, the action only runs after you confirm this message.
    public var confirm: String?

    public init(_ kind: Kind, _ title: String, confirm: String? = nil) {
        self.kind = kind
        self.title = title
        self.confirm = confirm
    }
}

public struct ToastModel {
    public var itemId: Int64?
    public var url: URL
    public var name: String
    public var kind: FileKind
    public var subtitle: String
    public var trust: TrustInfo
    public var suggestion: String?
    /// First is the primary action.
    public var actions: [FileAction]
    public var decision: Decision?
    public var editor: Editor?
    /// "Filed → …" receipts (bursts of these collapse into one "Undo all").
    public var isReceipt = false
    public var relatedIds: [Int64] = []
    /// Paths an action applies to (space cleanup).
    public var paths: [String] = []
    public var proposal: RuleLearner.Proposal?
    /// "Desktop › 2026-10-12" — where it will go, for display.
    public var destinationLabel: String?
    /// File it when the countdown runs out.
    public var autoFile = false

    public init(itemId: Int64?, url: URL, name: String, kind: FileKind, subtitle: String, trust: TrustInfo,
                suggestion: String?, actions: [FileAction], decision: Decision?, editor: Editor?) {
        self.itemId = itemId
        self.url = url
        self.name = name
        self.kind = kind
        self.subtitle = subtitle
        self.trust = trust
        self.suggestion = suggestion
        self.actions = actions
        self.decision = decision
        self.editor = editor
    }
}

public struct Editor: Equatable {
    public var name: String
    public var bundleId: String

    static let known: [Editor] = [
        Editor(name: "Cursor", bundleId: "com.todesktop.230313mxl4n4g"),
        Editor(name: "VS Code", bundleId: "com.microsoft.VSCode"),
        Editor(name: "Zed", bundleId: "dev.zed.Zed"),
        Editor(name: "Xcode", bundleId: "com.apple.dt.Xcode"),
    ]

    public static func installed(lookup: (String) -> Bool) -> Editor? { known.first { lookup($0.bundleId) } }
}

public enum ActionPlanner {
    public static func plan(_ f: ItemFacts, kind: FileKind, trust: TrustInfo, decision: Decision?,
                            config: Config, editor: Editor?) -> [FileAction] {
        let host = trust.originHost ?? trust.downloadedBy ?? "an unknown source"
        let runWarning = "\(f.name) was \(trust.quarantined ? "downloaded from \(host)" : "not created by you on this Mac")"
            + " and will run with your permissions. Only continue if you expected it."
        var a: [FileAction] = []

        switch kind {
        case .application:
            switch trust.gatekeeper {
            case .accepted:
                a += [FileAction(.moveToApplications, "Move to Applications"), FileAction(.open, "Open")]
            case .rejected:
                break  // no way to launch it from here
            case .notApplicable:
                a.append(FileAction(.open, "Open…", confirm: "This app isn't signed by an identified developer. " + runWarning))
            }
        case .installerPackage:
            switch trust.gatekeeper {
            case .accepted: a.append(FileAction(.openInstaller, "Install…"))
            case .rejected: break
            case .notApplicable:
                a.append(FileAction(.openInstaller, "Install…", confirm: "This package isn't signed by an identified developer. " + runWarning))
            }
        case .diskImage:
            if trust.gatekeeper != .rejected { a.append(FileAction(.mountImage, "Open disk image")) }
        case .script:
            a.append(FileAction(.viewSource, "View source"))
            a.append(FileAction(.runInTerminal, "Run in Terminal…", confirm: runWarning))
        case .linkFile:
            let target = Trust.linkTarget(f.url) ?? "an unknown target"
            let local = f.ext == "fileloc" || !(target.hasPrefix("http://") || target.hasPrefix("https://"))
            a.append(FileAction(.openLink, "Open link…", confirm: "This opens \(target)."
                + (local ? " It points at something on this Mac, which can launch apps." : "")))
        case .configProfile:
            break  // install from System Settings only, deliberately
        case .archive:
            let unsafe = Unarchiver.unsafeEntries(f.entries ?? [])
            if unsafe.isEmpty && Unarchiver.supported(f.url) {
                let n = (f.entries ?? []).filter { !$0.hasSuffix("/") }.count
                a.append(FileAction(.unzip, n > 0 ? "Unzip (\(n) files)" : "Unzip here"))
            }
            a.append(FileAction(.preview, "Preview"))
        case .font:
            a += [FileAction(.installFont, "Install font"), FileAction(.preview, "Preview")]
        case .calendar:
            a += [FileAction(.addToCalendar, "Add to Calendar"), FileAction(.preview, "Preview")]
        case .contact:
            a += [FileAction(.addContact, "Add to Contacts"), FileAction(.preview, "Preview")]
        case .credential:
            let vault = config.onePasswordVault.map { "the “\($0)” vault" } ?? "your default vault"
            a.append(FileAction(.importTo1Password, "Import to 1Password…",
                                confirm: "Creates a Document item in \(vault) from \(f.name), then moves the original to the Trash."))
            if decision?.action == .move { a.append(FileAction(.moveToSensitive, "Move to _Sensitive")) }
            a.append(FileAction(.openPasswordManager, "Open 1Password"))
        case .screenshot, .image:
            a += [FileAction(.copyImage, "Copy"), FileAction(.preview, "Preview"), FileAction(.open, "Open")]
        case .video, .audio:
            a += [FileAction(.preview, "Play"), FileAction(.open, "Open")]
        case .macroDocument:
            a.append(FileAction(.preview, "Preview"))
            a.append(FileAction(.open, "Open…", confirm: "\(f.name) contains macros. If Office asks, keep macros disabled unless you expected them."))
        case .web:
            a.append(FileAction(.preview, "Preview"))
            a.append(trust.quarantined
                ? FileAction(.open, "Open in browser…", confirm: "This page came from \(host) and will run its scripts in your browser.")
                : FileAction(.open, "Open in browser"))
        case .codeProject, .codeFile:
            if let editor { a.append(FileAction(.openInEditor, "Open in \(editor.name)")) }
            if kind == .codeFile { a.append(FileAction(.preview, "Preview")) }
        case .transcript, .pdf, .document, .model3D, .other:
            a += [FileAction(.open, "Open"), FileAction(.preview, "Preview")]
        case .folder:
            break
        }

        if let d = decision, kind != .credential {
            switch d.action {
            case .move:
                a.append(FileAction(.fileNow, "File to \(shortDestination(d, config: config))"))
            case .trash:
                a.append(FileAction(.fileNow, "Move to Trash"))
            default: break
            }
        }
        if decision?.rule == "fallback", AIAdvisor.blockReason(f, decision: decision) == nil {
            a.append(FileAction(.askAI, "Ask Claude"))
        }
        a.append(FileAction(.keep, "Keep here"))
        if !a.contains(where: { $0.kind == .reveal }) { a.append(FileAction(.reveal, "Show in Finder")) }
        return a
    }

    static func shortDestination(_ d: Decision, config: Config) -> String {
        guard let dest = d.destination else { return "library" }
        let lib = config.libraryURL.path + "/"
        let rel = dest.hasPrefix(lib) ? String(dest.dropFirst(lib.count)) : Paths.pretty(dest)
        let parts = rel.split(separator: "/")
        // "Meetings/Acme/2026-09" reads better as "Meetings/Acme"
        if parts.count > 2, String(parts.last!).matches("^(\\d{4}(-\\d{2})?|port-\\d+)$") {
            return parts.dropLast().joined(separator: "/")
        }
        return rel
    }

    /// "~/Documents/Meetings/Globex/2026-09" → "Documents › Meetings › Globex › 2026-09"
    public static func label(forDestination d: Decision) -> String? {
        guard d.action == .move, let dest = d.destination else { return d.action == .trash ? "Trash" : nil }
        let home = Paths.home + "/"
        let rel = dest.hasPrefix(home) ? String(dest.dropFirst(home.count)) : dest
        var label = rel.split(separator: "/").joined(separator: " › ")
        if let n = d.newName { label += "  as “\(n)”" }
        return label
    }

    /// Only confident, ordinary moves may happen when a countdown runs out — never trash, never risky kinds.
    public static func mayAutoFile(_ d: Decision?, kind: FileKind, trust: TrustInfo, config: Config) -> Bool {
        guard config.toastAutoFile, let d, d.action == .move, d.confidence >= 0.6 else { return false }
        guard !kind.canExecute, kind != .credential, kind != .codeProject, trust.level == .trusted else { return false }
        return !d.flags.contains("sensitive") && !d.flags.contains("alert")
    }

    public static func suggestion(_ d: Decision?, root: RootConfig?, config: Config) -> String? {
        guard let d else { return nil }
        let when: String
        if config.mode == .auto && ((d.action == .move && d.confidence >= config.autoThreshold)
            || (d.action == .trash && d.confidence >= config.trashThreshold)), let root {
            let mins = Int(root.graceSeconds / 60)
            when = root.useLastUsed ? "files \(mins)m after you're done with it" : "files in \(mins)m"
        } else {
            when = "suggested"
        }
        switch d.action {
        case .move: return "→ \(shortDestination(d, config: config)) · \(when) · \(d.reason)"
        case .trash: return "→ Trash · \(when) · \(d.reason)"
        case .hold: return "Staying put · \(d.reason)"
        case .ignore: return nil
        }
    }
}

// MARK: - Safe extraction

public enum Unarchiver {
    static let tarExts: Set<String> = ["tar", "tgz", "gz", "bz2", "tbz", "xz", "txz"]

    public static func supported(_ url: URL) -> Bool {
        let e = url.pathExtension.lowercased()
        return e == "zip" || tarExts.contains(e)
    }

    /// Entries that would land outside the destination folder.
    public static func unsafeEntries(_ entries: [String]) -> [String] {
        entries.filter { $0.hasPrefix("/") || $0.split(separator: "/").contains("..") }
    }

    /// Extracts next to the archive into a new folder. Refuses archives that escape their folder.
    public static func extract(_ url: URL) throws -> URL {
        let e = url.pathExtension.lowercased()
        var base = url.deletingPathExtension().lastPathComponent
        if base.lowercased().hasSuffix(".tar") { base = String(base.dropLast(4)) }
        let listing: [String]
        if e == "zip" {
            listing = run("/usr/bin/zipinfo", ["-1", url.path]).out.split(separator: "\n").map(String.init)
        } else if tarExts.contains(e) {
            listing = run("/usr/bin/tar", ["-tf", url.path]).out.split(separator: "\n").map(String.init)
        } else {
            throw LandfallError.action("can't unpack .\(e) safely here — use Open")
        }
        let bad = unsafeEntries(listing)
        guard bad.isEmpty else {
            throw LandfallError.action("refusing to unpack: \(bad.count) entries point outside the folder (e.g. \(bad[0]))")
        }
        let dest = Mover.uniqueURL(dir: url.deletingLastPathComponent(), name: base)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let r = e == "zip"
            ? run("/usr/bin/ditto", ["-x", "-k", url.path, dest.path], stderr: true)
            : run("/usr/bin/tar", ["-xf", url.path, "-C", dest.path], stderr: true)
        guard r.status == 0 else { throw LandfallError.action("extraction failed: \(r.out)") }
        return dest
    }
}
