import AppKit
import EventKit
import LandfallCore
import ServiceManagement
import SwiftUI
import UserNotifications

final class SettingsModel: ObservableObject {
    /// Changes apply as you make them (debounced), like every other macOS settings window.
    @Published var config: Config { didSet { scheduleSave() } }
    @Published var apiKeyDraft = ""
    @Published var hasAPIKey = Keychain.apiKey() != nil
    @Published var loginItem = SMAppService.mainApp.status == .enabled
    @Published var calendarAccess = EKEventStore.authorizationStatus(for: .event) == .fullAccess
    @Published var notificationsAllowed: Bool?
    @Published var folderAccess: [String: Bool] = [:]
    @Published var smartCalls = 0
    weak var agent: Agent?
    private var pendingSave: DispatchWorkItem?
    private var loading = true

    init(agent: Agent?) {
        self.agent = agent
        config = (try? Config.load()) ?? .standard
        loading = false
        refreshPermissions()
    }

    private func scheduleSave() {
        guard !loading else { return }
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func save() {
        do {
            try config.save()
            agent?.configStamp = nil
            agent?.reloadConfigIfChanged()
        } catch {
            notify("Landfall couldn't save settings", "\(error)")
        }
    }

    func saveKey() {
        try? Keychain.setAPIKey(apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines))
        apiKeyDraft = ""
        hasAPIKey = Keychain.apiKey() != nil
    }

    func setLoginItem(_ on: Bool) {
        if on { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
        loginItem = SMAppService.mainApp.status == .enabled
    }

    /// Pick a file, see exactly what would be sent, then optionally ask Claude.
    func tryOnFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.message = "Choose a file to see what Smart Filing would send and where it would go."
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url, var f = Inspector.full(url) else { return }
        if Classifier.imageExts.contains(f.ext) { f.ocrText = OCR.text(url) }
        let config = self.config
        let alert = NSAlert()
        if let why = AIAdvisor.blockReason(f, decision: nil) {
            alert.messageText = "Smart Filing won't send this file"
            alert.informativeText = "It \(why). Landfall keeps files like this to its own rules."
            alert.runModal()
            return
        }
        alert.messageText = "This is what would be sent for \(url.lastPathComponent)"
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 520, height: 260))
        text.string = AIAdvisor.prompt(for: f, config: config)
        text.isEditable = false
        text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        let scroll = NSScrollView(frame: text.frame)
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        alert.accessoryView = scroll
        alert.addButton(withTitle: "Ask Claude")
        alert.addButton(withTitle: "Close")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { @MainActor in
            let result = NSAlert()
            do {
                let d = try await AIAdvisor.suggest(f, decision: nil, config: config)
                result.messageText = "Smart Filing would put it in " + (d.destination.map { Paths.pretty($0) } ?? "?")
                result.informativeText = d.reason + (d.newName.map { "\nRenamed to “\($0)”." } ?? "")
                    + "\nConfidence \(Int(d.confidence * 100))%. Nothing was moved."
            } catch {
                result.messageText = "Smart Filing couldn't answer"
                result.informativeText = "\(error)"
            }
            result.runModal()
        }
    }

    func refreshPermissions() {
        smartCalls = agent?.engine.smartCallsThisMonth ?? 0
        loginItem = SMAppService.mainApp.status == .enabled
        calendarAccess = EKEventStore.authorizationStatus(for: .event) == .fullAccess
        hasAPIKey = Keychain.apiKey() != nil
        var access: [String: Bool] = [:]
        for r in config.roots {
            access[r.name] = (try? FileManager.default.contentsOfDirectory(atPath: r.url.path)) != nil
        }
        folderAccess = access
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().getNotificationSettings { s in
            DispatchQueue.main.async { self.notificationsAllowed = s.authorizationStatus == .authorized || s.authorizationStatus == .provisional }
        }
    }

    func requestCalendar() {
        agent?.calendar.requestAccess { [weak self] ok in
            self?.calendarAccess = ok
            if !ok { openPrivacy("Privacy_Calendars") }
        }
    }
}

func openPrivacy(_ anchor: String) {
    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!)
}

