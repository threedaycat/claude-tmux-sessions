#!/usr/bin/env bash
# Pick a tracked Claude Code tmux pane (running/done) and jump to it.
# One fzf list, one kind of row: each entry IS a pane (a Claude Code
# instance). Rows are grouped by session for readability, but the session
# itself is never a selectable stop — only panes are. Arrow keys move the
# live preview (right side) instantly; Enter jumps.
set -euo pipefail

STATUS_FILE="$HOME/.claude/tmux-claude-status.json"

if [ ! -s "$STATUS_FILE" ]; then
  echo "还没有记录到任何 Claude Code session。"
  sleep 1.5
  exit 0
fi

# Fields (tab-separated): display, pane_id
# `display` is fully pre-formatted/padded/colored by the script below
# (CJK-width aware) and is the only field fzf shows (--with-nth=1).
# pane_id is hidden metadata used for the preview and the final jump.
rows=$(python3 - "$STATUS_FILE" <<'PYEOF'
import json, sys, subprocess, time, unicodedata
from collections import defaultdict

status_file = sys.argv[1]
with open(status_file) as f:
    data = json.load(f)

fmt = "#{pane_id}\t#{session_name}\t#{window_index}\t#{window_name}\t#{pane_index}\t#{pane_current_path}"
try:
    out = subprocess.check_output(["tmux", "list-panes", "-a", "-F", fmt], text=True)
except Exception:
    out = ""

live = {}
for line in out.splitlines():
    parts = line.split("\t")
    if len(parts) == 6:
        live[parts[0]] = parts


def vwidth(s):
    w = 0
    for ch in s:
        w += 2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1
    return w


def pad(s, width):
    w = vwidth(s)
    return s if w >= width else s + " " * (width - w)


now = time.time()
by_session = defaultdict(list)
for pane, e in data.items():
    if pane not in live:
        continue
    _, session, window_index, window_name, pane_index, cwd = live[pane]
    age = int(now - e.get("updated_at", now))
    status = e.get("status", "running")
    if status == "done":
        label, rank = "\033[32mDONE\033[0m", 0
    else:
        label, rank = "\033[33mRUN \033[0m", 1
    winpane = f"{window_index}.{pane_index}"
    key = (rank, -e.get("updated_at", 0))
    by_session[session].append((key, pane, label, age, winpane, window_name, cwd))

sessions_sorted = sorted(by_session.keys(), key=lambda s: min(k for k, *_ in by_session[s]))

for s in sessions_sorted:
    for _key, pane, label, age, winpane, wname, cwd in sorted(by_session[s], key=lambda x: x[0]):
        display = (
            pad(s, 18)
            + label
            + "  "
            + pad(f"{age}s前", 8)
            + pad(winpane, 7)
            + pad(wname, 24)
            + "  "
            + cwd
        )
        print(f"{display}\t{pane}")
PYEOF
)

if [ -z "$rows" ]; then
  echo "没有找到仍然存活的 Claude Code tmux pane。"
  sleep 1.5
  exit 0
fi

chosen=$(printf '%s\n' "$rows" | fzf --ansi --delimiter=$'\t' --with-nth=1 \
  --header='↑↓ 选择 Claude 窗口 (右侧预览实时更新)  ·  Enter 跳转 / Esc 取消' \
  --layout=reverse --height=100% \
  --preview 'tmux capture-pane -p -e -S -200 -t "{2}" 2>&1 || echo "(pane 已关闭或无法读取)"' \
  --preview-window='right,60%,border-left,wrap,follow' \
  --preview-label=' Claude 实时画面 ')

[ -n "$chosen" ] || exit 0

pane_id=$(printf '%s' "$chosen" | awk -F'\t' '{print $2}')
session=$(tmux display-message -p -t "$pane_id" '#{session_name}' 2>/dev/null || true)

if [ -z "$session" ]; then
  echo "pane 已经不存在了 ($pane_id)。"
  sleep 1.5
  exit 0
fi

if [ -n "${TMUX:-}" ]; then
  tmux switch-client -t "$session"
  tmux select-window -t "$pane_id"
  tmux select-pane -t "$pane_id"
else
  tmux attach -t "$session" \; select-window -t "$pane_id" \; select-pane -t "$pane_id"
fi
