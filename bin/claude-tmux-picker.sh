#!/usr/bin/env bash
# Pick a tracked Claude Code tmux pane (running/done) and jump to it.
# Two-level UI: first pick a tmux session, then pick a window/pane within it.
set -euo pipefail

STATUS_FILE="$HOME/.claude/tmux-claude-status.json"

if [ ! -s "$STATUS_FILE" ]; then
  echo "还没有记录到任何 Claude Code session。"
  sleep 1.5
  exit 0
fi

# Fields (tab-separated): session, status, label(ansi), age, winpane, window_name, cwd, pane_id
# Already sorted globally: done-first, then most-recently-updated first.
all_rows=$(python3 - "$STATUS_FILE" <<'PYEOF'
import json, sys, subprocess, time

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

now = time.time()
rows = []
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
    rows.append((rank, -e.get("updated_at", 0),
                 f"{session}\t{status}\t{label}\t{age}s前\t{winpane}\t{window_name}\t{cwd}\t{pane}"))

rows.sort(key=lambda r: (r[0], r[1]))
for _, _, line in rows:
    print(line)
PYEOF
)

if [ -z "$all_rows" ]; then
  echo "没有找到仍然存活的 Claude Code tmux pane。"
  sleep 1.5
  exit 0
fi

# Sessions in priority order = order of first appearance in the globally-sorted
# row list (a session's earliest row is its most urgent/recent pane).
session_order=$(printf '%s\n' "$all_rows" | awk -F'\t' '!seen[$1]++ {print $1}')

session_menu=""
while IFS= read -r s; do
  counts=$(printf '%s\n' "$all_rows" | awk -F'\t' -v s="$s" '
    $1==s && $2=="done" {d++}
    $1==s && $2=="running" {r++}
    END {printf "%d\t%d", d+0, r+0}')
  done_n=$(printf '%s' "$counts" | cut -f1)
  run_n=$(printf '%s' "$counts" | cut -f2)
  session_menu+="${s}\t✅ ${done_n}  🏃 ${run_n}\n"
done <<< "$session_order"

while true; do
  chosen_session_line=$(printf '%b' "$session_menu" | fzf --delimiter=$'\t' --with-nth=1,2 \
    --header='选择 tmux session  (Enter 进入 / Esc 取消)' --layout=reverse --height=100%)
  [ -n "$chosen_session_line" ] || exit 0
  chosen_session=$(printf '%s' "$chosen_session_line" | awk -F'\t' '{print $1}')

  pane_rows=$(printf '%s\n' "$all_rows" | awk -F'\t' -v s="$chosen_session" '$1==s')

  while true; do
    chosen=$(printf '%s\n' "$pane_rows" | fzf --ansi --delimiter=$'\t' --with-nth=3,4,5,6,7 \
      --header="[$chosen_session] Enter 跳转 / Esc 返回上一级" --layout=reverse --height=100% \
      --preview 'tmux capture-pane -p -e -S -200 -t "{-1}"' \
      --preview-window='right,60%,border-left,wrap' \
      --preview-label=' 实时预览 ')

    if [ -z "$chosen" ]; then
      break  # Esc: 回到 session 菜单
    fi

    pane_id=$(printf '%s' "$chosen" | awk -F'\t' '{print $NF}')

    if [ -n "${TMUX:-}" ]; then
      tmux switch-client -t "$chosen_session"
      tmux select-window -t "$pane_id"
      tmux select-pane -t "$pane_id"
    else
      tmux attach -t "$chosen_session" \; select-window -t "$pane_id" \; select-pane -t "$pane_id"
    fi
    exit 0
  done
done
