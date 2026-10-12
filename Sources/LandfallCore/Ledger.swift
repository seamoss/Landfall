import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// One thing that landed in a watched folder, followed wherever it goes afterwards.
public struct Item {
    public var id: Int64
    public var name: String
    public var kind: String
    public var root: String
    /// Current known location.
    public var path: String
    /// pending · proposed · held · filed · trashed · kept · elsewhere · gone
    public var status: String
    public var firstSeen: Date
    public var hash: String?
    public var size: Int64
    public var inode: Int64
    public var origin: String?
    public var bookmark: Data?
    public var decision: Decision?
    public var updated: Date

    init(_ r: [String: Any]) {
        id = r["id"] as? Int64 ?? 0
        name = r["name"] as? String ?? ""
        kind = r["kind"] as? String ?? "file"
        root = r["root"] as? String ?? ""
        path = r["path"] as? String ?? ""
        status = r["status"] as? String ?? ""
        firstSeen = Date(timeIntervalSince1970: r["first_seen"] as? Double ?? 0)
        hash = r["hash"] as? String
        size = r["size"] as? Int64 ?? 0
        inode = r["inode"] as? Int64 ?? 0
        origin = r["origin"] as? String
        bookmark = r["bookmark"] as? Data
        decision = (r["decision"] as? String).flatMap(Decision.from(json:))
        updated = Date(timeIntervalSince1970: r["updated"] as? Double ?? 0)
    }
}

public struct Event {
    public var id: Int64
    public var itemId: Int64
    public var ts: Date
    /// arrived · relocated · proposed · held · moved · trashed · undo · kept · corrected · gone · error
    public var type: String
    public var src: String?
    public var dst: String?
    public var rule: String?
    public var confidence: Double?
    public var reason: String?
    public var applied: Bool
    public var undone: Bool

    init(_ r: [String: Any]) {
        id = r["id"] as? Int64 ?? 0
        itemId = r["item_id"] as? Int64 ?? 0
        ts = Date(timeIntervalSince1970: r["ts"] as? Double ?? 0)
        type = r["type"] as? String ?? ""
        src = r["src"] as? String
        dst = r["dst"] as? String
        rule = r["rule"] as? String
        confidence = r["confidence"] as? Double
        reason = r["reason"] as? String
        applied = (r["applied"] as? Int64 ?? 0) != 0
        undone = (r["undone"] as? Int64 ?? 0) != 0
    }
}

public final class Ledger {
    private var db: OpaquePointer?

    public init(path: URL) throws {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open(path.path, &db) == SQLITE_OK else {
            throw LandfallError.db("Couldn't open ledger at \(path.path)")
        }
        sqlite3_busy_timeout(db, 5000)
        try exec("PRAGMA journal_mode=WAL")
        try exec("""
            CREATE TABLE IF NOT EXISTS items(
              id INTEGER PRIMARY KEY,
              name TEXT NOT NULL, kind TEXT, root TEXT, path TEXT NOT NULL, status TEXT NOT NULL,
              first_seen REAL NOT NULL, hash TEXT, size INTEGER, inode INTEGER, uti TEXT, origin TEXT,
              bookmark BLOB, decision TEXT, updated REAL)
            """)
        try exec("""
            CREATE TABLE IF NOT EXISTS events(
              id INTEGER PRIMARY KEY,
              item_id INTEGER NOT NULL REFERENCES items(id),
              ts REAL NOT NULL, type TEXT NOT NULL, src TEXT, dst TEXT, rule TEXT, confidence REAL,
              reason TEXT, applied INTEGER DEFAULT 0, undone INTEGER DEFAULT 0)
            """)
        try exec("CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT)")
        // Full-text search over names, document text and OCR'd screenshots. Secrets are never indexed.
        try exec("CREATE VIRTUAL TABLE IF NOT EXISTS content USING fts5(name, body, item_id UNINDEXED, tokenize='unicode61 remove_diacritics 2')")
        try exec("CREATE INDEX IF NOT EXISTS items_path ON items(path)")
        try exec("CREATE INDEX IF NOT EXISTS items_hash ON items(hash)")
        try exec("CREATE INDEX IF NOT EXISTS items_inode ON items(inode)")
        try exec("CREATE INDEX IF NOT EXISTS events_item ON events(item_id)")
    }

    deinit { sqlite3_close(db) }

    // MARK: - Items

