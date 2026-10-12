import AppKit
import EventKit
import LandfallCore
import ServiceManagement
import SwiftUI

final class SettingsModel: ObservableObject {
    @Published var config: Config
    @Published var apiKeyDraft = ""
    @Published var hasAPIKey = Keychain.apiKey() != nil
    @Published var loginItem = SMAppService.mainApp.status == .enabled
    @Published var calendarAccess = EKEventStore.authorizationStatus(for: .event) == .fullAccess
    @Published var dirty = false
    @Published var status = ""
    weak var agent: Agent?

    init(agent: Agent?) {
        self.agent = agent
        config = (try? Config.load()) ?? .standard
    }

    func save() {
        do {
            try config.save()
            agent?.configStamp = nil
            agent?.reloadConfigIfChanged()
            dirty = false
            status = "Saved"
        } catch { status = "Couldn't save: \(error)" }
    }

    func revert() {
        config = (try? Config.load()) ?? .standard
        dirty = false
        status = ""
    }

    func saveKey() {
        do {
            try Keychain.setAPIKey(apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines))
            apiKeyDraft = ""
            hasAPIKey = Keychain.apiKey() != nil
            status = hasAPIKey ? "API key saved to the keychain" : "API key removed"
        } catch { status = "\(error)" }
    }

    func setLoginItem(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch { status = "Login item: \(error.localizedDescription)" }
        loginItem = SMAppService.mainApp.status == .enabled
    }

    func requestCalendar() {
        agent?.calendar.requestAccess { [weak self] ok in
            self?.calendarAccess = ok
            if !ok { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!) }
        }
    }
}

final class SettingsWindowController: NSWindowController {
    init(engine: Engine, agent: Agent) {
        let model = SettingsModel(agent: agent)
        let host = NSHostingController(rootView: SettingsView(model: model))
        let window = NSWindow(contentViewController: host)
        window.title = "Landfall Settings"
        // Fixed size: no resizing, no zoom, no full screen.
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.collectionBehavior = [.fullScreenNone]
        window.setContentSize(SettingsView.size)
        window.contentMinSize = SettingsView.size
        window.contentMaxSize = SettingsView.size
        window.center()
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError() }
}

struct SettingsView: View {
    static let size = NSSize(width: 720, height: 600)
    @ObservedObject var model: SettingsModel
    @State var tab = 0

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $tab) {
                GeneralTab(model: model).tabItem { Label("General", systemImage: "gearshape") }.tag(0)
                FoldersTab(model: model).tabItem { Label("Folders", systemImage: "folder") }.tag(1)
                ClientsTab(model: model).tabItem { Label("Clients", systemImage: "person.2") }.tag(2)
                RulesTab(model: model).tabItem { Label("Rules", systemImage: "list.bullet.rectangle") }.tag(3)
            }
            .padding()
            Divider()
            HStack {
                Text(model.status).font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Open config.json") { NSWorkspace.shared.open(Paths.configURL) }
                Button("Revert") { model.revert() }.disabled(!model.dirty)
                Button("Save") { model.save() }.keyboardShortcut("s").buttonStyle(.borderedProminent).disabled(!model.dirty)
            }
            .padding(12)
        }
        .frame(width: SettingsView.size.width, height: SettingsView.size.height)
        .onChange(of: model.config.json) { _ in model.dirty = true }
    }
}

