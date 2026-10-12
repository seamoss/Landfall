import Foundation
import Security

/// Asks Claude where a file belongs. Sends metadata and a short excerpt only — never anything
/// flagged sensitive/noAI, never credentials — and its answers are always proposals.
public enum AIAdvisor {
    public static let maxConfidence = 0.8  // below the auto threshold: you always approve
    static let excerptChars = 1500

    public enum Refusal: Error, CustomStringConvertible {
        case notAllowed(String), noKey, api(String)
        public var description: String {
            switch self {
            case .notAllowed(let why): return "not sent to Claude: \(why)"
            case .noKey: return "no Anthropic API key — run `landfall ai-key` or add one in Settings"
            case .api(let s): return s
            }
        }
    }

    /// Why an item must not be sent, if it mustn't.
    public static func blockReason(_ f: ItemFacts, decision: Decision?) -> String? {
        if let d = decision, d.flags.contains("noAI") || d.flags.contains("sensitive") { return "flagged as private" }
        if decision?.rule == "credential" { return "contains credentials" }
        if Classifier(config: .standard).credential(f) != nil || (f.textHead?.matches("-----BEGIN") ?? false) {
            return "looks like it contains secrets"
        }
        return nil
    }

    /// The exact text that would be sent (shown by `landfall ai --dry-run`).
    public static func prompt(for f: ItemFacts, config: Config) -> String {
        var lines = [
            "File: \(f.name)",
            "Kind: \(f.uti ?? "unknown"), \(formatBytes(f.size))",
        ]
        if let host = f.origins.lazy.compactMap(Trust.host).first { lines.append("Downloaded from: \(host)") }
        if let t = f.title { lines.append("Title: \(t)") }
        if let text = f.textHead?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            lines.append("Excerpt:\n\"\"\"\n\(text.prefix(excerptChars))\n\"\"\"")
        }
        lines.append("\nExisting folders (library-relative):\n" + libraryFolders(config).map { "- \($0)" }.joined(separator: "\n"))
        lines.append("\nClients: " + config.clients.map(\.name).joined(separator: ", "))
        return lines.joined(separator: "\n")
    }

    static let system = """
    You file documents into a personal Mac library for a software consultant. Pick the single best \
    library-relative folder for the file. Prefer an existing folder; you may propose one new subfolder \
    under an existing folder when nothing fits. Never choose _Sensitive or Dev. Suggest a clearer file \
    name only when the current one is meaningless or misspelled, otherwise return an empty string. \
    Confidence is your probability (0-1) that the person would agree.
    """

    static let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "folder": ["type": "string", "description": "Library-relative folder, e.g. Personal/Vehicles"],
            "rename": ["type": "string", "description": "New file name including extension, or empty"],
            "confidence": ["type": "number"],
            "reason": ["type": "string", "description": "One short sentence"],
        ],
        "required": ["folder", "rename", "confidence", "reason"],
        "additionalProperties": false,
    ]

    public static func suggest(_ f: ItemFacts, decision: Decision?, config: Config) async throws -> Decision {
        if let why = blockReason(f, decision: decision) { throw Refusal.notAllowed(why) }
        guard let key = Keychain.apiKey() else { throw Refusal.noKey }

        let body: [String: Any] = [
            "model": config.ai.model,
            "max_tokens": 2048,
            "system": system,
            "output_config": ["effort": "low", "format": ["type": "json_schema", "schema": schema]],
            "messages": [["role": "user", "content": prompt(for: f, config: config)]],
        ]
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            let msg = (json["error"] as? [String: Any])?["message"] as? String ?? "HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)"
            throw Refusal.api("Claude API error: \(msg)")
        }
        let stop = json["stop_reason"] as? String
        guard stop != "refusal" else { throw Refusal.api("Claude declined to classify this file") }
        guard stop != "max_tokens" else { throw Refusal.api("Claude's answer was cut off") }
        let text = (json["content"] as? [[String: Any]] ?? []).first { $0["type"] as? String == "text" }?["text"] as? String
        guard let text, let out = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let folder = out["folder"] as? String else {
            throw Refusal.api("Claude's answer wasn't valid JSON")
        }
        return try validated(folder: folder, rename: out["rename"] as? String ?? "",
                            confidence: out["confidence"] as? Double ?? 0.5,
                            reason: out["reason"] as? String ?? "", f: f, config: config)
    }

    /// Validate the model's answer before it becomes a proposal.
    static func validated(folder: String, rename: String, confidence: Double, reason: String,
                         f: ItemFacts, config: Config) throws -> Decision {
        let rel = folder.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        let parts = rel.split(separator: "/").map(String.init)
        guard !rel.isEmpty, !parts.contains(".."), !parts.contains("."), !folder.hasPrefix("~"),
              parts.first != config.folders.sensitive, parts.first != config.folders.dev else {
            throw Refusal.api("Claude suggested an invalid folder (\(folder))")
        }
        var newName: String?
        let r = rename.trimmingCharacters(in: .whitespacesAndNewlines)
        if !r.isEmpty, !r.contains("/"), r != f.name {
            newName = f.url.pathExtension.isEmpty || r.hasSuffix("." + f.url.pathExtension) ? r : r + "." + f.url.pathExtension
        }
        return Decision(action: .move, destination: config.libraryURL.appendingPathComponent(rel).path, newName: newName,
                        confidence: min(max(confidence, 0), maxConfidence), rule: "ai",
                        reason: "Claude: " + reason, flags: [])
    }

    /// Two levels of the library, skipping Dev's insides and hidden folders.
    static func libraryFolders(_ config: Config) -> [String] {
        let fm = FileManager.default
        let lib = config.libraryURL
        var out: [String] = []
        for top in ((try? fm.contentsOfDirectory(atPath: lib.path)) ?? []).sorted() where !top.hasPrefix(".") {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: lib.appendingPathComponent(top).path, isDirectory: &isDir), isDir.boolValue,
                  top != config.folders.sensitive else { continue }
            out.append(top)
            if top == config.folders.dev { continue }
            for sub in ((try? fm.contentsOfDirectory(atPath: lib.appendingPathComponent(top).path)) ?? []).sorted()
            where !sub.hasPrefix(".") && !sub.matches("^\\d{4}(-\\d{2})?$") {
                var d: ObjCBool = false
                if fm.fileExists(atPath: lib.appendingPathComponent("\(top)/\(sub)").path, isDirectory: &d), d.boolValue {
                    out.append("\(top)/\(sub)")
                }
            }
        }
        return Array(out.prefix(150))
    }
}

