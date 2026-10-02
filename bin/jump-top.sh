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

pane_id=$(BIN_DIR="$BIN_DIR" python3 - "$STATUS_FILE" <<'PYEOF'
import json, os, sys, subprocess

status_file = sys.argv[1]
with open(status_file) as f:
    data = json.load(f)

# 按有效状态排（主 agent + 它的 subagent，见 effective_status.py）：主 agent 停了但
# subagent 还在跑的，是「在跑」不是「完成」，不该被当成一条结果抢先跳过去。
try:
    sys.path.insert(0, os.environ.get("BIN_DIR") or ".")
    import effective_status
    data = effective_status.effective(data)
except Exception:
    pass

try:
    out = subprocess.check_output(["tmux", "list-panes", "-a", "-F", "#{pane_id}"], text=True)
except Exception:
    out = ""
live = set(out.split())

import os, time
# Idle older than this has been abandoned — don't let "jump to what needs
# me most" land on a stale idle over a fresh done. Matches list-rows.sh /
# status-badge.sh. Overridable via env.
IDLE_STALE = int(os.environ.get("CLAUDE_TMUX_IDLE_STALE_SECS", "7200"))  # 2h
now = time.time()


def rank_of(status, read, age):
    if status == "blocked":
        return -1
    if status in ("done", "input") and read:
        return 3
    if status == "input":
        return 4 if age >= IDLE_STALE else 0   # aged-out idle sinks below all
    if status == "done":
        return 1
    return 2

best = None
best_key = None
for pane, e in data.items():
    if pane not in live or e.get("archived"):
        continue
    age = now - e.get("updated_at", now)
    key = (rank_of(e.get("status", "running"), e.get("read"), age), -e.get("updated_at", 0))
    if best_key is None or key < best_key:
        best_key = key
        best = pane

print(best or "")
PYEOF
)

# An explicit pane (the status bar's clickable WAIT chip names one) wins
# over the ranking above.
case "${1:-}" in %*) pane_id="$1" ;; esac

if [ -z "$pane_id" ]; then
  tmux display-message "没有需要处理的 pane"
  exit 0
fi

# has-session, not `display-message -p -t <pane> ''`: the latter exits 0 even
# for a pane id that no longer exists, so this guard never fired. See the same
# fix in claude-tmux-picker.sh.
if ! tmux has-session -t "$pane_id" 2>/dev/null; then
  tmux display-message "pane 已经不存在了 ($pane_id)"
  exit 0
fi

python3 "$BIN_DIR/../hooks/tmux_status_update.py" mark-read "$pane_id" 2>/dev/null || true

# Target the pane id directly (tmux resolves it to its session) — session
# names may contain ':'/'.' which break name-based targets.
tmux switch-client -t "$pane_id"
tmux select-window -t "$pane_id"
tmux select-pane -t "$pane_id"
