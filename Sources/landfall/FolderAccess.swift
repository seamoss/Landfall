import AppKit
import LandfallCore

/// In the App Sandbox, Desktop and Documents are reachable only after the user picks each once in an
/// Open panel. The resulting security-scoped bookmarks are saved and reopened at every launch.
/// (Downloads comes from an entitlement. Outside the sandbox none of this applies.)
enum FolderAccess {
    private static let key = "folderGrants"
    private static var opened: [URL] = []

    private static var grants: [String: Data] {
        get { UserDefaults.standard.dictionary(forKey: key) as? [String: Data] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    /// Reopen every saved grant. Call before watching anything.
    static func restore() {
        guard Paths.isSandboxed else { return }
        var updated = grants
        for (path, data) in grants {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI],
                                     relativeTo: nil, bookmarkDataIsStale: &stale) else {
                updated[path] = nil
                continue
            }
            if url.startAccessingSecurityScopedResource() { opened.append(url) }
            if stale, let fresh = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil,
                                                        relativeTo: nil) {
                updated[path] = fresh
            }
        }
        grants = updated
    }

    static func canRead(_ path: String) -> Bool {
        (try? FileManager.default.contentsOfDirectory(atPath: path)) != nil
    }

    /// Ask the user to choose `path`; returns true once Landfall can read it.
    @discardableResult
    static func request(_ path: String, name: String) -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: path)
        panel.prompt = "Grant Access"
        panel.message = "Choose your \(name) folder so Landfall can watch it and file what lands there."
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        guard normalize(url.path) == normalize(path) else {
            let alert = NSAlert()
            alert.messageText = "That isn't your \(name) folder"
            alert.informativeText = "Choose \(Paths.pretty(path)) to give Landfall access to it."
            alert.runModal()
            return false
        }
        guard let data = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil,
                                               relativeTo: nil) else { return false }
        var g = grants
        g[normalize(path)] = data
        grants = g
        if url.startAccessingSecurityScopedResource() { opened.append(url) }
        return canRead(path)
    }
}