/// Standard macOS settings window: toolbar tabs, fixed size, changes apply immediately.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static let size = NSSize(width: 680, height: 620)
    let model: SettingsModel

    init(engine: Engine, agent: Agent) {
        model = SettingsModel(agent: agent)
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        func pane<V: View>(_ title: String, _ symbol: String, _ view: V) -> NSTabViewItem {
            let host = NSHostingController(rootView: view.frame(width: Self.size.width, height: Self.size.height))
            host.sizingOptions = []
            host.preferredContentSize = Self.size
            let item = NSTabViewItem(viewController: host)
            item.label = title
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            return item
        }
        tabs.addTabViewItem(pane("General", "gearshape", GeneralTab(model: model)))
        tabs.addTabViewItem(pane("Folders", "folder", FoldersTab(model: model)))
        tabs.addTabViewItem(pane("Smart Filing", "sparkles", SmartFilingTab(model: model)))
        tabs.addTabViewItem(pane("Rules", "list.bullet.rectangle", RulesTab(model: model)))

        let window = NSWindow(contentViewController: tabs)
        window.toolbarStyle = .preference
        // Fixed size: no resizing, no zoom, no full screen.
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.collectionBehavior = [.fullScreenNone]
        window.setContentSize(Self.size)
        window.contentMinSize = Self.size
        window.contentMaxSize = Self.size
        window.center()
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Permissions may have changed in System Settings while we were away.
    func windowDidBecomeKey(_ notification: Notification) { model.refreshPermissions() }
}

// MARK: - General

struct GeneralTab: View {
    @ObservedObject var model: SettingsModel

    var modeExplanation: String {
        switch model.config.mode {
        case .shadow: return "Landfall records what it would do and suggests it; nothing moves unless you click."
        case .review: return "Every decision waits for you in the menu bar and in toasts."
        case .auto: return "Confident decisions happen on their own. Everything is logged and undoable."
        }
    }

    var body: some View {
        Form {
            Section {
                Picker("Mode", selection: $model.config.mode) {
                    Text("Watch").tag(Mode.shadow)
                    Text("Suggest").tag(Mode.review)
                    Text("Auto").tag(Mode.auto)
                }
                .pickerStyle(.segmented)
                Text(modeExplanation).font(.callout).foregroundStyle(.secondary)
            }

            Section("Permissions") {
                ForEach(model.config.roots, id: \.name) { r in
                    PermissionRow(title: "\(r.name.capitalized) folder", symbol: "folder",
                                  ok: model.folderAccess[r.name] ?? false,
                                  fix: "Open Privacy Settings…") { openPrivacy("Privacy_FilesAndFolders") }
                }
                PermissionRow(title: "Notifications", symbol: "bell.badge", ok: model.notificationsAllowed ?? false,
                              fix: "Open Notification Settings…") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                }
                PermissionRow(title: "Calendar", symbol: "calendar", ok: model.calendarAccess,
                              fix: "Grant Access…", optional: !model.config.useCalendar) { model.requestCalendar() }
                Toggle(isOn: Binding(get: { model.loginItem }, set: { model.setLoginItem($0) })) {
                    Label("Open at login", systemImage: "power")
                }
            }

            Section("When Something Lands") {
                Toggle(isOn: $model.config.toasts) {
                    Text("Show a toast")
                    Text("A card at the top of the screen: what it is, where it's going, and quick actions.")
                }
                Toggle(isOn: $model.config.toastAutoFile) {
                    Text("File it when the countdown ends")
                    Text("Only confident moves of ordinary files. Never trashes; never touches credentials, apps, scripts or installers. Hover to pause.")
                }
                .disabled(!model.config.toasts)
                Picker("File after", selection: $model.config.autoFileSeconds) {
                    ForEach(Self.durations(including: model.config.autoFileSeconds), id: \.self) { Text(Self.label($0)).tag($0) }
                }
                .disabled(!model.config.toasts || !model.config.toastAutoFile)
                Picker("Other toasts stay", selection: $model.config.toastSeconds) {
                    ForEach(Self.durations(including: model.config.toastSeconds), id: \.self) { Text(Self.label($0)).tag($0) }
                }
                .disabled(!model.config.toasts)
                Toggle(isOn: $model.config.notify) {
                    Text("Notifications and daily digest")
                    Text("Alerts for credentials, and an evening summary of what was filed.")
                }
            }

            Section("Context") {
                Toggle(isOn: $model.config.useCalendar) {
                    Text("Use my calendar")
                    Text("The meeting you're in when a file arrives helps pick its client. Nothing leaves your Mac.")
                }
            }

            Section("1Password") {
                TextField("Vault", text: optional($model.config.onePasswordVault), prompt: Text("Default vault"))
                StatusLine(ok: OnePassword.cli != nil, okText: "1Password CLI found", badText: OnePassword.installHint)
            }

            Section("Disk Space") {
                Toggle(isOn: $model.config.spaceReport) {
                    Text("Weekly space report")
                    Text("Monday morning: rebuildable folders (node_modules, .venv, .next…) in idle projects.")
                }
                TextField("Project folders", text: commaList($model.config.spaceRoots))
                Stepper(value: $model.config.spaceIdleDays, in: 7...365, step: 7) {
                    LabeledContent("Idle after", value: "\(Int(model.config.spaceIdleDays)) days")
                }
                HStack {
                    Button("Run Space Report Now") { model.agent?.weeklySpaceReport(force: true) }
                    Spacer()
                    Button("Open config.json") { NSWorkspace.shared.open(Paths.configURL) }
                        .buttonStyle(.link)
                }
            }
        }
        .formStyle(.grouped)
    }
}

