import AppKit
import LandfallCore
import SwiftUI

/// The Space Report: rebuildable folders (node_modules, .next, cargo target…) in your code projects.
/// Measuring them takes minutes, so the window opens at once and fills in as each folder is sized.
final class SpaceReportModel: ObservableObject {
    enum Phase: Equatable { case idle, measuring(started: Date), done(at: Date) }

    let engine: Engine
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var hits: [SpaceHit] = []
    /// Ticked for the Trash.
    @Published var selected: Set<String> = []
    @Published var idleDays: Double
    @Published var status = ""
    /// The weekly run, once it finishes (writes the text report, may show a toast).
    var onFinished: (([SpaceHit], _ asked: Bool) -> Void)?

    init(engine: Engine) {
        self.engine = engine
        idleDays = engine.config.spaceIdleDays
    }

    var isMeasuring: Bool { if case .measuring = phase { return true } else { return false } }
    var roots: [URL] { engine.config.spaceRoots.map { URL(fileURLWithPath: normalize($0)) } }
    var total: Int64 { hits.reduce(0) { $0 + $1.bytes } }

    /// Rebuildable, and in a project untouched for `idleDays`: what Clean idle would take.
    func isIdle(_ h: SpaceHit) -> Bool { !h.reportOnly && (h.idleDays ?? .infinity) >= idleDays }
    var idleBytes: Int64 { hits.filter(isIdle).reduce(0) { $0 + $1.bytes } }
    var selectedHits: [SpaceHit] { hits.filter { selected.contains($0.path) } }
    var selectedBytes: Int64 { selectedHits.reduce(0) { $0 + $1.bytes } }

    func selectIdle() { selected = Set(hits.filter(isIdle).map(\.path)) }

    /// Start measuring, unless already at it. `asked`: someone clicked, rather than the weekly timer.
    func start(asked: Bool) {
        guard !isMeasuring else { return }
        let now = Date()
        phase = .measuring(started: now)
        hits = []
        selected = []
        status = ""
        let roots = roots
        let ignore = engine.config.ignore
        Log.info("space report: measuring \(roots.map { Paths.pretty($0.path) }.joined(separator: ", "))")
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let all = Space.scan(roots, ignore: ignore) { hit in
                guard hit.bytes > 1 << 20 else { return }
                DispatchQueue.main.async { self?.hits.append(hit) }
            }.filter { $0.bytes > 1 << 20 }
            DispatchQueue.main.async {
                guard let self else { return }
                Log.info("space report: \(all.count) folders measured in \(Int(Date().timeIntervalSince(now)))s")
                self.hits = all
                self.phase = .done(at: Date())
                self.selectIdle()
                self.onFinished?(all, asked)
            }
        }
    }

    func trashSelected() {
        let chosen = selectedHits
        guard !chosen.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "Move \(chosen.count) folder\(chosen.count == 1 ? "" : "s") (\(formatBytes(selectedBytes))) to the Trash?"
        alert.informativeText = "They're rebuildable: reinstall or rebuild with the project's package manager or build tool when you "
            + "return to it. You can also put them back from the Trash."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var freed: Int64 = 0
        var failed = 0
        for h in chosen {
            if (try? engine.guardIgnored(h.path)) != nil, (try? Mover.trash(URL(fileURLWithPath: h.path))) != nil {
                freed += h.bytes
                hits.removeAll { $0.path == h.path }
            } else {
                failed += 1
            }
        }
        selected.subtract(chosen.map(\.path))
        Log.info("space report: trashed \(chosen.count - failed) folders (\(formatBytes(freed)))")
        status = "Moved \(formatBytes(freed)) to the Trash" + (failed > 0 ? " · \(failed) couldn't be moved" : "")
    }
}

