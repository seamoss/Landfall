import AppKit
import LandfallCore
import Sparkle

/// Sparkle auto-updates. Landfall lives in the menu bar, so scheduled update checks use
/// "gentle reminders": no window steals focus; a notification and the menu offer the update instead.
final class Updater: NSObject, SPUStandardUserDriverDelegate {
    static let shared = Updater()

    private var controller: SPUStandardUpdaterController?
    /// The version waiting to be installed, if a check found one.
    private(set) var availableVersion: String?
    var onChange: (() -> Void)?

    /// Only the app bundle updates itself; the CLI and snapshots never start Sparkle.
    func start() {
        guard controller == nil, Bundle.main.bundleIdentifier != nil else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
    }

    var updater: SPUUpdater? { controller?.updater }
    var isRunning: Bool { controller != nil }

    var automaticallyChecks: Bool {
        get { updater?.automaticallyChecksForUpdates ?? true }
        set { updater?.automaticallyChecksForUpdates = newValue }
    }

    var automaticallyDownloads: Bool {
        get { updater?.automaticallyDownloadsUpdates ?? false }
        set { updater?.automaticallyDownloadsUpdates = newValue }
    }

    var lastChecked: Date? { updater?.lastUpdateCheckDate }

    func checkForUpdates() {
        guard let controller else { return }
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    // MARK: SPUStandardUserDriverDelegate

    var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Show Sparkle's window only if the user is already looking at Landfall.
    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        immediateFocus
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem,
                                                   state: SPUUserUpdateState) {
        availableVersion = update.displayVersionString
        onChange?()
        if !handleShowingUpdate {
            notify("Landfall \(update.displayVersionString) is available",
                   "Choose “Update to \(update.displayVersionString)…” in the Landfall menu.")
        }
    }

    func standardUserDriverWillFinishUpdateSession() {
        availableVersion = nil
        onChange?()
    }
}
