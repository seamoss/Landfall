#!/bin/bash
# @raycast.schemaVersion 1
# @raycast.title Landfall Review
# @raycast.mode fullOutput
# @raycast.packageName Landfall
# @raycast.icon 🛬
PATH="$HOME/.local/bin:$PATH" landfall review | sed 's/\x1b\[[0-9;]*m//g'
