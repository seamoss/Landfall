#!/bin/bash
# Install dist/Landfall.app (or a given .app) for this user: /Applications, `landfall` on PATH,
# retire the old LaunchAgent, then launch (first launch registers the login item and opens Settings).
set -euo pipefail
cd "$(dirname "$0")/.."
SRC="${1:-dist/Landfall.app}"
DEST=/Applications
[ -w "$DEST" ] || DEST="$HOME/Applications"
mkdir -p "$DEST" "$HOME/.local/bin"

pkill -f "Landfall.app/Contents/MacOS/Landfall" 2>/dev/null || true
launchctl bootout "gui/$(id -u)/dev.landfall.agent" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/dev.landfall.agent.plist"

rm -rf "$DEST/Landfall.app"
ditto "$SRC" "$DEST/Landfall.app"
# A wrapper, not a symlink: exec'ing the real path lets macOS see the app bundle (login item, keychain, notifications).
rm -f "$HOME/.local/bin/landfall"
printf '#!/bin/sh\nexec "%s/Landfall.app/Contents/MacOS/Landfall" "$@"\n' "$DEST" > "$HOME/.local/bin/landfall"
chmod +x "$HOME/.local/bin/landfall"
open "$DEST/Landfall.app"
echo "✓ Installed $DEST/Landfall.app · CLI: $HOME/.local/bin/landfall"
