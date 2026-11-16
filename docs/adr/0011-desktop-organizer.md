# 0011. An Organizer that empties the Desktop's dated folders, by explicit choice

- **Status:** Accepted
- **Date:** 2026-11-16

## Context
The Desktop files in place (0005): arrivals go into dated folders on the Desktop itself, so recent things stay at hand. Nothing ever moved them on, so the dated folders piled up: 21 of them holding about 50 items after five weeks.

## Decision
- An **Organizer** (menu: Organize Desktop…; CLI: `landfall organize`) lists everything in Landfall's marked filing folders, grouped by date, with a suggestion per item.
- **Suggestions reuse the rules:** each item is classified as if its folder filed into the library, so the answer is its permanent home in Documents. Trash is suggested only where the rules already say so (duplicates, opened installers, archives already unzipped); otherwise the choice is yours. No confident home means Leave.
- **Nothing moves until Apply**, and folders from the last 7 days start as Leave, because the Desktop is a working shelf. `organize --apply` follows the same default unless `--all`.
- Every move goes through the ordinary `execute` path with rule `organizer`, so it's recorded, explainable and undoable (0003). Undo All reverses a batch. Items put in a dated folder by hand are tracked when first organized.
- Dated folders left empty are moved to the Trash (they're Landfall's own). Undo recreates and re-marks a folder it needs.

## Consequences
- The Desktop's dated folders are a stage, not a destination.
- Bulk Trash is always a visible, deliberate choice; the Organizer never deletes by default.
