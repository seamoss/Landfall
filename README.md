# Landfall

Watches `~/Downloads`, `~/Desktop` and `~/Documents`, files what lands there into the library at `~/Documents`, and remembers where everything went.

| Folder | Role | Behavior |
|---|---|---|
| Downloads | intake | filed 5 min after it settles |
| Desktop | shelf | filed 2 h after you last opened it |
| Documents | library | only loose top-level files; folders (incl. `Dev`) are never touched |

Native Swift, no dependencies: FSEvents, Spotlight metadata, SQLite ledger, AppKit menu bar.

## Install

```bash
./scripts/package.sh     # universal build, Developer ID signature, DMG (+ notarization if a profile is stored)
./scripts/install.sh     # /Applications/Landfall.app, `landfall` on PATH, login item, launches
```

Or open `dist/Landfall-<version>.dmg` and drag to Applications. First launch registers the login item, asks for Calendar access and opens Settings; macOS asks once each for Desktop, Documents and Downloads. To notarize for other Macs, store credentials once:

```bash
xcrun notarytool store-credentials landfall-notary --apple-id <your-apple-id> --team-id 4J2T5H73JM
```

then re-run `package.sh`. The icon is drawn by `scripts/make-icon.swift`.

## Where things go

Each watched folder chooses (Settings › Folders, or `roots[].filing` in config):

- **The library** — `~/Documents/Clients/…`, `Meetings/…`, `Screenshots/…` (Downloads, Documents).
- **In place** — a cabinet inside the folder itself, e.g. `~/Desktop/2026-10-12/` (`{yyyy-mm-dd}`), or `{yyyy-mm-dd}/{category}`, `{yyyy-mm}`, `{category}`. Cabinet folders are tagged so they're never re-filed. Credentials still go to the library's `_Sensitive`.

## Modes

- **shadow** (default): record and propose, never touch files.
- **review**: same, but intended for `landfall apply` / the menu bar "Needs a decision" list.
- **auto**: moves at confidence ≥ 0.85, trashes at ≥ 0.9; everything else waits for you. Switching modes re-checks what's waiting.

Every action goes through the macOS Trash or a move, both logged and reversible with `landfall undo`. An undone or dragged-back item is marked *kept* and never re-filed.

## What it knows (in order)

1. **Ignore** dotfiles, partial downloads, Finder tag `Keep`, `neverTouch`, library folders.
2. **Credentials** (`.p12/.pem/.env`, `client_secret*.json`, private keys, API tokens, backup codes) → `_Sensitive`, notification, never sent to any model.
3. **Your rules** from `config.json`.
4. **Duplicates**: same hash as a tracked file, or an identical browser `name (2).ext`.
5. **Archive twins**: a `.zip` whose contents are already unzipped beside it.
6. **Junk**: empty / near-empty `Untitled*`.
7. **Installers** (`.dmg/.pkg`): trashed a day after you've opened them.
8. **Code**: git repos and projects → `Dev/` (held if dirty or name collides).
9. **Meeting transcripts** (Tactiq): client from participants/title → `Meetings/<Client>/YYYY-MM/`, renamed `YYYY-MM-DD Title.txt`.
10. **Screenshots** → `Screenshots/YYYY-MM`; `127.0.0.1_PORT_*` captures → `Screenshots/Dev Captures/port-N`.
11. **Fonts**, **résumés** (yours → `Personal`; others → `Personal/Hiring`, flagged), **contacts**, **3D/CAD**, **contracts** (→ `Clients/<X>/Contracts`), **audio/video**.
12. **Client match** on name, title, content, participants and download domain → `Clients/<X>` (data files → `Data/`).
13. **Images**, then **hold** for anything without a confident home.

## Tracking

- `landfall recent --since 3d` — the timeline, across all three folders.
- `landfall where <q>` / `landfall why <q|#id>` — current location, origin URL, verdict and full history. Items are followed by inode and bookmark, so moves you make yourself (Downloads → Desktop → somewhere) stay one item.
- `~/Desktop/Recent Landings/` — Finder aliases to everything filed in the last 7 days.
- Daily digest notification after 17:00; `landfall digest` any time.
- `landfall suggest` — when you re-file the same kind of thing twice, it proposes a rule.

## Toasts

When something new finishes landing (live arrivals only, never the startup catalog), a toast slides in top-right with the file's icon, kind, size, origin, a trust line and Landfall's suggestion, plus actions that fit the type:

| Kind | Actions |
|---|---|
| PDF / document / transcript | Open · Preview |
| Image / screenshot | Copy · Preview · Open |
| Archive | Unzip (refused if any entry escapes the folder) · Preview |
| Font · `.ics` · `.vcf` | Install font · Add to Calendar · Add to Contacts |
| Code project / file | Open in Cursor / VS Code / Zed |
| Disk image | Open disk image |
| App | Move to Applications · Open (signed + notarized); **Open…** with confirmation (unsigned); nothing (Gatekeeper-rejected) |
| Installer package | Install… (confirmation unless signed) |
| Script | **View source** first; Run in Terminal… always confirms, runs visibly with the right interpreter |
| `.webloc` / `.fileloc` | Open link… confirms and shows the target |
| Office macro docs | Preview first; Open… warns about macros |
| Credential | Move to _Sensitive · Open 1Password — never Open/Preview |
| Configuration profile | nothing but Show in Finder |

Every toast also has **File to …** (acts now, even in shadow mode — you asked), **Keep here**, and **Show in Finder**. Trust comes from the quarantine flag, the download URL and `spctl` (Gatekeeper). Nothing ever runs without a click; anything that can execute code asks twice. Bursts of 4+ arrivals collapse into one summary toast. When auto mode files something, a "Filed → …" toast offers Undo.

Toasts stay for `toastSeconds` (default 20, paused while hovered); turn them off with `"toasts": false`. Preview one with `landfall toast <file>` or render it with `--snapshot out.png [--dark]`.

## Housekeeping

`landfall space [path]` reports rebuildable folders (`node_modules`, `.venv`, `.next`, `.turbo`, cargo `target`) and agent worktrees under `~/Documents/Dev`, with project idle time. `--trash --idle 30 --yes` moves the idle ones to the Trash (worktrees are report-only).

## Config

`~/.config/landfall/config.json` — partial files are fine; missing keys use defaults. The running agent reloads it within 10 s.

```json
{
  "rules": [
    { "name": "Bike manuals", "nameRegex": "(?i)(vulcan|carburetor)", "to": "Personal/Vehicles" },
    { "name": "Globex calls", "participantsAny": ["Jane Doe"], "to": "Meetings/Globex/{yyyy-mm}", "rename": "{date} {title}" }
  ],
  "clients": [{ "name": "Initech", "people": ["Sam Lee", "Jane Doe"] }]
}
```

Files: ledger `~/Library/Application Support/Landfall/ledger.sqlite`, log `~/Library/Logs/Landfall/landfall.log`, agent `~/Library/LaunchAgents/dev.landfall.agent.plist`.

## Context and learning

- **Calendar:** the meeting you were in when a file arrived (title, attendees, attendee email domains) picks the client. Transcripts use their own start time.
- **OCR + search:** text in screenshots and images is recognized on arrival; `landfall search <words>` (or `landfall reindex`) covers names, document text and image text. Secrets and private items are never indexed.
- **Renaming:** copy suffixes go (`Report (2).pdf` → `Report.pdf`), punctuation typos are respelled (`Resu,e` → `Resume`), hash names become a title, heading or `Image 2026-10-12 1430`.
- **Rules from corrections:** move two filed items of a kind to the same folder and a toast offers a rule (shared meeting participant → download site → common name word, plus extension). Add / Not now / Never.
- **Smart Filing (add-on, bring your own key):** Claude reads what's inside a file and picks the folder or client. Off by default; turn it on in Settings › Smart Filing with your Anthropic API key (stored in the login keychain, or `landfall ai-key`). Choose the model (Haiku 5.5 default, Sonnet 5.5, Opus 5.5), whether it reads only files Landfall isn't sure about or every document with text, how much text is sent (1,500 / 4,000 / 8,000 characters), and whether its picks may file on their own (otherwise they're suggestions). Your rules and the safety rules (secrets, duplicates, installers, screenshots, code, résumés, contacts) always win. Sent: name, type, size, download site, the excerpt (or OCR text), folder names, client names/aliases/domains — never credentials, private files, or people's names. "Try on a File…" shows the exact payload first; a monthly counter tracks usage. Toasts show its pick with ✦ and Claude's reason.
- **1Password:** "Import to 1Password…" on credential toasts, the menu, or `landfall vault --all` creates a Document item via the `op` CLI (`brew install 1password-cli`, then enable CLI integration in 1Password), then trashes the original.
- **Housekeeping:** Monday-morning space report toast (Clean idle / Show report); older `localhost` captures of the same page proposed for the Trash; Downloads untouched for 30 days expire to the Trash in auto mode (one "Undo all" toast).

## Shortcuts, Raycast, scripting

`landfall://settings · scan · review · space · file?path= · ask?path= · toast?path=` — see `extras/raycast/README.md`. Raycast script commands ship in `extras/raycast`. `recent`, `where`, `review` and `search` take `--json`.