extension GeneralTab {
    static let presets: [Double] = [5, 10, 15, 20, 30, 45, 60, 90, 120, 300]

    /// The presets, plus whatever odd value is in config.json so the picker never shows blank.
    static func durations(including current: Double) -> [Double] {
        (presets.contains(current) ? presets : (presets + [current]).sorted())
    }

    static func label(_ s: Double) -> String {
        s < 60 ? "\(Int(s)) seconds" : s == 60 ? "1 minute" : s.truncatingRemainder(dividingBy: 60) == 0 ? "\(Int(s / 60)) minutes" : "\(Int(s)) seconds"
    }
}

struct PermissionRow: View {
    let title: String
    let symbol: String
    let ok: Bool
    let fix: String
    var optional = false
    let action: () -> Void

    var body: some View {
        LabeledContent {
            if ok {
                Label("Allowed", systemImage: "checkmark.circle.fill")
                    .labelStyle(.titleAndIcon).foregroundStyle(.green)
            } else {
                HStack(spacing: 8) {
                    Image(systemName: optional ? "minus.circle" : "exclamationmark.triangle.fill")
                        .foregroundStyle(optional ? Color.secondary : Color.orange)
                    Button(fix, action: action)
                }
            }
        } label: {
            Label(title, systemImage: symbol)
        }
    }
}

struct StatusLine: View {
    let ok: Bool
    let okText: String
    let badText: String

    var body: some View {
        Label(ok ? okText : badText, systemImage: ok ? "checkmark.circle.fill" : "info.circle")
            .font(.callout)
            .foregroundStyle(ok ? Color.green : Color.secondary)
    }
}

