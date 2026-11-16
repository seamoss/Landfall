import AppKit
import LandfallCore
import SwiftUI

/// Organize Desktop: everything in the Desktop's dated folders, each going into the library for good,
/// to the Trash, or staying. Nothing moves until Apply; Undo All reverses the whole batch.
final class OrganizerModel: ObservableObject {
    /// Dated folders this recent start as "Leave": the Desktop is a working shelf.
    static let recentDays = 7

    let engine: Engine
    @Published var entries: [OrganizerEntry] = []
    @Published var choices: [String: OrganizerChoice] = [:]
    @Published var applied: [Int64] = []
    @Published var status = ""
    @Published var busy = false

    init(engine: Engine) {
        self.engine = engine
        reload()
    }

    var cabinets: [String] {
        var seen = Set<String>()
        return entries.map(\.cabinet).filter { seen.insert($0).inserted }
    }

    func entries(in cabinet: String) -> [OrganizerEntry] { entries.filter { $0.cabinet == cabinet } }

    func reload() {
        entries = engine.organizerEntries()
        choices = Dictionary(uniqueKeysWithValues: entries.map { ($0.path, defaultChoice($0)) })
    }

    func defaultChoice(_ e: OrganizerEntry) -> OrganizerChoice {
        Self.isRecent(e.cabinet) ? .leave : e.suggestion
    }

    static func isRecent(_ cabinet: String) -> Bool {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: String(cabinet.prefix(10))) else { return false }
        return Date().timeIntervalSince(d) < Double(recentDays) * 86400
    }

    func choice(_ e: OrganizerEntry) -> OrganizerChoice { choices[e.path] ?? .leave }

    func set(_ c: OrganizerChoice, for e: OrganizerEntry) { choices[e.path] = c }

    /// "Set all" for one dated folder: each item's own suggestion, the Trash, or leave.
    func setAll(_ cabinet: String, _ pick: (OrganizerEntry) -> OrganizerChoice) {
        for e in entries(in: cabinet) { choices[e.path] = pick(e) }
    }

    var counts: (file: Int, trash: Int, leave: Int) {
        var c = (file: 0, trash: 0, leave: 0)
        for e in entries {
            switch choice(e) {
            case .file: c.file += 1
            case .trash: c.trash += 1
            case .leave: c.leave += 1
            }
        }
        return c
    }

    func apply() {
        busy = true
        var done: [Int64] = []
        var failures: [String] = []
        for e in entries where choice(e) != .leave {
            do {
                if let it = try engine.organize(e, choice(e)) { done.append(it.id) }
            } catch {
                failures.append("\(e.name): \(error.localizedDescription)")
                Log.error("organize failed — \(e.name): \(error.localizedDescription)")
            }
        }
        let tidied = engine.tidyCabinets()
        applied = done
        Log.info("organizer: \(done.count) moved, \(failures.count) failed, \(tidied.count) empty folders removed")
        status = "\(done.count) item\(done.count == 1 ? "" : "s") done"
            + (tidied.isEmpty ? "" : " · \(tidied.count) empty folder\(tidied.count == 1 ? "" : "s") removed")
            + (failures.isEmpty ? "" : " · \(failures.count) couldn't be moved (see the log)")
        reload()
        busy = false
    }

    func undoAll() {
        busy = true
        var failed = 0
        for id in applied.reversed() {
            do { _ = try engine.undo(id) } catch {
                failed += 1
                Log.error("organizer undo failed — #\(id): \(error.localizedDescription)")
            }
        }
        status = failed == 0 ? "Undone — everything is back where it was" : "Undone, except \(failed) (see the log)"
        applied = []
        reload()
        busy = false
    }

    func chooseFolder(for e: OrganizerEntry) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "File Here"
        panel.message = "Where should \(e.name) live?"
        panel.directoryURL = engine.config.libraryURL
        if panel.runModal() == .OK, let url = panel.url { set(.file(url.path), for: e) }
    }

    func label(_ c: OrganizerChoice) -> String {
        switch c {
        case .file(let dest): return "File to " + Paths.pretty(dest).replacingOccurrences(of: "~/Documents/", with: "")
        case .trash: return "Trash"
        case .leave: return "Leave on Desktop"
        }
    }
}

