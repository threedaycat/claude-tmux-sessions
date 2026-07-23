#!/usr/bin/env bash
# Ambient tmux status-bar segment: aggregate counts across ALL tracked
# panes, visible from any session/window without opening the picker or
# relying on a macOS notification. Wired into status-right via #(...).
set -euo pipefail

STATUS_FILE="$HOME/.claude/tmux-claude-status.json"
[ -s "$STATUS_FILE" ] || exit 0

# Clean out stale entries (dead pane / Claude exited) before counting.
SCRIPT_PATH="${BASH_SOURCE[0]}"
[ -L "$SCRIPT_PATH" ] && SCRIPT_PATH="$(readlink "$SCRIPT_PATH")"
BIN_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
python3 "$BIN_DIR/../hooks/tmux_status_update.py" prune 2>/dev/null || true
[ -s "$STATUS_FILE" ] || exit 0

python3 - "$STATUS_FILE" <<'PYEOF'
import json, sys, subprocess

status_file = sys.argv[1]
with open(status_file) as f:
    data = json.load(f)

try:
    out = subprocess.check_output(["tmux", "list-panes", "-a", "-F", "#{pane_id}"], text=True)
except Exception:
    out = ""
live = set(out.split())

blocked = idle = done_unread = 0
for pane, e in data.items():
    if pane not in live or e.get("archived"):
        continue
    status = e.get("status", "running")
    if status == "blocked":
        blocked += 1
    elif status == "input" and not e.get("read"):
        idle += 1
    elif status == "done" and not e.get("read"):
        done_unread += 1

# One glyph, colour-coded to the theme palette (red=blocked,
# green=done-unread, magenta=idle — the same hues as the picker's
# WAIT/DONE/IDLE labels) instead of emoji — emoji bring their own colours
# and sizes and clash with the rest of the status line. tmux honours
# #[...] style directives inside #() output; #[default] restores the
# status-right style for whatever segment follows.
parts = []
if blocked:
    parts.append(f"#[fg=#d70000]● {blocked}")
if done_unread:
    parts.append(f"#[fg=#5fff00]● {done_unread}")
if idle:
    parts.append(f"#[fg=#ff00af]● {idle}")

if parts:
    print("  ".join(parts) + "#[default] ")
PYEOF