struct FoldersTab: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section("Library") {
                TextField("Library folder", text: $model.config.library)
                Toggle("Keep a “Recent Landings” folder of aliases", isOn: Binding(
                    get: { model.config.recentShelf != nil },
                    set: { model.config.recentShelf = $0 ? "~/Desktop/Recent Landings" : nil }))
            }
            ForEach($model.config.roots, id: \.name) { $root in
                Section(root.name.capitalized + " — " + root.path) {
                    Picker("Role", selection: $root.role) {
                        Text("Intake").tag(RootRole.intake)
                        Text("Shelf").tag(RootRole.shelf)
                        Text("Library").tag(RootRole.library)
                    }
                    Picker("File items into", selection: $root.filing.mode) {
                        Text("The library (\(model.config.library))").tag(Filing.Mode.library)
                        Text("This folder").tag(Filing.Mode.inPlace)
                    }
                    if root.filing.mode == .inPlace {
                        TextField("Cabinet folder (blank = \(root.path) itself)", text: optional($root.filing.folder))
                        Picker("Organize by", selection: $root.filing.layout) {
                            Text("Day — 2026-10-12").tag("{yyyy-mm-dd}")
                            Text("Day, then type — 2026-10-12/Screenshots").tag("{yyyy-mm-dd}/{category}")
                            Text("Month — 2026-10").tag("{yyyy-mm}")
                            Text("Type — Screenshots").tag("{category}")
                            if !["{yyyy-mm-dd}", "{yyyy-mm-dd}/{category}", "{yyyy-mm}", "{category}"].contains(root.filing.layout) {
                                Text("Custom — \(root.filing.layout)").tag(root.filing.layout)
                            }
                        }
                        Text("Credentials still go to _Sensitive in the library.").font(.caption).foregroundStyle(.secondary)
                    }
                    Stepper("Grace period: \(Int(root.graceSeconds / 60)) minutes", value: $root.graceSeconds, in: 0...86400, step: 300)
                    Toggle("Count from when I last opened it", isOn: $root.useLastUsed)
                    TextField("Trash unfiled items after N days (blank = never)", text: Binding(
                        get: { root.expireDays.map { String(Int($0)) } ?? "" },
                        set: { root.expireDays = Double($0) }))
                    TextField("Never touch (comma-separated)", text: commaList($root.neverTouch))
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct EditIndex: Identifiable { let id: Int }

/// Smart Filing: bring-your-own-key Claude that files by what's inside, plus the clients it (and the rules) know.
struct SmartFilingTab: View {
    @ObservedObject var model: SettingsModel
    @State private var editing: EditIndex?

    static let models: [(id: String, name: String, note: String)] = [
        ("claude-haiku-5-5", "Claude Haiku 5.5", "Fastest, lowest cost"),
        ("claude-sonnet-5-5", "Claude Sonnet 5.5", "Better with long or ambiguous documents"),
        ("claude-opus-5-5", "Claude Opus 5.5", "Most capable, highest cost"),
    ]

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $model.config.ai.enabled) {
                    Label {
                        Text("Smart Filing")
                        Text("Reads what's inside a file and picks the right folder or client. Uses your own Anthropic API key; you pay Anthropic directly.")
                    } icon: {
                        Image(systemName: "sparkles").foregroundStyle(.purple)
                    }
                }
                .disabled(!model.hasAPIKey && !model.config.ai.enabled)
                if !model.hasAPIKey {
                    Label("Add an API key below to turn it on.", systemImage: "key")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }

            Section("Anthropic API Key") {
                LabeledContent("API key") {
                    HStack {
                        SecureField("API key", text: $model.apiKeyDraft,
                                    prompt: Text(model.hasAPIKey ? "Saved in your keychain" : "sk-ant-…"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 240)
                        Button(model.apiKeyDraft.isEmpty && model.hasAPIKey ? "Remove" : "Save") { model.saveKey() }
                            .disabled(model.apiKeyDraft.isEmpty && !model.hasAPIKey)
                    }
                }
                Picker("Model", selection: $model.config.ai.model) {
                    ForEach(Self.models, id: \.id) { m in
                        Text("\(m.name) — \(m.note)").tag(m.id)
                    }
                    if !Self.models.contains(where: { $0.id == model.config.ai.model }) {
                        Text(model.config.ai.model).tag(model.config.ai.model)
                    }
                }
                LabeledContent("This month", value: "\(model.smartCalls) file\(model.smartCalls == 1 ? "" : "s") read")
                HStack {
                    Link("Get a key at console.anthropic.com", destination: URL(string: "https://console.anthropic.com/settings/keys")!)
                        .font(.callout)
                    Spacer()
                }
            }

            Section("When to Use It") {
                Picker("Read", selection: $model.config.ai.scope) {
                    Text("Only files Landfall isn't sure about").tag(AIConfig.Scope.unsure)
                    Text("Every document with readable text").tag(AIConfig.Scope.documents)
                }
                Toggle(isOn: $model.config.ai.autoFile) {
                    Text("Let Smart Filing file on its own")
                    Text("Off: its picks are suggestions you confirm. On: confident picks file like any other decision, with the toast countdown.")
                }
                Text("Your rules, and Landfall's rules for secrets, duplicates, installers, screenshots and code, always come first.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .disabled(!model.config.ai.enabled)

            Section("Privacy") {
                Picker("Text sent per file", selection: $model.config.ai.excerptChars) {
                    Text("1,500 characters").tag(1500)
                    Text("4,000 characters").tag(4000)
                    Text("8,000 characters").tag(8000)
                    if ![1500, 4000, 8000].contains(model.config.ai.excerptChars) {
                        Text("\(model.config.ai.excerptChars) characters").tag(model.config.ai.excerptChars)
                    }
                }
                LabeledContent("Also sent") {
                    Text("File name, type, size, download site, your folder names, client names and aliases")
                        .multilineTextAlignment(.trailing).foregroundStyle(.secondary)
                }
                LabeledContent("Never sent") {
                    Text("Credentials and anything that looks like a secret, résumés and contact cards, people's names from your client list")
                        .multilineTextAlignment(.trailing).foregroundStyle(.secondary)
                }
                HStack {
                    Spacer()
                    Button("Try on a File…") { model.tryOnFile() }
                        .disabled(!model.hasAPIKey)
                }
            }

            Section {
                ForEach(model.config.clients.indices, id: \.self) { i in
                    LabeledContent {
                        Button("Details…") { editing = EditIndex(id: i) }
                    } label: {
                        Text(model.config.clients[i].name)
                        Text(Self.summary(model.config.clients[i]))
                    }
                }
            } header: {
                Text("Clients & Projects")
            } footer: {
                HStack {
                    Text("Used by Smart Filing and by Landfall's own rules: names, aliases, people, sites and meetings.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Add Client…") {
                        model.config.clients.append(ClientConfig(name: "New Client"))
                        editing = EditIndex(id: model.config.clients.count - 1)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .sheet(item: $editing) { e in
            if model.config.clients.indices.contains(e.id) {
                ClientEditor(client: $model.config.clients[e.id],
                             onDelete: { model.config.clients.remove(at: e.id); editing = nil },
                             onDone: { editing = nil })
            }
        }
    }

    static func summary(_ c: ClientConfig) -> String {
        var parts: [String] = []
        if !c.people.isEmpty { parts.append("\(c.people.count) \(c.people.count == 1 ? "person" : "people")") }
        if !c.aliases.isEmpty { parts.append("also “\(c.aliases.prefix(2).joined(separator: "”, “"))”") }
        if !c.domains.isEmpty { parts.append(c.domains.joined(separator: ", ")) }
        return ([c.folderPath] + parts).joined(separator: " · ")
    }
}

struct ClientEditor: View {
    @Binding var client: ClientConfig
    let onDelete: () -> Void
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $client.name)
                    TextField("Folder", text: optional($client.folder), prompt: Text("Clients/\(client.name)"))
                }
                Section {
                    TextField("Also known as", text: commaList($client.aliases), prompt: Text("Acronyms, product names"))
                    TextField("People", text: commaList($client.people), prompt: Text("Jane Doe, Sam Lee"))
                    TextField("Domains", text: commaList($client.domains), prompt: Text("client.com"))
                } footer: {
                    Text("Comma-separated. People match meeting participants and calendar attendees; domains match download sites and attendee emails.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            SheetButtons(deleteTitle: "Delete Client", onDelete: onDelete, onDone: onDone)
        }
        .frame(width: 480)
    }
}

struct RulesTab: View {
    @ObservedObject var model: SettingsModel
    @State private var editing: EditIndex?

    func summary(_ r: RuleConfig) -> String {
        var when: [String] = []
        if let x = r.nameRegex { when.append("name ~ \(x)") }
        if let x = r.extensions { when.append(x.map { "." + $0 }.joined(separator: " ")) }
        if let x = r.participantsAny { when.append("with \(x.joined(separator: ", "))") }
        if let x = r.originRegex { when.append("from \(x)") }
        if let x = r.contentRegex { when.append("content ~ \(x)") }
        let then: String
        switch r.action ?? "move" {
        case "trash": then = "Trash"
        case "hold": then = "leave it"
        case "ignore": then = "ignore"
        default: then = r.to ?? "?"
        }
        return (when.isEmpty ? "No conditions yet" : when.joined(separator: " · ")) + "  →  " + then
    }

    var body: some View {
        Form {
            Section {
                if model.config.rules.isEmpty {
                    Text("No rules yet. Landfall offers one when you correct the same kind of filing twice.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.config.rules.indices, id: \.self) { i in
                    LabeledContent {
                        Button("Details…") { editing = EditIndex(id: i) }
                    } label: {
                        Text(model.config.rules[i].name)
                        Text(summary(model.config.rules[i]))
                    }
                }
            } header: {
                Text("Rules")
            } footer: {
                HStack {
                    Text("Rules run before Landfall's own judgement. All conditions that are set must match.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Add Rule…") {
                        model.config.rules.append(RuleConfig(name: "New Rule", to: ""))
                        editing = EditIndex(id: model.config.rules.count - 1)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .sheet(item: $editing) { e in
            if model.config.rules.indices.contains(e.id) {
                RuleEditor(rule: $model.config.rules[e.id],
                           onDelete: { model.config.rules.remove(at: e.id); editing = nil },
                           onDone: { editing = nil })
            }
        }
    }
}

struct RuleEditor: View {
    @Binding var rule: RuleConfig
    let onDelete: () -> Void
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("Name", text: $rule.name)
                Section("When") {
                    TextField("Name matches", text: optional($rule.nameRegex), prompt: Text("Regular expression"))
                    TextField("Extensions", text: optionalList($rule.extensions), prompt: Text("pdf, docx"))
                    TextField("Content matches", text: optional($rule.contentRegex), prompt: Text("Regular expression"))
                    TextField("Downloaded from", text: optional($rule.originRegex), prompt: Text("Regular expression on the URL"))
                    TextField("Meeting with", text: optionalList($rule.participantsAny), prompt: Text("Jane Doe, Sam Lee"))
                    Picker("Only in", selection: Binding(get: { rule.root ?? "" }, set: { rule.root = $0.isEmpty ? nil : $0 })) {
                        Text("Any folder").tag("")
                        Text("Downloads").tag("downloads")
                        Text("Desktop").tag("desktop")
                        Text("Documents").tag("documents")
                    }
                }
                Section("Then") {
                    Picker("Action", selection: Binding(get: { rule.action ?? "move" }, set: { rule.action = $0 == "move" ? nil : $0 })) {
                        Text("Move").tag("move"); Text("Move to Trash").tag("trash"); Text("Leave it").tag("hold"); Text("Ignore").tag("ignore")
                    }
                    if (rule.action ?? "move") == "move" {
                        TextField("To", text: optional($rule.to), prompt: Text("Clients/{client}/{yyyy-mm}"))
                        TextField("Rename to", text: optional($rule.rename), prompt: Text("{date} {title}"))
                    }
                }
            }
            .formStyle(.grouped)
            SheetButtons(deleteTitle: "Delete Rule", onDelete: onDelete, onDone: onDone)
        }
        .frame(width: 520)
    }
}

struct SheetButtons: View {
    let deleteTitle: String
    let onDelete: () -> Void
    let onDone: () -> Void

    var body: some View {
        HStack {
            Button(deleteTitle, role: .destructive, action: onDelete)
            Spacer()
            Button("Done", action: onDone)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
        }
        .padding(16)
    }
}

// MARK: - Binding helpers

func optional(_ b: Binding<String?>) -> Binding<String> {
    Binding(get: { b.wrappedValue ?? "" }, set: { b.wrappedValue = $0.isEmpty ? nil : $0 })
}

func commaList(_ b: Binding<[String]>) -> Binding<String> {
    Binding(get: { b.wrappedValue.joined(separator: ", ") },
            set: { b.wrappedValue = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } })
}

func optionalList(_ b: Binding<[String]?>) -> Binding<String> {
    Binding(get: { (b.wrappedValue ?? []).joined(separator: ", ") },
            set: {
                let list = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                b.wrappedValue = list.isEmpty ? nil : list
            })
}

/// Render a settings pane to PNG without showing a window (for checking layouts).
func snapshotSettings(tab: Int, to url: URL) throws {
    let model = SettingsModel(agent: nil)
    let size = SettingsWindowController.size
    let views: [AnyView] = [AnyView(GeneralTab(model: model)), AnyView(FoldersTab(model: model)),
                            AnyView(SmartFilingTab(model: model)), AnyView(RulesTab(model: model))]
    let host = NSHostingView(rootView: views[min(tab, 3)].frame(width: size.width, height: size.height))
    host.frame = NSRect(origin: .zero, size: size)
    let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.5))
    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw LandfallError.action("render failed") }
    host.cacheDisplay(in: host.bounds, to: rep)
    try rep.representation(using: .png, properties: [:])!.write(to: url)
}
