#!/bin/bash
# @raycast.schemaVersion 1
# @raycast.title File Selected Items Now
# @raycast.mode compact
# @raycast.packageName Landfall
# @raycast.icon 🗂️
# @raycast.description Ask Landfall to file whatever is selected in Finder, right now.
osascript -l JavaScript -e 'Application("Finder").selection().map(i => decodeURI(i.url()).replace("file://", "")).join("\n")' |
while IFS= read -r p; do
  [ -n "$p" ] && open "landfall://file?path=$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1]))' "$p")"
done
echo "Sent to Landfall"