struct SpaceReportView: View {
    @ObservedObject var model: SpaceReportModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 720, minHeight: 480)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Space Report").font(.title2.weight(.semibold))
                Text(summary).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if case .done = model.phase {
                Picker("Idle for at least", selection: $model.idleDays) {
                    ForEach([7.0, 14, 30, 60, 90], id: \.self) { Text("\(Int($0)) days").tag($0) }
                }
                .fixedSize()
                .onChange(of: model.idleDays) { _, _ in model.selectIdle() }
            }
        }
        .padding(16)
    }

    private var summary: String {
        let where_ = model.roots.map { Paths.pretty($0.path) }.joined(separator: ", ")
        switch model.phase {
        case .idle:
            return "Rebuildable folders in \(where_)."
        case .measuring:
            return "Measuring rebuildable folders in \(where_). This takes a minute or two; folders appear as they're sized."
        case .done(let at):
            return "\(formatBytes(model.total)) in \(model.hits.count) rebuildable folders · \(formatBytes(model.idleBytes)) "
                + "in projects idle \(Int(model.idleDays))+ days, ticked below. Measured \(formatDate(at, "HH:mm"))."
        }
    }

    @ViewBuilder private var content: some View {
        if case .measuring(let started) = model.phase, model.hits.isEmpty {
            VStack(spacing: 12) {
                ProgressView()
                TimelineView(.periodic(from: started, by: 1)) { ctx in
                    Text("Looking for node_modules, .next, target… · \(Int(ctx.date.timeIntervalSince(started)))s")
                        .foregroundStyle(.secondary).monospacedDigit()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if case .done = model.phase, model.hits.isEmpty {
            ContentUnavailableView("Nothing to reclaim", systemImage: "checkmark.circle",
                                   description: Text("No rebuildable folders over 1 MB."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(model.hits.sorted { $0.bytes > $1.bytes }) { row($0) }
            }
            .listStyle(.inset)
        }
    }

    private func row(_ h: SpaceHit) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { model.selected.contains(h.path) },
                                     set: { on in if on { model.selected.insert(h.path) } else { model.selected.remove(h.path) } }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(h.reportOnly || model.isMeasuring)
            Text(formatBytes(h.bytes))
                .monospacedDigit()
                .frame(width: 80, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                Text(Paths.pretty(h.path)).lineLimit(1).truncationMode(.middle)
                Text([h.kind,
                      h.idleDays.map { $0 < 1 ? "touched today" : "idle \(Int($0)) days" } ?? "not in a git repo",
                      h.reportOnly ? "report only — not rebuildable" : nil].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(model.isIdle(h) ? Color.secondary : Color.secondary.opacity(0.7))
            }
            Spacer()
        }
        .padding(.vertical, 1)
        .contextMenu {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: h.path)]) }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            switch model.phase {
            case .measuring(let started):
                ProgressView().controlSize(.small)
                TimelineView(.periodic(from: started, by: 1)) { ctx in
                    Text("\(model.hits.count) folder\(model.hits.count == 1 ? "" : "s") · \(formatBytes(model.total)) so far · \(Int(ctx.date.timeIntervalSince(started)))s")
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize()
                }
                if let last = model.hits.last {
                    Text(Paths.pretty(last.path)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            default:
                Text(model.selected.isEmpty ? "Nothing selected" : "\(model.selected.count) selected · \(formatBytes(model.selectedBytes))")
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
                if !model.status.isEmpty { Text(model.status).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer()
            Button("Show Text Report") {
                NSWorkspace.shared.open(Paths.logURL.deletingLastPathComponent().appendingPathComponent("space-report.txt"))
            }
            .disabled(model.isMeasuring)
            Button("Measure Again") { model.start(asked: true) }
                .disabled(model.isMeasuring)
            Button("Move to Trash…") { model.trashSelected() }
                .keyboardShortcut(.defaultAction)
                .disabled(model.isMeasuring || model.selected.isEmpty)
        }
        .padding(12)
    }
}

final class SpaceReportWindowController: NSWindowController, NSWindowDelegate {
    static var shared: SpaceReportWindowController?

    static func show(_ model: SpaceReportModel) {
        if shared == nil { shared = SpaceReportWindowController(model: model) }
        NSApp.activate(ignoringOtherApps: true)
        shared?.showWindow(nil)
        shared?.window?.makeKeyAndOrderFront(nil)
    }

    init(model: SpaceReportModel) {
        let window = NSWindow(contentViewController: NSHostingController(rootView: SpaceReportView(model: model)))
        window.title = "Space Report"
        window.setContentSize(NSSize(width: 780, height: 600))
        window.styleMask.insert(.resizable)
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) { Self.shared = nil }
}