extension Config {
    /// For change tracking in the settings window.
    var json: String {
        (try? JSONEncoder().encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
}

// MARK: - Tabs

struct GeneralTab: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                Picker("Mode", selection: $model.config.mode) {
                    Text("Shadow — only watch").tag(Mode.shadow)
                    Text("Review — I approve").tag(Mode.review)
                    Text("Auto — file confident items").tag(Mode.auto)
                }
                Toggle("Launch at login", isOn: Binding(get: { model.loginItem }, set: { model.setLoginItem($0) }))
                Toggle("Show a toast when something lands", isOn: $model.config.toasts)
                Stepper("Toasts stay \(Int(model.config.toastSeconds)) seconds", value: $model.config.toastSeconds, in: 5...120, step: 5)
                Toggle("File items automatically when the countdown ends", isOn: $model.config.toastAutoFile)
                    .disabled(!model.config.toasts)
                Text("Only confident moves of ordinary files. Never trashes, and never touches credentials, apps, scripts or installers. Hover a toast to pause it.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Notifications and daily digest", isOn: $model.config.notify)
            }
            Section("Calendar") {
                Toggle("Use the meeting I'm in to pick a client", isOn: $model.config.useCalendar)
                HStack {
                    Text(model.calendarAccess ? "Calendar access granted" : "Calendar access not granted")
                        .foregroundStyle(.secondary)
                    Spacer()
                    if !model.calendarAccess { Button("Grant access…") { model.requestCalendar() } }
                }
            }
            Section("Claude") {
                Toggle("Ask Claude automatically about files with no home", isOn: $model.config.ai.auto)
                TextField("Model", text: $model.config.ai.model)
                HStack {
                    SecureField(model.hasAPIKey ? "API key saved in keychain — paste to replace" : "Anthropic API key", text: $model.apiKeyDraft)
                    Button(model.apiKeyDraft.isEmpty && model.hasAPIKey ? "Remove" : "Save key") { model.saveKey() }
                        .disabled(model.apiKeyDraft.isEmpty && !model.hasAPIKey)
                }
                Text("Only the file name, type, origin and a 1,500-character excerpt are sent. Credentials and anything flagged private never are. Claude's answers are always suggestions.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("1Password") {
                TextField("Vault for imported credentials (blank = default)", text: optional($model.config.onePasswordVault))
                Text(OnePassword.cli != nil ? "1Password CLI found" : OnePassword.installHint)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Space") {
                Toggle("Weekly report of rebuildable folders (Monday morning)", isOn: $model.config.spaceReport)
                TextField("Project folders", text: commaList($model.config.spaceRoots))
                Stepper("Idle after \(Int(model.config.spaceIdleDays)) days", value: $model.config.spaceIdleDays, in: 7...365, step: 7)
                Button("Run space report now") { model.agent?.weeklySpaceReport(force: true) }
            }
        }
        .formStyle(.grouped)
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

struct ClientsTab: View {
    @ObservedObject var model: SettingsModel
    @State private var selection: Int?

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(model.config.clients.indices, id: \.self) { i in
                        Text(model.config.clients[i].name).tag(i)
                    }
                }
                HStack {
                    Button { model.config.clients.append(ClientConfig(name: "New client")); selection = model.config.clients.count - 1 } label: { Image(systemName: "plus") }
                    Button {
                        if let i = selection { model.config.clients.remove(at: i); selection = nil }
                    } label: { Image(systemName: "minus") }.disabled(selection == nil)
                    Spacer()
                }
                .buttonStyle(.borderless).padding(6)
            }
            .frame(minWidth: 180, maxWidth: 220)

            if let i = selection, model.config.clients.indices.contains(i) {
                Form {
                    TextField("Name", text: $model.config.clients[i].name)
                    TextField("Folder (default Clients/<name>)", text: optional($model.config.clients[i].folder))
                    TextField("Aliases", text: commaList($model.config.clients[i].aliases))
                    TextField("People", text: commaList($model.config.clients[i].people))
                    TextField("Domains", text: commaList($model.config.clients[i].domains))
                    Text("Comma-separated. People match meeting participants and calendar attendees; domains match download sites and attendee emails.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .formStyle(.grouped)
            } else {
                Text("Select a client").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

struct RulesTab: View {
    @ObservedObject var model: SettingsModel
    @State private var selection: Int?

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(model.config.rules.indices, id: \.self) { i in
                        Text(model.config.rules[i].name).tag(i)
                    }
                }
                HStack {
                    Button { model.config.rules.append(RuleConfig(name: "New rule", to: "")); selection = model.config.rules.count - 1 } label: { Image(systemName: "plus") }
                    Button {
                        if let i = selection { model.config.rules.remove(at: i); selection = nil }
                    } label: { Image(systemName: "minus") }.disabled(selection == nil)
                    Spacer()
                }
                .buttonStyle(.borderless).padding(6)
            }
            .frame(minWidth: 200, maxWidth: 240)

            if let i = selection, model.config.rules.indices.contains(i) {
                Form {
                    TextField("Name", text: $model.config.rules[i].name)
                    Section("When (all that are set must match)") {
                        TextField("Name matches regex", text: optional($model.config.rules[i].nameRegex))
                        TextField("Extensions", text: optionalList($model.config.rules[i].extensions))
                        TextField("Content matches regex", text: optional($model.config.rules[i].contentRegex))
                        TextField("Downloaded from (regex)", text: optional($model.config.rules[i].originRegex))
                        TextField("Meeting participants include", text: optionalList($model.config.rules[i].participantsAny))
                        TextField("Only in folder (downloads/desktop/documents)", text: optional($model.config.rules[i].root))
                    }
                    Section("Then") {
                        Picker("Action", selection: Binding(get: { model.config.rules[i].action ?? "move" },
                                                            set: { model.config.rules[i].action = $0 == "move" ? nil : $0 })) {
                            Text("Move").tag("move"); Text("Trash").tag("trash"); Text("Leave it").tag("hold"); Text("Ignore").tag("ignore")
                        }
                        TextField("To (library-relative; {yyyy} {yyyy-mm} {client})", text: optional($model.config.rules[i].to))
                        TextField("Rename ({date} {title} {base} {ext})", text: optional($model.config.rules[i].rename))
                    }
                }
                .formStyle(.grouped)
            } else {
                Text("Select a rule").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
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

/// Render a settings tab to PNG without showing a window (for checking layouts).
func snapshotSettings(tab: Int, to url: URL) throws {
    let model = SettingsModel(agent: nil)
    let host = NSHostingView(rootView: SettingsView(model: model, tab: tab))
    host.frame = NSRect(x: 0, y: 0, width: 720, height: 760)
    let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.5))
    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw LandfallError.action("render failed") }
    host.cacheDisplay(in: host.bounds, to: rep)
    try rep.representation(using: .png, properties: [:])!.write(to: url)
}
