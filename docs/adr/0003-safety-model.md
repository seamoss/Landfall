# 0003. Safety model: modes, confidence thresholds, Trash instead of delete, everything undoable

- **Status:** Accepted
- **Date:** 2026-10-12

## Context
A tool that moves your files on its own must never lose anything and must earn trust before it acts. Mistakes are inevitable; they must be cheap and visible.

## Decision
- **Modes:** *shadow* (record and propose; nothing moves), *review* (everything waits for approval), *auto* (confident decisions act). New installs start in shadow.
- **Confidence:** every decision carries a confidence. In auto, moves need ≥ 0.85 and trashing needs ≥ 0.9; anything lower is a proposal.
- **No deletion:** "remove" always means the macOS Trash. The only files Landfall deletes outright are its own: the Finder aliases in *Recent Landings* and the retired LaunchAgent plist on uninstall.
- **Undo everything:** every applied move or trash is an event that `undo` reverses. An undone item, or one you drag back, becomes *kept* and is never re-filed.
- **Explicit clicks act in any mode:** "File now", "Apply" and the toast countdown (see 0006) are your decision, so they work even in shadow mode.
- **Never automatic:** running scripts, opening apps or installers, installing profiles, unpacking archives that escape their folder.

## Consequences
- Users can watch a week of proposals before switching to auto.
- Thresholds are config (`autoThreshold`, `trashThreshold`), not code.
- Features that act on their own (expiry, auto-filing, Smart Filing) must express themselves as decisions with a confidence and go through the same `decide → execute → event` path.

## Amendment (2026-11-05): looking at kept items again
"Never re-filed" stays true of anything automatic. When you ask (`landfall rescan --kept`, or Review Kept Items in the menu), Landfall re-judges kept items with today's rules and may propose a home. Those proposals carry an `askFirst` flag: they never execute on their own in any mode, the flag survives re-checks, and Keep returns the item to kept. Only a click moves them.
