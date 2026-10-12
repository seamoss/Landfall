#!/bin/bash
# @raycast.schemaVersion 1
# @raycast.title What Landed Today
# @raycast.mode fullOutput
# @raycast.packageName Landfall
# @raycast.icon 🛬
# @raycast.description Everything that arrived in Downloads, Desktop and Documents today, and where it went.
PATH="$HOME/.local/bin:$PATH" landfall recent --since 1d | sed 's/\x1b\[[0-9;]*m//g'
