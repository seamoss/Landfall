# 0002. A SQLite ledger records every item and action; items are followed by inode and bookmark

- **Status:** Accepted
- **Date:** 2026-10-12

## Context
"Where did that file go?" and "undo that" must work days later, after the user has moved things themselves. Paths change; a file dragged from Downloads to the Desktop is the same file. The record must survive app restarts and be readable by both the app and the CLI at the same time.

## Decision
Keep a SQLite database (`~/Library/Application Support/Landfall/ledger.sqlite`, WAL mode) with:
- `items` — one row per thing that landed: current path, status, hash, inode, origin URL, the latest decision (JSON) and a security-scoped bookmark.
- `events` — an append-only history per item: arrived, relocated, proposed, held, moved, trashed, undo, kept, corrected, gone.
- `content` — an FTS5 index of names, document text and OCR text (never for secrets or private items).
- `meta` — small key/values (first run, weekly report, Smart Filing usage).

Identity across moves: on arrival, an unknown path is matched to a missing item by inode; afterwards, bookmarks resolve where filed items went, so moves made in Finder become `relocated`/`corrected` events instead of lost records.

## Consequences
- `why`, `where`, `recent`, search, undo and rule learning all read the same data.
- Corrections (you moved something Landfall filed) are first-class events, which is what rule suggestions learn from.
- The ledger can hold names and text excerpts from your files; it stays on this Mac, and secrets are never indexed.
