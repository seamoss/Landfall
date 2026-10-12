import Foundation

/// Rebuildable dependency and build folders inside code projects.
public struct SpaceHit {
    public var path: String
    public var kind: String
    public var bytes: Int64
    public var repo: String?
    public var idleDays: Double?
    /// Agent worktrees are reported but never trashed automatically.
    public var reportOnly: Bool
}

public enum Space {
    static let rebuildable: Set<String> = ["node_modules", ".venv", "venv", ".next", ".turbo", ".nuxt", ".svelte-kit", ".parcel-cache"]

    public static func scan(_ roots: [URL], now: Date = Date()) -> [SpaceHit] {
        var hits: [SpaceHit] = []
        var idle: [String: Double?] = [:]
        for root in roots {
            guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                          options: [.skipsPackageDescendants]) else { continue }
            for case let u as URL in en {
                guard (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                let name = u.lastPathComponent
                let parent = u.deletingLastPathComponent()
                var kind: String?
                var reportOnly = false
                if rebuildable.contains(name) {
                    kind = name
                } else if name == "target" && fileExists(parent.appendingPathComponent("Cargo.toml").path) {
                    kind = "target (cargo)"
                } else if name == "worktrees" && parent.lastPathComponent == ".claude" {
                    kind = "agent worktrees"
                    reportOnly = true
                } else if name == ".git" {
                    en.skipDescendants()
                    continue
                }
                guard let kind else { continue }
                en.skipDescendants()
                let repo = enclosingRepo(parent.path)
                if let repo, idle[repo] == nil { idle[repo] = idleDays(repo, now: now) }
                hits.append(SpaceHit(path: u.path, kind: kind, bytes: Inspector.duBytes(u.path), repo: repo,
                                     idleDays: repo.flatMap { idle[$0] ?? nil }, reportOnly: reportOnly))
            }
        }
        return hits.sorted { $0.bytes > $1.bytes }
    }

    static func enclosingRepo(_ path: String) -> String? {
        var p = URL(fileURLWithPath: path)
        while p.path != "/" {
            if fileExists(p.appendingPathComponent(".git").path) { return p.path }
            p.deleteLastPathComponent()
        }
        return nil
    }

    static func idleDays(_ repo: String, now: Date) -> Double? {
        let r = run("/usr/bin/git", ["-C", repo, "log", "-1", "--format=%ct"])
        guard let ts = Double(r.out.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return now.timeIntervalSince(Date(timeIntervalSince1970: ts)) / 86400
    }
}
