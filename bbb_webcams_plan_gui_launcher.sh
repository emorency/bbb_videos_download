#!/usr/bin/env bash
set -euo pipefail

if [ $# -lt 2 ]; then
  echo "Usage: $0 <recording_dir> <NUM>" >&2
  echo "Example: $0 2026-08-04 01" >&2
  exit 1
fi

rec_dir="$1"
num="$2"
repo_dir="$(cd "$(dirname "$0")" && pwd)"

# Open in native Terminal.app to avoid VS Code sandbox GUI/XPC issues.
py_cmd="python3"
if [ -x "$repo_dir/.venv-qt/bin/python" ]; then
  py_cmd="$repo_dir/.venv-qt/bin/python"
fi
cmd="cd \"$repo_dir\"; \"$py_cmd\" bbb_webcams_plan_gui_qt.py \"$rec_dir\" \"$num\""
escaped_cmd="${cmd//\\/\\\\}"
escaped_cmd="${escaped_cmd//\"/\\\"}"
if osascript <<APPLESCRIPT
 tell application "Terminal" to activate
 delay 0.2
 tell application "Terminal"
   do script "$escaped_cmd"
 end tell
APPLESCRIPT
then
  echo "Launched GUI in Terminal.app"
else
  echo "Could not control Terminal.app from this environment." >&2
  echo "Run this command manually in Terminal.app:" >&2
  echo "  cd \"$repo_dir\" && \"$py_cmd\" bbb_webcams_plan_gui_qt.py \"$rec_dir\" \"$num\"" >&2
  exit 2
fi
