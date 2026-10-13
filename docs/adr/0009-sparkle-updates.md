# 0009. Update in place with Sparkle, fed from the public repo; gentle reminders only

- **Status:** Accepted
- **Date:** 2026-10-13

## Context
Without an updater, every fix meant downloading and dragging a new DMG. Sparkle 2 is the standard for apps distributed outside the App Store: it verifies an EdDSA signature on each update in addition to Apple's code signature and notarization. It needs a feed and update files reachable without authentication — possible now that `seamoss/Landfall` is public. Landfall is a menu bar app, so Sparkle's default of opening an update window on a schedule would interrupt whatever the user is doing.

## Decision
- Add Sparkle 2 as a Swift package dependency of the app target only (`LandfallCore` stays dependency-free). Embed `Sparkle.framework` in `Contents/Frameworks` and sign its helpers inside-out (Installer.xpc, Downloader.xpc, Autoupdate, Updater.app, framework, then the app), as Sparkle documents for Developer ID apps.
- Feed: `appcast.xml` at the repo root, served from `https://raw.githubusercontent.com/seamoss/Landfall/main/appcast.xml`. Update files are the notarized DMGs attached to GitHub releases.
- Signing: an EdDSA key pair made with Sparkle's `generate_keys`. The private key stays in the release machine's login keychain (backed up separately); the public key is `SUPublicEDKey` in Info.plist.
- `scripts/release.sh` signs the DMG with `sign_update`, adds an item to `appcast.xml` (`scripts/appcast.py`: version, build, minimum macOS, HTML notes from the CHANGELOG, signature), pushes the tag, publishes the release, and only then pushes `main`, so the feed never points at a missing file.
- Checks run once a day. **Gentle reminders:** a scheduled check that finds an update shows Sparkle's window only if Landfall is already in focus; otherwise it posts a notification and the menu shows "Update to …". Background download and install is opt-in (Settings › General › Updates).
- Only the app bundle starts Sparkle; the CLI and offscreen snapshots never do.

## Consequences
- Updates are verified twice: Sparkle's EdDSA signature and Apple's notarization.
- Losing the Sparkle private key means installed copies can't accept further updates; it must be backed up.
- Copies older than 0.6.0 have no updater; they need one manual install of 0.6.0 or later.
- `raw.githubusercontent.com` caches for a few minutes, so a new release can take that long to be offered.
