# Changelog

All notable changes to Landfall. Versions follow [Semantic Versioning](https://semver.org); the format follows [Keep a Changelog](https://keepachangelog.com).
`scripts/release.sh` turns the **Unreleased** section into the next version's release notes.

## [Unreleased]

## [0.6.0] - 2026-10-13

### Added
- **Automatic updates** with Sparkle: Landfall checks once a day for signed, notarized updates from GitHub, notifies you without interrupting, and offers "Update to …" in the menu. Settings › General › Updates has the switches and a Check Now button. Install this version manually once; later versions arrive by themselves.

## [0.5.1] - 2026-10-13

### Security
- The app no longer ships a starter configuration containing real client and people names; new installs start with no clients, and personal details live only in your own config file. Upgrade from 0.5.0.

### Added
- `scripts/release.sh`: one command from version bump to notarized GitHub release.
- Architecture decision records in `docs/adr/`.

### Changed
- README rewritten for the current app.

## [0.5.0] - 2026-10-13

### Added
- **Smart Filing** — an opt-in, bring-your-own-key add-on: Claude reads what's inside a file and picks its folder or client. Model choice (Haiku 5.5, Sonnet 5.5, Opus 5.5), scope (only unsure files, or every document with text), excerpt size (1,500 / 4,000 / 8,000 characters), "may file on its own", a payload preview ("Try on a File…") and a monthly usage count. Toasts wait for and show its pick.

### Changed
- Settings › Clients became Settings › Smart Filing (clients and projects are a section within it).
- The toast's "Ask Claude" action is now "Smart File" and only appears when an API key is set.

## [0.4.3] - 2026-10-13

### Added
- Settings › General › **File after**: an adjustable auto-file countdown (5 seconds to 5 minutes), separate from how long other toasts stay.

## [0.4.2] - 2026-10-13

### Changed
- Toasts appear top-center under the menu bar and drop down into place.

## [0.4.1] - 2026-10-13

### Fixed
- Toasts could hang off the right edge of the screen; they now appear on the display the pointer is on.

## [0.4.0] - 2026-10-13

### Changed
- Design pass for macOS 26: Icon Composer app icon with a Liquid Glass arrow; Liquid Glass toasts with capsule buttons, a round close button and an inset countdown; custom menu bar glyph; menu with section headers, file icons, subtitles and badges; Settings with toolbar tabs, instant apply, a permissions overview, and System Settings-style lists with editing sheets.
- Toasts respect Reduce Motion, Reduce Transparency and Increase Contrast, and are announced to VoiceOver.

## [0.3.4] - 2026-10-13

### Changed
- The toast's primary action is always drawn in the accent color.

## [0.3.3] - 2026-10-13

### Changed
- The toast's close button sits in the top-right corner.

## [0.3.2] - 2026-10-12

First version in the repository.

### Added
- Watches Downloads, Desktop and Documents; classifies arrivals (credentials, duplicates, archive twins, installers, code, meeting transcripts, screenshots, fonts, résumés, contacts, contracts, media, clients) and files them, with an undoable SQLite ledger.
- Modes: shadow, review, auto. Trash instead of delete; everything undoable.
- Actionable toasts with type-aware, safety-checked actions and a countdown that auto-files confident moves.
- Per-folder filing: the library, or dated cabinets in place (Desktop › 2026-10-12).
- Calendar context, OCR and full-text search, rename suggestions, rules learned from corrections, 1Password import, weekly space report, Downloads expiry.
- Settings window, URL scheme, Raycast script commands, `--json` output.
- Signed with Developer ID and notarized.
