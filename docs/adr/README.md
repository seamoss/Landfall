# Architecture decision records

Short records of decisions that shape Landfall: the context, what was decided, and what follows from it.
New decisions get the next number (copy `template.md`); superseded records stay, marked as such.

| # | Decision | Status |
|---|---|---|
| [0001](0001-native-swift-app-and-cli.md) | One native Swift binary is both the menu bar app and the CLI | Accepted |
| [0002](0002-sqlite-ledger-and-item-identity.md) | A SQLite ledger records every item and action; items are followed by inode and bookmark | Accepted |
| [0003](0003-safety-model.md) | Safety model: modes, confidence thresholds, Trash instead of delete, everything undoable | Accepted |
| [0004](0004-ordered-deterministic-rules.md) | Classification is an ordered list of deterministic handlers; firm rules first | Accepted |
| [0005](0005-per-folder-filing.md) | Each watched folder chooses where its items go: the library or dated cabinets in place | Accepted |
| [0006](0006-custom-toasts-and-countdown.md) | Arrivals get a custom toast panel, not Notification Center; a guarded countdown files by default | Accepted |
| [0007](0007-smart-filing-byok.md) | Content-based filing with an LLM is an opt-in, bring-your-own-key add-on with fixed privacy limits | Accepted |
| [0008](0008-distribution.md) | Ship as a Developer ID-signed, notarized app bundle via GitHub releases | Accepted |