/// The Anthropic API key lives in the login keychain, never in config.json.
public enum Keychain {
    static let service = "dev.landfall"
    static let account = "anthropic-api-key"

    public static func apiKey() -> String? {
        if let env = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !env.isEmpty { return env }
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(decoding: d, as: UTF8.self)
    }

    public static func setAPIKey(_ key: String?) throws {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        guard let key, !key.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(key.utf8)
        add[kSecAttrLabel as String] = "Landfall — Anthropic API key"
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw LandfallError.action("Keychain error \(status)") }
    }
}

/// Imports a file into 1Password as a Document item via the `op` CLI, then trashes it.
public enum OnePassword {
    public static var cli: String? {
        ["/opt/homebrew/bin/op", "/usr/local/bin/op", "/usr/bin/op"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public static let installHint = "Install the 1Password CLI (`brew install 1password-cli`), then turn on 1Password › Settings › Developer › Integrate with 1Password CLI."

    public static func importDocument(_ url: URL, vault: String?) throws {
        guard let op = cli else { throw LandfallError.action(installHint) }
        var args = ["document", "create", url.path, "--title", url.lastPathComponent, "--tags", "landfall"]
        if let vault, !vault.isEmpty { args += ["--vault", vault] }
        let r = run(op, args, stderr: true)
        guard r.status == 0 else {
            throw LandfallError.action("1Password import failed: \(r.out.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }
}
