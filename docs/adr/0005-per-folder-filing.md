# 0005. Each watched folder chooses where its items go: the library or dated cabinets in place

- **Status:** Accepted
- **Date:** 2026-10-12

## Context
Downloads are transient and belong in the library (`~/Documents`). The Desktop is a working surface: the user wanted Desktop items to stay on the Desktop, but tidied, in date-stamped folders.

## Decision
Each root has a `filing` setting:
- `library` — the classifier's destination under `~/Documents` is used as is.
- `inPlace` — the destination is rewritten into a cabinet inside the root (or a chosen folder) using a layout template: `{yyyy-mm-dd}` (default for the Desktop), `{yyyy-mm-dd}/{category}`, `{yyyy-mm}`, `{category}` or `{path}`.

Cabinet folders get a `dev.landfall.cabinet` extended attribute when created, so the watcher never treats them as new arrivals. Credentials always go to the library's `_Sensitive`, whatever the folder's setting.

## Consequences
- Rules and classification stay folder-agnostic; placement is a final, separate step (`Classifier.localize`).
- Renaming or deleting a cabinet's xattr would make it look like an arrival; the name pattern alone is not trusted.
