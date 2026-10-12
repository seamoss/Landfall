#!/bin/bash
# @raycast.schemaVersion 1
# @raycast.title Where Did It Go?
# @raycast.mode fullOutput
# @raycast.packageName Landfall
# @raycast.icon 🔎
# @raycast.argument1 { "type": "text", "placeholder": "file name or words inside it" }
export PATH="$HOME/.local/bin:$PATH"
{ landfall where "$1"; echo; echo "— content matches —"; landfall search "$1"; } | sed 's/\x1b\[[0-9;]*m//g'