    @discardableResult
    public func insertItem(name: String, kind: String, root: String, path: String, inode: Int64, size: Int64,
                           firstSeen: Date, bookmark: Data?) -> Int64 {
        (try? exec("""
            INSERT INTO items(name, kind, root, path, status, first_seen, inode, size, bookmark, updated)
            VALUES(?,?,?,?,'pending',?,?,?,?,?)
            """, [name, kind, root, path, firstSeen, inode, size, bookmark, Date()])) ?? 0
    }

    public func update(_ id: Int64, _ fields: [String: Any?]) {
        guard !fields.isEmpty else { return }
        let keys = Array(fields.keys)
        let sets = keys.map { "\($0)=?" }.joined(separator: ", ")
        var args: [Any?] = keys.map { fields[$0] ?? nil }
        args.append(Date())
        args.append(id)
        do { try exec("UPDATE items SET \(sets), updated=? WHERE id=?", args) } catch { Log.error("\(error)") }
    }

    public func item(_ id: Int64) -> Item? {
        rows("SELECT * FROM items WHERE id=?", [id]).first.map(Item.init)
    }

    /// The live item at this path (anything not trashed or gone).
    public func activeItem(atPath path: String) -> Item? {
        rows("SELECT * FROM items WHERE path=? AND status NOT IN ('gone','trashed') ORDER BY id DESC LIMIT 1", [path])
            .first.map(Item.init)
    }

    public func items(withHash hash: String) -> [Item] {
        rows("SELECT * FROM items WHERE hash=? AND status NOT IN ('gone','trashed') ORDER BY id", [hash]).map(Item.init)
    }

    public func items(withInode inode: Int64) -> [Item] {
        guard inode != 0 else { return [] }
        return rows("SELECT * FROM items WHERE inode=? AND status != 'trashed' ORDER BY id DESC", [inode]).map(Item.init)
    }

    public func items(statuses: [String]) -> [Item] {
        let q = statuses.map { _ in "?" }.joined(separator: ",")
        return rows("SELECT * FROM items WHERE status IN (\(q)) ORDER BY first_seen DESC", statuses).map(Item.init)
    }

    public func recent(since: Date, root: String? = nil) -> [Item] {
        if let root {
            return rows("SELECT * FROM items WHERE first_seen>=? AND root=? AND status != 'ignored' ORDER BY first_seen DESC",
                        [since, root]).map(Item.init)
        }
        return rows("SELECT * FROM items WHERE first_seen>=? AND status != 'ignored' ORDER BY first_seen DESC", [since])
            .map(Item.init)
    }

    public func search(_ q: String) -> [Item] {
        let like = "%\(q)%"
        return rows("""
            SELECT DISTINCT items.* FROM items LEFT JOIN events ON events.item_id = items.id
            WHERE items.name LIKE ? OR items.path LIKE ? OR events.src LIKE ?
            ORDER BY items.first_seen DESC LIMIT 50
            """, [like, like, like]).map(Item.init)
    }

    public func count(status: String) -> Int {
        Int(rows("SELECT COUNT(*) AS n FROM items WHERE status=?", [status]).first?["n"] as? Int64 ?? 0)
    }

    // MARK: - Events

    @discardableResult
    public func addEvent(_ itemId: Int64, _ type: String, src: String? = nil, dst: String? = nil, rule: String? = nil,
                         confidence: Double? = nil, reason: String? = nil, applied: Bool = false) -> Int64 {
        (try? exec("""
            INSERT INTO events(item_id, ts, type, src, dst, rule, confidence, reason, applied)
            VALUES(?,?,?,?,?,?,?,?,?)
            """, [itemId, Date(), type, src, dst, rule, confidence, reason, applied])) ?? 0
    }

    public func events(for itemId: Int64) -> [Event] {
        rows("SELECT * FROM events WHERE item_id=? ORDER BY id", [itemId]).map(Event.init)
    }

    public func events(since: Date, types: [String]) -> [Event] {
        let q = types.map { _ in "?" }.joined(separator: ",")
        return rows("SELECT * FROM events WHERE ts>=? AND type IN (\(q)) ORDER BY id", [since] + types).map(Event.init)
    }

    public func lastApplied(_ itemId: Int64) -> Event? {
        rows("""
            SELECT * FROM events WHERE item_id=? AND applied=1 AND undone=0 AND type IN ('moved','trashed')
            ORDER BY id DESC LIMIT 1
            """, [itemId]).first.map(Event.init)
    }

    public func lastAppliedOverall() -> Event? {
        rows("SELECT * FROM events WHERE applied=1 AND undone=0 AND type IN ('moved','trashed') ORDER BY id DESC LIMIT 1")
            .first.map(Event.init)
    }

