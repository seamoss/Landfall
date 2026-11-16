import Foundation

/// What to do with one thing sitting in a dated Desktop folder.
public enum OrganizerChoice: Equatable {
    /// Into the library for good (an absolute folder).
    case file(String)
    case trash
    case leave
}

/// One file or folder inside a Landfall filing folder (e.g. `Desktop/2026-10-12/`), with a suggestion.
public struct OrganizerEntry: Identifiable, Equatable {
    public var id: String { path }
    public let path: String
    public let name: String
    /// The dated folder it's in, e.g. "2026-10-12".
    public let cabinet: String
    public let itemId: Int64?
    public let kindLabel: String
    public let size: Int64
    public let suggestion: OrganizerChoice
    /// Why: the rule's reason, or why there's no suggestion.
    public let reason: String
    public let rule: String
    public let confidence: Double

    public init(path: String, name: String, cabinet: String, itemId: Int64?, kindLabel: String, size: Int64,
                suggestion: OrganizerChoice, reason: String, rule: String, confidence: Double) {
        self.path = path
        self.name = name
        self.cabinet = cabinet
        self.itemId = itemId
        self.kindLabel = kindLabel
        self.size = size
        self.suggestion = suggestion
        self.reason = reason
        self.rule = rule
        self.confidence = confidence
    }
}

/// The Organizer finishes what the Desktop's dated folders started: everything in them either goes
/// into the library for good or to the Trash. Suggestions come from the same rules, asked where the
/// item would go if the Desktop filed into the library. Nothing moves until you apply it, and every
/// move is an ordinary recorded, undoable event.
extension Engine {
    /// Landfall's own filing folders in every watched folder that files in place.
    public func cabinets() -> [URL] {
        var out: [URL] = []
        for r in config.roots where r.filing.mode == .inPlace {
            let base = URL(fileURLWithPath: r.filing.folder.map(normalize) ?? r.url.path)
            let kids = (try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            out += kids.filter { Inspector.xattr($0.path, Classifier.cabinetMarker) != nil }
                .map { URL(fileURLWithPath: normalize($0.path)) }
                .filter { config.ignoredFolder(containing: $0.path) == nil }
        }
        return out.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Everything in the filing folders, oldest folder first, each with a suggestion.
    public func organizerEntries() -> [OrganizerEntry] {
        organizerList().compactMap { organizerEntry($0.url, cabinet: $0.cabinet) }
    }

    /// What's in the filing folders, without looking inside anything yet (fast), so a window can
    /// show progress while `organizerEntry` reads each one.
    public func organizerList() -> [(url: URL, cabinet: String)] {
        cabinets().flatMap { cab in organizerItems(in: cab).map { (url: $0, cabinet: cab.lastPathComponent) } }
    }

    /// Files, and folders Landfall filed as one item (projects, apps); other folders are layout and get walked.
    func organizerItems(in dir: URL) -> [URL] {
        let fm = FileManager.default
        let kids = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
                                                options: [.skipsHiddenFiles])) ?? []
        var out: [URL] = []
        for k in kids.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            if config.ignoredFolder(containing: k.path) != nil { continue }
            let v = try? k.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            let isDir = v?.isDirectory ?? false
            if !isDir || v?.isPackage == true || ledger.activeItem(atPath: normalize(k.path)) != nil {
                out.append(k)
            } else {
                out += organizerItems(in: k)
            }
        }
        return out
    }

    public func organizerEntry(_ url: URL, cabinet: String) -> OrganizerEntry? {
        let path = normalize(url.path)
        guard let loc = locate(path), var f = Inspector.full(URL(fileURLWithPath: path)) else { return nil }
        let tracked = ledger.activeItem(atPath: path)
        enrich(&f, firstSeen: tracked?.firstSeen)
        var asLibrary = loc.root
        asLibrary.filing = Filing(mode: .library)
        let d = classifier.classify(f, root: asLibrary)
        let kind = FileKind.detect(f, decision: d).label
        let here = (path as NSString).deletingLastPathComponent
        let choice: OrganizerChoice
        var reason = d.reason
        switch d.action {
        case .trash:
            choice = .trash
        case .move:
            if let dest = d.destination, normalize(dest) != here, locate(dest)?.root.filing.mode != .inPlace {
                choice = .file(dest)
            } else {
                choice = .leave
            }
        case .hold, .ignore:
            choice = .leave
            if d.rule == "fallback" { reason = "no confident home in \(Paths.pretty(config.libraryURL.path)) yet" }
        }
        return OrganizerEntry(path: path, name: f.name, cabinet: cabinet, itemId: tracked?.id, kindLabel: kind,
                              size: f.size, suggestion: choice, reason: reason, rule: d.rule, confidence: d.confidence)
    }

    /// Carry out one choice. `.leave` does nothing and returns nil.
    @discardableResult
    public func organize(_ e: OrganizerEntry, _ choice: OrganizerChoice) throws -> Item? {
        guard fileExists(e.path) else { throw LandfallError.action("\(e.name) is no longer at \(Paths.pretty(e.path))") }
        let d: Decision
        switch choice {
        case .leave:
            return nil
        case .trash:
            d = Decision(action: .trash, confidence: 1, rule: "organizer",
                         reason: e.suggestion == .trash ? "Organizer: \(e.reason)" : "Organizer: you chose the Trash")
        case .file(let dest):
            d = Decision(action: .move, destination: normalize(dest), confidence: 1, rule: "organizer",
                         reason: e.suggestion == choice ? "Organizer: \(e.reason)" : "Organizer: you chose \(Paths.pretty(dest))")
        }
        let id = e.itemId ?? ledger.activeItem(atPath: e.path)?.id ?? track(e.path)
        try execute(id, path: e.path, d)
        return ledger.item(id)
    }

    /// Start following something Landfall hadn't tracked (it was put in a filing folder by hand).
    func track(_ path: String) -> Int64 {
        let q = Inspector.quick(URL(fileURLWithPath: path))
        let id = ledger.insertItem(name: (path as NSString).lastPathComponent, kind: q?.isDir == true ? "dir" : "file",
                                   root: locate(path)?.root.name ?? "", path: path, inode: Int64(q?.inode ?? 0),
                                   size: q?.size ?? 0, firstSeen: q?.added ?? clock(), bookmark: Mover.bookmark(path))
        ledger.update(id, ["status": "filed"])
        ledger.addEvent(id, "arrived", dst: path, reason: "found in a filing folder")
        return id
    }

    /// Filing folders with nothing left in them go to the Trash (they're Landfall's own). Returns their names.
    @discardableResult
    public func tidyCabinets() -> [String] {
        var out: [String] = []
        for cab in cabinets() where organizerItems(in: cab).isEmpty {
            if (try? Mover.trash(cab)) != nil { out.append(cab.lastPathComponent) }
        }
        return out
    }
}
