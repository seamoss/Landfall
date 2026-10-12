import Foundation

/// File operations. Nothing here deletes: "trash" means the macOS Trash.
public enum Mover {
    /// `name`, or `name 2`, `name 3`… if something is already there.
    public static func uniqueURL(dir: URL, name: String) -> URL {
        let first = dir.appendingPathComponent(name)
        guard fileExists(first.path) else { return first }
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        for i in 2... {
            let candidate = dir.appendingPathComponent(ext.isEmpty ? "\(base) \(i)" : "\(base) \(i).\(ext)")
            if !fileExists(candidate.path) { return candidate }
        }
        return first
    }

    public static func move(_ src: URL, toDir: URL, name: String? = nil) throws -> URL {
        try FileManager.default.createDirectory(at: toDir, withIntermediateDirectories: true)
        let dst = uniqueURL(dir: toDir, name: name ?? src.lastPathComponent)
        try FileManager.default.moveItem(at: src, to: dst)
        return dst
    }

    public static func trash(_ src: URL) throws -> URL {
        var out: NSURL?
        try FileManager.default.trashItem(at: src, resultingItemURL: &out)
        return (out as URL?) ?? src
    }

    public static func bookmark(_ path: String) -> Data? {
        try? URL(fileURLWithPath: path).bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// Where a bookmarked item is now, or nil if it no longer exists.
    public static func resolve(_ data: Data) -> String? {
        var stale = false
        guard let u = try? URL(resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting],
                               relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        return fileExists(u.path) ? normalize(u.path) : nil
    }
}
