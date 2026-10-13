import CoreServices
import CryptoKit
import Foundation
import PDFKit
import UniformTypeIdentifiers

/// Everything Landfall knows about one item before deciding what to do with it.
public struct ItemFacts {
    public var url: URL
    public var isDir = false
    public var isPackage = false
    public var size: Int64 = 0
    public var inode: UInt64 = 0
    public var uti: String?
    public var hash: String?
    public var origins: [String] = []
    public var isScreenshot = false
    public var added: Date?
    public var lastUsed: Date?
    public var modified: Date?
    public var title: String?
    public var textHead: String?
    /// Zip entries, or relative file paths inside a folder.
    public var entries: [String]?
    public var isGitRepo = false
    public var gitDirty = false
    /// `git` couldn't run (e.g. in the App Sandbox), so uncommitted changes are unknown.
    public var gitUnknown = false
    public var tags: [String] = []
    /// Calendar events around the time it arrived (filled in by the engine).
    public var meetings: [Meeting] = []
    /// Text recognized in an image.
    public var ocrText: String?

    public init(url: URL) { self.url = url }

    public var name: String { url.lastPathComponent }
    public var ext: String { url.pathExtension.lowercased() }
    public var base: String { url.deletingPathExtension().lastPathComponent }
}

public enum Inspector {
    static let textExts: Set<String> = [
        "txt", "md", "markdown", "json", "csv", "tsv", "log", "yaml", "yml", "toml", "env", "pem", "key",
        "html", "htm", "xml", "gs", "js", "ts", "py", "sh", "ini", "cfg", "conf", "srt", "vtt",
    ]
    static let richTextExts: Set<String> = ["docx", "doc", "rtf", "odt"]
    static let headLimit = 16000

