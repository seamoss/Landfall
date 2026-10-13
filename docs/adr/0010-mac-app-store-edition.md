# 0010. A sandboxed Mac App Store edition built from the same sources

- **Status:** Accepted
- **Date:** 2026-10-13

## Context
The Mac App Store requires the App Sandbox and forbids self-updating, installing code outside the bundle, starting at login without consent, and sharing data with third-party AI without explicit permission. Landfall was built unsandboxed (0001, 0008). A probe app run under the intended sandbox entitlements showed most of what Landfall relies on still works — Downloads access, FSEvents, Spotlight metadata, bookmarks, Trash *and* restoring from the Trash, `du`/`zipinfo`/`ditto`/`tar`/`textutil`, the network, EventKit, `SMAppService`, the Security framework — and three things don't: Desktop and Documents without a user grant, `spctl` ("internal error in Code Signing subsystem") and `git` ("cannot be used within an App Sandbox").

## Decision
- Keep **two editions from one codebase**: the Developer ID edition (SwiftPM, Sparkle, `com.noisebeard.Landfall` for now) and the **Mac App Store edition** (`com.heavystack.Landfall`, team 4J2T5H73JM), built from an XcodeGen spec (`project.yml`, `scripts/mas.sh`) with the `MAS` compilation condition and automatic signing. The generated `.xcodeproj` is not committed.
- **Paths:** `Paths.home` is the user's real home (watched folders); `Paths.dataHome` is where Landfall keeps its config, ledger and log (the container when sandboxed).
- **Folder access:** Downloads by entitlement; Desktop and Documents through a one-time Open-panel grant from Settings › General › Permissions, stored as security-scoped app-scope bookmarks and reopened at launch.
- **Replacements:** Gatekeeper checks fall back from `spctl` to `SecStaticCode` (apps, disk images) and `pkgutil` (packages); repositories are held instead of judged when `git` can't run; project idle time comes from `.git`'s own timestamps.
- **Left out of the App Store edition** (`Capabilities`): Sparkle, Run in Terminal, Move to Applications, the 1Password CLI import; fonts open in Font Book instead of being copied to `~/Library/Fonts`. The `landfall` command isn't installed.
- **Both editions now** ask before adding the login item, and ask for explicit consent — naming Anthropic and what is sent — before Smart Filing is turned on.
- No automatic migration of the Developer ID edition's data into the container yet: Apple's container migration *moves* files, which would break a Developer ID copy still running on the same Mac. The App Store edition starts fresh.

## Consequences
- One code path, two build systems; `swift build -Xswiftc -DMAS` checks the App Store variant compiles without Xcode.
- The Developer ID edition's bundle ID switch to `com.heavystack.Landfall` is a separate, tested step (folder permissions and the login item reset; Sparkle's handling of a bundle-ID change must be verified first).
- Running both editions on one Mac at once would file everything twice; test the App Store edition with the other one quit.