    public func markUndone(_ eventId: Int64) {
        try? exec("UPDATE events SET undone=1 WHERE id=?", [eventId])
    }

    // MARK: - Meta

    public func meta(_ key: String) -> String? {
        rows("SELECT value FROM meta WHERE key=?", [key]).first?["value"] as? String
    }

    public func setMeta(_ key: String, _ value: String?) {
        if let value {
            try? exec("INSERT INTO meta(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [key, value])
        } else {
            try? exec("DELETE FROM meta WHERE key=?", [key])
        }
    }

    // MARK: - Full-text search

    public func index(_ itemId: Int64, name: String, body: String) {
        try? exec("DELETE FROM content WHERE item_id=?", [itemId])
        try? exec("INSERT INTO content(name, body, item_id) VALUES(?,?,?)", [name, body, itemId])
    }

    public func unindex(_ itemId: Int64) {
        try? exec("DELETE FROM content WHERE item_id=?", [itemId])
    }

    /// Items whose name or content matches; each with a short snippet.
    public func searchContent(_ q: String, limit: Int = 30) -> [(item: Item, snippet: String)] {
        let terms = q.split(whereSeparator: { $0.isWhitespace })
            .map { "\"" + $0.replacingOccurrences(of: "\"", with: "") + "\"*" }
            .joined(separator: " ")
        guard !terms.isEmpty else { return [] }
        let hits = rows("""
            SELECT item_id, snippet(content, 1, '«', '»', '…', 12) AS snip FROM content
            WHERE content MATCH ? ORDER BY rank LIMIT ?
            """, [terms, limit])
        return hits.compactMap { r in
            guard let id = r["item_id"] as? Int64, let it = item(id) else { return nil }
            return (it, (r["snip"] as? String ?? "").replacingOccurrences(of: "\n", with: " "))
        }
    }

    // MARK: - SQLite plumbing

    @discardableResult
    func exec(_ sql: String, _ args: [Any?] = []) throws -> Int64 {
        let stmt = try prepare(sql, args)
        defer { sqlite3_finalize(stmt) }
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            throw LandfallError.db(String(cString: sqlite3_errmsg(db)))
        }
        return sqlite3_last_insert_rowid(db)
    }

    func rows(_ sql: String, _ args: [Any?] = []) -> [[String: Any]] {
        guard let stmt = try? prepare(sql, args) else { return [] }
        defer { sqlite3_finalize(stmt) }
        var out: [[String: Any]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            var row: [String: Any] = [:]
            for i in 0..<sqlite3_column_count(stmt) {
                let name = String(cString: sqlite3_column_name(stmt, i))
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_INTEGER: row[name] = sqlite3_column_int64(stmt, i)
                case SQLITE_FLOAT: row[name] = sqlite3_column_double(stmt, i)
                case SQLITE_TEXT: row[name] = String(cString: sqlite3_column_text(stmt, i))
                case SQLITE_BLOB:
                    if let p = sqlite3_column_blob(stmt, i) {
                        row[name] = Data(bytes: p, count: Int(sqlite3_column_bytes(stmt, i)))
                    }
                default: break
                }
            }
            out.append(row)
        }
        return out
    }

    private func prepare(_ sql: String, _ args: [Any?]) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw LandfallError.db(String(cString: sqlite3_errmsg(db)))
        }
        for (i, arg) in args.enumerated() {
            let idx = Int32(i + 1)
            guard let a = arg else { sqlite3_bind_null(stmt, idx); continue }
            switch a {
            case let v as Bool: sqlite3_bind_int64(stmt, idx, v ? 1 : 0)
            case let v as Int64: sqlite3_bind_int64(stmt, idx, v)
            case let v as Int: sqlite3_bind_int64(stmt, idx, Int64(v))
            case let v as Double: sqlite3_bind_double(stmt, idx, v)
            case let v as Date: sqlite3_bind_double(stmt, idx, v.timeIntervalSince1970)
            case let v as String: sqlite3_bind_text(stmt, idx, v, -1, SQLITE_TRANSIENT)
            case let v as Data:
                if v.isEmpty {
                    sqlite3_bind_zeroblob(stmt, idx, 0)
                } else {
                    _ = v.withUnsafeBytes { sqlite3_bind_blob(stmt, idx, $0.baseAddress, Int32(v.count), SQLITE_TRANSIENT) }
                }
            default: sqlite3_bind_null(stmt, idx)
            }
        }
        return stmt
    }
}