    /// Cheap stat-level facts, safe to call on every file-system event.
    public static func quick(_ url: URL) -> ItemFacts? {
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isPackageKey, .fileSizeKey, .addedToDirectoryDateKey,
            .contentModificationDateKey, .tagNamesKey, .contentTypeKey,
        ]
        guard let v = try? url.resourceValues(forKeys: keys) else { return nil }
        var f = ItemFacts(url: url)
        f.isDir = v.isDirectory ?? false
        f.isPackage = v.isPackage ?? false
        f.size = Int64(v.fileSize ?? 0)
        f.added = v.addedToDirectoryDate
        f.modified = v.contentModificationDate
        f.tags = v.tagNames ?? []
        f.uti = v.contentType?.identifier
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let ino = attrs[.systemFileNumber] as? NSNumber {
            f.inode = ino.uint64Value
        }
        return f
    }

    /// Full inspection: hash, Spotlight metadata, content excerpt, archive listing, git state.
    public static func full(_ url: URL, hash: Bool = true) -> ItemFacts? {
        guard var f = quick(url) else { return nil }
        let path = url.path
        if f.isDir { f.size = duBytes(path) }
        if hash && !f.isDir && f.size <= 4 << 30 { f.hash = sha256(url) }

        let md = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL)
        func mdValue(_ key: String) -> Any? {
            guard let md else { return nil }
            return MDItemCopyAttribute(md, key as CFString)
        }
        f.origins = (mdValue("kMDItemWhereFroms") as? [String])
            ?? (plistXattr(path, "com.apple.metadata:kMDItemWhereFroms") as? [String]) ?? []
        f.isScreenshot = (mdValue("kMDItemIsScreenCapture") as? Bool)
            ?? (plistXattr(path, "com.apple.metadata:kMDItemIsScreenCapture") as? Bool) ?? false
        f.lastUsed = lastUsedXattr(path) ?? (mdValue("kMDItemLastUsedDate") as? Date)
        f.title = (mdValue("kMDItemTitle") as? String).flatMap { $0.isEmpty ? nil : $0 }

        if !f.isDir {
            let isText = textExts.contains(f.ext)
                || (f.uti.flatMap { UTType($0) }?.conforms(to: .plainText) ?? false)
            if isText {
                f.textHead = readHead(url)
            } else if f.ext == "pdf" {
                readPDF(url, into: &f)
            } else if richTextExts.contains(f.ext) {
                let r = run("/usr/bin/textutil", ["-convert", "txt", "-stdout", path])
                if r.status == 0 { f.textHead = String(r.out.prefix(headLimit)) }
            }
            if f.ext == "zip" {
                let r = run("/usr/bin/zipinfo", ["-1", path])
                if r.status == 0 {
                    f.entries = Array(r.out.split(separator: "\n").map(String.init).prefix(5000))
                }
            }
        } else if !f.isPackage {
            f.isGitRepo = fileExists(url.appendingPathComponent(".git").path)
            if f.isGitRepo {
                let r = run("/usr/bin/git", ["-C", path, "status", "--porcelain"], stderr: true)
                if r.status == -1 || r.out.contains("App Sandbox") || r.out.contains("xcrun: error") {
                    f.gitUnknown = true
                } else {
                    f.gitDirty = r.status != 0 || !r.out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
            }
            f.entries = listFiles(url, limit: 5000)
        }
        return f
    }

    /// When you last opened it. The xattr is the real record; Spotlight's value falls back to creation time.
    public static func lastUsed(_ url: URL) -> Date? {
        if let d = lastUsedXattr(url.path) { return d }
        if let md = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL),
           let d = MDItemCopyAttribute(md, "kMDItemLastUsedDate" as CFString) as? Date {
            return d
        }
        return lastUsedXattr(url.path)
    }

    public static func sha256(_ url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try? h.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Relative paths of files under `url`, skipping .DS_Store, .git and dependency folders.
    public static func listFiles(_ url: URL, limit: Int) -> [String] {
        let base = url.resolvingSymlinksInPath().path
        guard let en = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey],
                                                      options: [.skipsPackageDescendants]) else { return [] }
        var out: [String] = []
        for case let u as URL in en {
            let name = u.lastPathComponent
            if name == ".DS_Store" { continue }
            let isDir = (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                if [".git", "node_modules", ".venv"].contains(name) { en.skipDescendants() }
                continue
            }
            let p = u.resolvingSymlinksInPath().path
            guard p.hasPrefix(base + "/") else { continue }
            out.append(String(p.dropFirst(base.count + 1)).precomposedStringWithCanonicalMapping)
            if out.count >= limit { break }
        }
        return out
    }

    public static func duBytes(_ path: String) -> Int64 {
        let r = run("/usr/bin/du", ["-sk", path])
        guard let kb = r.out.split(separator: "\t").first.flatMap({ Int64($0.trimmingCharacters(in: .whitespaces)) })
        else { return 0 }
        return kb * 1024
    }

    public static func xattr(_ path: String, _ name: String) -> Data? {
        let len = getxattr(path, name, nil, 0, 0, 0)
        guard len > 0 else { return nil }
        var data = Data(count: len)
        let r = data.withUnsafeMutableBytes { getxattr(path, name, $0.baseAddress, len, 0, 0) }
        return r > 0 ? data : nil
    }

    static func plistXattr(_ path: String, _ name: String) -> Any? {
        guard let d = xattr(path, name) else { return nil }
        return try? PropertyListSerialization.propertyList(from: d, options: [], format: nil)
    }

    /// `com.apple.lastuseddate#PS` holds a raw timespec.
    static func lastUsedXattr(_ path: String) -> Date? {
        guard let d = xattr(path, "com.apple.lastuseddate#PS"), d.count >= 8 else { return nil }
        let secs = d.withUnsafeBytes { $0.loadUnaligned(as: Int64.self) }
        return secs > 0 ? Date(timeIntervalSince1970: TimeInterval(secs)) : nil
    }

    static func readHead(_ url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let d = try? h.read(upToCount: 64 * 1024) else { return nil }
        return String(decoding: d, as: UTF8.self)
    }

    static func readPDF(_ url: URL, into f: inout ItemFacts) {
        guard let doc = PDFDocument(url: url) else { return }
        if f.title == nil, let t = doc.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String, !t.isEmpty {
            f.title = t
        }
        var s = ""
        for i in 0..<min(doc.pageCount, 3) {
            s += doc.page(at: i)?.string ?? ""
            if s.count > headLimit { break }
        }
        f.textHead = String(s.prefix(headLimit))
    }
}
