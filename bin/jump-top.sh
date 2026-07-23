#!/usr/bin/env bash
# Jump straight to the single highest-priority tracked pane (blocked >
# idle > done-unread > running > read) — no picker UI at all. Bound to a
# tmux key for "just take me to whatever needs me most".
set -euo pipefail

STATUS_FILE="$HOME/.claude/tmux-claude-status.json"

if [ ! -s "$STATUS_FILE" ]; then
  tmux display-message "没有追踪到任何 Claude Code pane"
  exit 0
fi

SCRIPT_PATH="${BASH_SOURCE[0]}"
[ -L "$SCRIPT_PATH" ] && SCRIPT_PATH="$(readlink "$SCRIPT_PATH")"
BIN_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"

# Clean out stale entries (dead pane / Claude exited) so we never jump to
# a pane whose Claude is long gone.
python3 "$BIN_DIR/../hooks/tmux_status_update.py" prune 2>/dev/null || true

pane_id=$(python3 - "$STATUS_FILE" <<'PYEOF'
import json, sys, subprocess

status_file = sys.argv[1]
with open(status_file) as f:
    data = json.load(f)

try:
    out = subprocess.check_output(["tmux", "list-panes", "-a", "-F", "#{pane_id}"], text=True)
except Exception:
    out = ""
live = set(out.split())

def rank_of(status, read):
    if status == "blocked":
        return -1
    if status in ("done", "input") and read:
        return 3
    if status == "input":
        return 0
    if status == "done":
        return 1
    return 2

best = None
best_key = None
for pane, e in data.items():
    if pane not in live or e.get("archived"):
        continue
    key = (rank_of(e.get("status", "running"), e.get("read")), -e.get("updated_at", 0))
    if best_key is None or key < best_key:
        best_key = key
        best = pane

print(best or "")
PYEOF
)

if [ -z "$pane_id" ]; then
  tmux display-message "没有需要处理的 pane"
  exit 0
fi

if ! tmux display-message -p -t "$pane_id" '' >/dev/null 2>&1; then
  tmux display-message "pane 已经不存在了 ($pane_id)"
  exit 0
fi

python3 "$BIN_DIR/../hooks/tmux_status_update.py" mark-read "$pane_id" 2>/dev/null || true

# Target the pane id directly (tmux resolves it to its session) — session
# names may contain ':'/'.' which break name-based targets.
tmux switch-client -t "$pane_id"
tmux select-window -t "$pane_id"
tmux select-pane -t "$pane_id"
