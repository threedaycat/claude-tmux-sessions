#!/usr/bin/env bash
# Pick a tracked Claude Code tmux pane (running/done) and jump to it.
# One fzf list: pane rows are the only selectable stops. Session header
# rows are shown for visual grouping only — up/down/entry skip over them
# via bin/skip-header.sh. Arrow keys move the live preview (right side)
# instantly; Enter jumps.
set -euo pipefail

# Resolve through the ~/.claude/hooks symlink to this script's real location,
# so skip-header.sh (which lives next to it) can always be found.
SCRIPT_PATH="${BASH_SOURCE[0]}"
[ -L "$SCRIPT_PATH" ] && SCRIPT_PATH="$(readlink "$SCRIPT_PATH")"
BIN_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"

STATUS_FILE="$HOME/.claude/tmux-claude-status.json"

if [ ! -s "$STATUS_FILE" ]; then
  echo "还没有记录到任何 Claude Code session。"
  sleep 1.5
  exit 0
fi

# Fields (tab-separated): display, pane_id
# `display` is fully pre-formatted/padded/colored by the script below
# (CJK-width aware) and is the only field fzf shows (--with-nth=1).
# Header rows (one per session, for visual grouping only) have an empty
# pane_id field; pane rows carry their tmux pane id.
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
    _, session, _win_idx, window_name, _pane_idx, cwd = live[pane]
    age = int(now - e.get("updated_at", now))
    status = e.get("status", "running")
    if status == "done":
        label, rank = "\033[32mDONE\033[0m", 0
    else:
        label, rank = "\033[33mRUN \033[0m", 1
    key = (rank, -e.get("updated_at", 0))
    by_session[session].append((key, pane, label, age, window_name, cwd))

sessions_sorted = sorted(by_session.keys(), key=lambda s: min(k for k, *_ in by_session[s]))

for s in sessions_sorted:
    entries = sorted(by_session[s], key=lambda x: x[0])
    d = sum(1 for key, *_ in entries if key[0] == 0)
    r = len(entries) - d
    header = pad(f"▾ {s}", 18) + f"✅{d}  \U0001f3c3{r}"
    print(f"{header}\t")

    for _key, pane, label, age, wname, cwd in entries:
        display = (
            "  "
            + label
            + "  "
            + pad(f"{age}s前", 8)
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

TOTAL=$(printf '%s\n' "$rows" | wc -l | tr -d ' ')
HEADER_POS=$(printf '%s\n' "$rows" | awk -F'\t' '{ if ($2 == "") print NR }' | paste -sd, -)
export HEADER_POS=",${HEADER_POS}," TOTAL

chosen=$(printf '%s\n' "$rows" | fzf --ansi --delimiter=$'\t' --with-nth=1 \
  --header='↑↓ 选择 Claude 窗口 (右侧预览实时更新)  ·  Enter 跳转 / Esc 取消' \
  --layout=reverse --height=100% \
  --preview 'tmux capture-pane -p -e -S -200 -t {2} 2>&1 || echo "(pane 已关闭或无法读取)"' \
  --preview-window='right,60%,border-left,wrap,follow' \
  --preview-label=' Claude 实时画面 ' \
  --bind "load:transform:$BIN_DIR/skip-header.sh 0 init" \
  --bind "down:transform:$BIN_DIR/skip-header.sh {n} down" \
  --bind "up:transform:$BIN_DIR/skip-header.sh {n} up")

[ -n "$chosen" ] || exit 0

pane_id=$(printf '%s' "$chosen" | awk -F'\t' '{print $2}')

if [ -z "$pane_id" ]; then
  # Landed on a header row somehow (e.g. it was the only line matching a
  # search query) — there's nothing to jump to.
  exit 0
fi

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
