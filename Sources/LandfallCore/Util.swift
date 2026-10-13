import Foundation

public enum LandfallError: Error, CustomStringConvertible {
    case db(String)
    case config(String)
    case action(String)

    public var description: String {
        switch self {
        case .db(let s), .config(let s), .action(let s): return s
        }
    }
}

public enum Paths {
    /// The user's real home folder — the base for watched folders, even inside the App Sandbox.
    public static let home: String = {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir { return String(cString: dir) }
        return NSHomeDirectory()
    }()

    /// Where Landfall keeps its own data: the user's home, or the app's container when sandboxed.
    public static var dataHome: String { NSHomeDirectory() }

    public static var isSandboxed: Bool { ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil }

    /// LANDFALL_HOME puts config, ledger and log in one directory (used by tests).
    static var appHome: URL? {
        ProcessInfo.processInfo.environment["LANDFALL_HOME"].map { URL(fileURLWithPath: $0) }
    }

    public static var configURL: URL {
        (appHome ?? URL(fileURLWithPath: dataHome).appendingPathComponent(".config/landfall"))
            .appendingPathComponent("config.json")
    }

    public static var ledgerURL: URL {
        (appHome ?? URL(fileURLWithPath: dataHome).appendingPathComponent("Library/Application Support/Landfall"))
            .appendingPathComponent("ledger.sqlite")
    }

    public static var logURL: URL {
        (appHome ?? URL(fileURLWithPath: dataHome).appendingPathComponent("Library/Logs/Landfall"))
            .appendingPathComponent("landfall.log")
    }

    /// `~` means the real home folder, also in the sandbox (where NSString's tilde expansion points at the container).
    public static func expand(_ p: String) -> String {
        if p == "~" { return home }
        if p.hasPrefix("~/") { return home + p.dropFirst(1) }
        return p
    }

    public static func pretty(_ p: String) -> String {
        p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p
    }
}

/// Features a build can switch off. The Mac App Store edition turns off what the sandbox or App Review won't allow.
public enum Capabilities {
    /// Run in Terminal… (needs Apple Events to Terminal).
    public static var runScripts = true
    /// Move to Applications (writes outside the user's folders).
    public static var moveToApplications = true
    /// Import to 1Password (runs the `op` command-line tool).
    public static var onePasswordCLI = true
    /// Copy fonts into ~/Library/Fonts; otherwise fonts open in Font Book.
    public static var installFontsDirectly = true
}

/// Canonical form for every path Landfall stores or compares.
public func normalize(_ p: String) -> String {
    URL(fileURLWithPath: Paths.expand(p)).resolvingSymlinksInPath().standardizedFileURL.path
}

public func fileExists(_ p: String) -> Bool { FileManager.default.fileExists(atPath: p) }

@discardableResult
public func run(_ launchPath: String, _ args: [String], stderr: Bool = false) -> (status: Int32, out: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: launchPath)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = stderr ? pipe : FileHandle.nullDevice
    do { try p.run() } catch { return (-1, "") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

/// Set by the app to deliver through Notification Center; the CLI falls back to osascript.
public var notifyHandler: ((String, String) -> Void)?

public func notify(_ title: String, _ body: String) {
    if let notifyHandler { return notifyHandler(title, body) }
    func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
    run("/usr/bin/osascript", ["-e", "display notification \"\(esc(body))\" with title \"\(esc(title))\""])
}

public enum Log {
    public static var echo = true

    public static func info(_ s: String) { write("INFO", s) }
    public static func warn(_ s: String) { write("WARN", s) }
    public static func error(_ s: String) { write("ERROR", s) }

    static func write(_ level: String, _ s: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) [\(level)] \(s)\n"
        let data = Data(line.utf8)
        if echo { FileHandle.standardError.write(data) }
        let url = Paths.logURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(data)
            try? h.close()
        } else {
            try? data.write(to: url)
        }
    }
}

extension String {
    public func matches(_ pattern: String) -> Bool {
        range(of: pattern, options: .regularExpression) != nil
    }

    /// Capture groups of the first match (index 0 is the whole match).
    public func captures(_ pattern: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return nil }
        let ns = self as NSString
        guard let m = re.firstMatch(in: self, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (0..<m.numberOfRanges).map {
            m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0))
        }
    }

    /// Case-insensitive whole-word match; underscores and punctuation count as boundaries.
    public func containsWord(_ w: String) -> Bool {
        let p = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: w) + "(?![\\p{L}\\p{N}])"
        return range(of: p, options: [.regularExpression, .caseInsensitive]) != nil
    }
}

public func parseDuration(_ s: String) -> TimeInterval? {
    guard let c = s.captures("^(\\d+(?:\\.\\d+)?)([smhdw])$"), let n = Double(c[1]) else { return nil }
    switch c[2] {
    case "s": return n
    case "m": return n * 60
    case "h": return n * 3600
    case "d": return n * 86400
    default: return n * 604800
    }
}

public func ago(_ d: Date, now: Date = Date()) -> String {
    let s = now.timeIntervalSince(d)
    if s < 60 { return "just now" }
    if s < 3600 { return "\(Int(s / 60))m ago" }
    if s < 86400 { return "\(Int(s / 3600))h ago" }
    return "\(Int(s / 86400))d ago"
}

public func formatBytes(_ n: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
}

public func formatDate(_ d: Date, _ format: String) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = format
    return f.string(from: d)
}