struct OrganizerView: View {
    @ObservedObject var model: OrganizerModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.entries.isEmpty {
                ContentUnavailableView("Nothing to organize", systemImage: "checkmark.circle",
                                       description: Text("The Desktop's dated folders are empty."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(model.cabinets, id: \.self) { cab in
                        Section { ForEach(model.entries(in: cab)) { row($0) } } header: { sectionHeader(cab) }
                    }
                }
                .listStyle(.inset)
            }
            Divider()
            footer
        }
        .frame(minWidth: 680, minHeight: 480)
        .disabled(model.busy)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Organize Desktop").font(.title2.weight(.semibold))
            Text("\(model.entries.count) items in \(model.cabinets.count) dated folders. File them into Documents for good or "
                 + "send them to the Trash. Folders from the last \(OrganizerModel.recentDays) days start as Leave. "
                 + "Every move is recorded and can be undone.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    private func sectionHeader(_ cab: String) -> some View {
        HStack {
            Text(cab).font(.headline)
            Text("\(model.entries(in: cab).count)").foregroundStyle(.secondary)
            Spacer()
            Menu("Set All") {
                Button("Suggested") { model.setAll(cab) { $0.suggestion } }
                Button("Trash") { model.setAll(cab) { _ in .trash } }
                Button("Leave on Desktop") { model.setAll(cab) { _ in .leave } }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    private func row(_ e: OrganizerEntry) -> some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: e.path))
                .resizable()
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(e.name).lineLimit(1).truncationMode(.middle)
                Text(([e.kindLabel, formatBytes(e.size)]
                      + (e.reason.caseInsensitiveCompare(e.kindLabel) == .orderedSame ? [] : [e.reason])).joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            choiceMenu(e)
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: e.path)]) }
            Button("Quick Look") { NSWorkspace.shared.open(URL(fileURLWithPath: e.path)) }
        }
    }

    private func choiceMenu(_ e: OrganizerEntry) -> some View {
        let current = model.choice(e)
        return Menu {
            if case .file = e.suggestion { Button(model.label(e.suggestion)) { model.set(e.suggestion, for: e) } }
            if case .file = current, current != e.suggestion { Button(model.label(current)) { model.set(current, for: e) } }
            Button("Choose Folder…") { model.chooseFolder(for: e) }
            Divider()
            Button("Trash") { model.set(.trash, for: e) }
            Button("Leave on Desktop") { model.set(.leave, for: e) }
        } label: {
            Text(model.label(current))
                .foregroundStyle(color(current))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .menuStyle(.borderlessButton)
        .frame(width: 260, alignment: .trailing)
    }

    private func color(_ c: OrganizerChoice) -> Color {
        switch c {
        case .file: return .accentColor
        case .trash: return Color(nsColor: .systemRed)
        case .leave: return .secondary
        }
    }

    private var footer: some View {
        let c = model.counts
        return HStack(spacing: 10) {
            Text("File \(c.file) · Trash \(c.trash) · Leave \(c.leave)").monospacedDigit()
            if !model.status.isEmpty { Text(model.status).foregroundStyle(.secondary).lineLimit(1) }
            Spacer()
            if !model.applied.isEmpty { Button("Undo All") { model.undoAll() } }
            Button("Apply") { model.apply() }
                .keyboardShortcut(.defaultAction)
                .disabled(c.file + c.trash == 0)
        }
        .padding(12)
    }
}

final class OrganizerWindowController: NSWindowController, NSWindowDelegate {
    static var shared: OrganizerWindowController?

    static func show(engine: Engine) {
        if shared == nil { shared = OrganizerWindowController(engine: engine) } else { shared?.model.reload() }
        NSApp.activate(ignoringOtherApps: true)
        shared?.showWindow(nil)
        shared?.window?.makeKeyAndOrderFront(nil)
    }

    let model: OrganizerModel

    init(engine: Engine) {
        model = OrganizerModel(engine: engine)
        let host = NSHostingController(rootView: OrganizerView(model: model))
        let window = NSWindow(contentViewController: host)
        window.title = "Organize Desktop"
        window.setContentSize(NSSize(width: 760, height: 620))
        window.styleMask.insert(.resizable)
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) { Self.shared = nil }
}
