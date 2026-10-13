# 0001. One native Swift binary is both the menu bar app and the CLI

- **Status:** Accepted
- **Date:** 2026-10-12

## Context
Landfall needs file-system events, Spotlight metadata (download origin, screenshot flag, last-opened date), the Trash, Finder aliases, Vision OCR, EventKit, Keychain, Gatekeeper checks and a menu bar presence. It must run all day with little overhead, and macOS grants folder access (TCC) per signed binary. A Python or Electron prototype would need bridges for most of this, ship a runtime, and present an unstable identity to TCC.

## Decision
Write Landfall in Swift with no third-party dependencies, as a Swift package with two targets:
- `LandfallCore` — the engine, classifier, ledger and every rule. No UI. Fully unit-tested.
- `landfall` — one executable that is the menu bar app when launched by LaunchServices (no terminal attached) and the command-line tool when run from a shell.

The `landfall` command on PATH is a small wrapper that `exec`s the binary inside `Landfall.app`, so the CLI and the app share one identity, config, ledger and keychain items.

## Consequences
- One code path for decisions: the CLI, the menu, toasts and timers all call the same engine.
- Tests cover the core without UI; UI is verified with offscreen snapshots (`landfall toast --snapshot`, `landfall settings --snapshot`). Liquid Glass only renders on a live screen, so glass details need a human look.
- Builds use SwiftPM rather than an Xcode project, so some Xcode-only features (App Intents metadata) are out of reach; the URL scheme and CLI cover automation instead.
