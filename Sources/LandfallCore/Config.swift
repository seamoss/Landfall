import Foundation

public enum Mode: String, Codable, CaseIterable {
    /// Log what would happen; never touch files.
    case shadow
    /// Propose everything; act only on `landfall apply`.
    case review
    /// Act on confident decisions; propose the rest.
    case auto
}

public enum RootRole: String, Codable {
    /// Things pass through (Downloads). Short grace period.
    case intake
    /// Working surface (Desktop). Items stay while in use.
    case shelf
    /// The library itself (Documents). Only loose top-level files are touched.
    case library
}

/// Where a watched folder's items get filed.
public struct Filing: Codable, Equatable {
    public enum Mode: String, Codable { case library, inPlace }
    public var mode: Mode
    /// Base folder for in-place filing; defaults to the watched folder itself.
    public var folder: String?
    /// Subfolder pattern: {yyyy-mm-dd} {yyyy-mm} {yyyy} {category} {path}.
    public var layout: String

    public init(mode: Mode = .library, folder: String? = nil, layout: String = "{yyyy-mm-dd}") {
        self.mode = mode
        self.folder = folder
        self.layout = layout
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = try c.decodeIfPresent(Mode.self, forKey: .mode) ?? .library
        folder = try c.decodeIfPresent(String.self, forKey: .folder)
        layout = try c.decodeIfPresent(String.self, forKey: .layout) ?? "{yyyy-mm-dd}"
    }
}

public struct RootConfig: Codable, Equatable {
    public var name: String
    public var path: String
    public var role: RootRole
    public var graceSeconds: Double
    /// Count the grace period from the last time the item was opened.
    public var useLastUsed: Bool
    public var neverTouch: [String]
    /// Items nobody filed or opened for this many days go to the Trash (intake roots).
    public var expireDays: Double?
    public var filing: Filing

    public init(name: String, path: String, role: RootRole, graceSeconds: Double, useLastUsed: Bool = false,
                neverTouch: [String] = [], expireDays: Double? = nil, filing: Filing = Filing()) {
        self.name = name
        self.path = path
        self.role = role
        self.graceSeconds = graceSeconds
        self.useLastUsed = useLastUsed
        self.neverTouch = neverTouch
        self.expireDays = expireDays
        self.filing = filing
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        path = try c.decode(String.self, forKey: .path)
        role = try c.decodeIfPresent(RootRole.self, forKey: .role) ?? .intake
        graceSeconds = try c.decodeIfPresent(Double.self, forKey: .graceSeconds) ?? 300
        useLastUsed = try c.decodeIfPresent(Bool.self, forKey: .useLastUsed) ?? false
        neverTouch = try c.decodeIfPresent([String].self, forKey: .neverTouch) ?? []
        expireDays = try c.decodeIfPresent(Double.self, forKey: .expireDays)
        filing = try c.decodeIfPresent(Filing.self, forKey: .filing) ?? Filing()
    }

    public var url: URL { URL(fileURLWithPath: normalize(path)) }
}

public struct ClientConfig: Codable, Equatable {
    public var name: String
    public var aliases: [String]
    public var people: [String]
    public var domains: [String]
    /// Library-relative folder; defaults to Clients/<name>.
    public var folder: String?

    public init(name: String, aliases: [String] = [], people: [String] = [], domains: [String] = [], folder: String? = nil) {
        self.name = name
        self.aliases = aliases
        self.people = people
        self.domains = domains
        self.folder = folder
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        aliases = try c.decodeIfPresent([String].self, forKey: .aliases) ?? []
        people = try c.decodeIfPresent([String].self, forKey: .people) ?? []
        domains = try c.decodeIfPresent([String].self, forKey: .domains) ?? []
        folder = try c.decodeIfPresent(String.self, forKey: .folder)
    }

    public var folderPath: String { folder ?? "Clients/\(name)" }
}

/// A user rule. Every condition that is set must match; a rule with no conditions never matches.
public struct RuleConfig: Codable, Equatable {
    public var name: String
    public var nameRegex: String?
    public var extensions: [String]?
    public var contentRegex: String?
    public var originRegex: String?
    public var participantsAny: [String]?
    public var root: String?
    /// Library-relative destination. Supports {yyyy} {mm} {yyyy-mm} {client}.
    public var to: String?
    /// move (default) | trash | hold | ignore
    public var action: String?
    /// Supports {date} {title} {name} {base} {ext}.
    public var rename: String?
    public var confidence: Double?

    public init(name: String, nameRegex: String? = nil, extensions: [String]? = nil, contentRegex: String? = nil,
                originRegex: String? = nil, participantsAny: [String]? = nil, root: String? = nil, to: String? = nil,
                action: String? = nil, rename: String? = nil, confidence: Double? = nil) {
        self.name = name
        self.nameRegex = nameRegex
        self.extensions = extensions
        self.contentRegex = contentRegex
        self.originRegex = originRegex
        self.participantsAny = participantsAny
        self.root = root
        self.to = to
        self.action = action
        self.rename = rename
        self.confidence = confidence
    }

    var hasConditions: Bool {
        nameRegex != nil || extensions != nil || contentRegex != nil || originRegex != nil || participantsAny != nil
    }
}

/// Library-relative folder names.
public struct Folders: Codable, Equatable {
    public var sensitive = "_Sensitive"
    public var meetings = "Meetings"
    public var screenshots = "Screenshots"
    public var devCaptures = "Screenshots/Dev Captures"
    public var designBrand = "Design & Brand"
    public var logos = "Design & Brand/Logos"
    public var fonts = "Design & Brand/Fonts"
    public var images = "Images"
    public var music = "Music"
    public var personal = "Personal"
    public var personalMedia = "Personal/Media"
    public var hiring = "Personal/Hiring"
    public var contacts = "Personal/Contacts"
    public var making = "Personal/Making"
    public var dev = "Dev"
    public var unassigned = "Clients/_Unassigned"
    public var contracts = "Contracts"
    public var data = "Data"

