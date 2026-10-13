# 0006. Arrivals get a custom toast panel, not Notification Center; a guarded countdown files by default

- **Status:** Accepted
- **Date:** 2026-10-12 (placement and design revised 2026-10-13)

## Context
When something lands, the useful moment to act is right then: open it, copy it, keep it, file it. Notification Center allows few actions, no thumbnails or trust details, and no countdown. The user also wanted a default behaviour — if they do nothing, file it.

## Decision
- A non-activating floating panel (`NSPanel`) shows a thumbnail, kind, size, origin, a trust line when relevant, the destination, and up to three actions (more under ⋯). It never takes focus. On macOS 26 it uses Liquid Glass; earlier systems get a vibrant material; Reduce Transparency gets a solid background.
- It appears **top-center under the menu bar** on the display the pointer is on. (Top-right was tried first; the panel could overhang the screen edge.)
- Actions depend on file type and trust (quarantine flag, download site, Gatekeeper). Anything that can execute code needs a second confirmation; credentials never get Open or Preview; configuration profiles get nothing but Show in Finder.
- **Countdown:** when a toast's decision is a confident (≥ 0.6) move of an ordinary file, a countdown (`autoFileSeconds`, default 20 s) files it when it runs out, then shows "Filed → …" with Undo. Hovering pauses it; using the file restarts it. Never on a timer: trashing, credentials, apps, scripts, installers, disk images, code projects, anything flagged sensitive or risky. Toggle: `toastAutoFile`.
- Only live arrivals toast — never the startup catalog. Bursts of four or more collapse into one summary.
- Notification Center is still used for alerts (credentials) and the daily digest.

## Consequences
- The countdown acts in every mode, including shadow: the visible timer is the user's chance to decline (0003).
- The UI lives in the app target, so toast behaviour beyond eligibility (`ActionPlanner.mayAutoFile`) is verified by snapshots and live checks, not unit tests.