    public init() {}
}

/// Smart Filing: an opt-in, bring-your-own-key add-on that reads what's inside a file and picks its home.
public struct AIConfig: Codable, Equatable {
    public enum Scope: String, Codable, CaseIterable {
        /// Only items Landfall's own rules aren't confident about.
        case unsure
        /// Every document with readable text (rules for secrets, duplicates, installers etc. still win).
        case documents
    }

    public var enabled: Bool = false
    public var scope: Scope = .unsure
    /// Off: Smart Filing's picks are suggestions. On: confident picks file like any other decision.
    public var autoFile: Bool = false
    /// How much of the file's text is sent.
    public var excerptChars: Int = 1500
    public var model: String = "claude-haiku-5-5"

    public init() {}
}

public struct Config: Codable {
    public var mode: Mode
    public var library: String
    public var ownerNames: [String]
    public var autoThreshold: Double
    public var trashThreshold: Double
    public var settleSeconds: Double
    public var recentShelf: String?
    public var recentDays: Double
    public var notify: Bool
    /// Show an actionable toast when something new lands.
    public var toasts: Bool
    public var toastSeconds: Double
    /// When a toast's countdown runs out, file the item (confident, ordinary moves only).
    public var toastAutoFile: Bool
    /// How long the auto-file countdown runs before it files the item.
    public var autoFileSeconds: Double
    /// Use the meeting you were in when a file arrived to pick its client.
    public var useCalendar: Bool
    public var ai: AIConfig
    /// 1Password vault for imported credentials (nil = your default vault).
    public var onePasswordVault: String?
    /// Monday-morning report of rebuildable folders.
    public var spaceReport: Bool
    public var spaceRoots: [String]
    public var spaceIdleDays: Double
    public var folders: Folders
    public var roots: [RootConfig]
    public var clients: [ClientConfig]
    public var rules: [RuleConfig]

    public static var standard: Config {
        Config(
            mode: .shadow,
            library: "~/Documents",
            ownerNames: [],
            autoThreshold: 0.85,
            trashThreshold: 0.9,
            settleSeconds: 5,
            recentShelf: "~/Desktop/Recent Landings",
            recentDays: 7,
            notify: true,
            toasts: true,
            toastSeconds: 20,
            toastAutoFile: true,
            autoFileSeconds: 20,
            useCalendar: true,
            ai: AIConfig(),
            onePasswordVault: nil,
            spaceReport: true,
            spaceRoots: ["~/Documents/Dev"],
            spaceIdleDays: 30,
            folders: Folders(),
            roots: [
                RootConfig(name: "downloads", path: "~/Downloads", role: .intake, graceSeconds: 300, expireDays: 30),
                RootConfig(name: "desktop", path: "~/Desktop", role: .shelf, graceSeconds: 7200, useLastUsed: true,
                           filing: Filing(mode: .inPlace, layout: "{yyyy-mm-dd}")),
                RootConfig(name: "documents", path: "~/Documents", role: .library, graceSeconds: 1800, useLastUsed: true,
                           neverTouch: ["Dev", "Cleanout"]),
            ],
            clients: [],
            rules: []
        )
    }

    /// The starting config written by `landfall init` and on first launch. Personal details
    /// (your name, your clients) are added in Settings and live only in your config file.
    public static func seeded() -> Config {
        var c = standard
        c.rules = [
            RuleConfig(name: "Phone videos by year", nameRegex: "^(\\d{8}_\\d{6}|PXL_|IMG_\\d+)",
                       extensions: ["mp4", "mov"], to: "Personal/Media/{yyyy}"),
        ]
        return c
    }

    public var libraryURL: URL { URL(fileURLWithPath: normalize(library)) }

    public func root(named n: String) -> RootConfig? { roots.first { $0.name == n } }

    /// Missing keys fall back to `standard`, so a hand-written config can be partial.
    public static func load(from url: URL = Paths.configURL) throws -> Config {
        guard fileExists(url.path) else { return standard }
        do {
            let user = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
            let base = try JSONSerialization.jsonObject(with: JSONEncoder().encode(standard))
            let merged = mergeJSON(base, user)
            return try JSONDecoder().decode(Config.self, from: JSONSerialization.data(withJSONObject: merged))
        } catch {
            throw LandfallError.config("Couldn't read \(Paths.pretty(url.path)): \(error)")
        }
    }

    public func save(to url: URL = Paths.configURL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try enc.encode(self).write(to: url, options: .atomic)
    }

    /// Append a rule to the user's file without rewriting the rest of it.
    public static func appendRule(_ rule: RuleConfig, at url: URL = Paths.configURL) throws {
        var obj: [String: Any] = [:]
        if fileExists(url.path) {
            obj = (try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]) ?? [:]
        }
        let ruleObj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(rule))
        obj["rules"] = ((obj["rules"] as? [Any]) ?? []) + [ruleObj]
        try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            .write(to: url, options: .atomic)
    }

    /// Change one top-level key in the user's file without rewriting the rest.
    public static func set(_ key: String, _ value: Any, at url: URL = Paths.configURL) throws {
        var obj: [String: Any] = [:]
        if fileExists(url.path) {
            obj = (try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]) ?? [:]
        }
        obj[key] = value
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            .write(to: url, options: .atomic)
    }
}

func mergeJSON(_ a: Any, _ b: Any) -> Any {
    guard let da = a as? [String: Any], let db = b as? [String: Any] else { return b }
    var out = da
    for (k, v) in db {
        out[k] = da[k].map { mergeJSON($0, v) } ?? v
    }
    return out
}
