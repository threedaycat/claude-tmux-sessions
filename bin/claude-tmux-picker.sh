#!/usr/bin/env bash
# Pick a tracked Claude Code tmux pane (running/done) and jump to it.
# Single fzf screen showing a session > window > pane tree; arrow keys move
# the live preview (right side), one Enter jumps. No intermediate menus.
set -euo pipefail

# Resolve through the ~/.claude/hooks symlink to this script's real location,
# so preview-pane.sh (which lives next to it) can always be found.
SCRIPT_PATH="${BASH_SOURCE[0]}"
[ -L "$SCRIPT_PATH" ] && SCRIPT_PATH="$(readlink "$SCRIPT_PATH")"
BIN_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
STATUS_FILE="$HOME/.claude/tmux-claude-status.json"

if [ ! -s "$STATUS_FILE" ]; then
  echo "还没有记录到任何 Claude Code session。"
  sleep 1.5
  exit 0
fi

# Fields (tab-separated): display, kind(S/W/P), session, window_index, pane_id
# `display` is fully pre-formatted/padded/colored/indented by the script
# below (CJK-width aware) and is the only field fzf shows (--with-nth=1).
# The rest are hidden metadata used for the preview and the final jump.
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
# tree[session][window_index] = [ {pane_index, window_name, cwd, status, updated_at, pane_id}, ... ]
tree = defaultdict(lambda: defaultdict(list))
for pane, e in data.items():
    if pane not in live:
        continue
    _, session, window_index, window_name, pane_index, cwd = live[pane]
    tree[session][window_index].append({
        "pane_index": pane_index,
        "window_name": window_name,
        "cwd": cwd,
        "status": e.get("status", "running"),
        "updated_at": e.get("updated_at", now),
        "pane_id": pane,
    })


def rank_of(status):
    return 0 if status == "done" else 1


def best_key(panes):
    return min((rank_of(p["status"]), -p["updated_at"]) for p in panes)


def session_best_key(session):
    return best_key([p for panes in tree[session].values() for p in panes])


rows = []
for session in sorted(tree.keys(), key=session_best_key):
    all_panes = [p for panes in tree[session].values() for p in panes]
    d = sum(1 for p in all_panes if p["status"] == "done")
    r = len(all_panes) - d
    header = pad(f"▾ {session}", 28) + f"✅{d}  \U0001f3c3{r}"
    rows.append(f"{header}\tS\t{session}\t\t")

    windows = tree[session]
    for window_index in sorted(windows.keys(), key=lambda w: best_key(windows[w])):
        panes = windows[window_index]
        wname = panes[0]["window_name"]
        wd = sum(1 for p in panes if p["status"] == "done")
        wr = len(panes) - wd
        wheader = pad(f"  ▸ {window_index}:{wname}", 28) + f"✅{wd}  \U0001f3c3{wr}"
        rows.append(f"{wheader}\tW\t{session}\t{window_index}\t")

        for p in sorted(panes, key=lambda p: (rank_of(p["status"]), -p["updated_at"])):
            age = int(now - p["updated_at"])
            if p["status"] == "done":
                label = "\033[32mDONE\033[0m"
            else:
                label = "\033[33mRUN \033[0m"
            line = (
                "    "
                + pad(f"{window_index}.{p['pane_index']}", 7)
                + label
                + "  "
                + pad(f"{age}s前", 8)
                + p["cwd"]
            )
            rows.append(f"{line}\tP\t{session}\t{window_index}\t{p['pane_id']}")

for line in rows:
    print(line)
PYEOF
)

if [ -z "$rows" ]; then
  echo "没有找到仍然存活的 Claude Code tmux pane。"
  sleep 1.5
  exit 0
fi

chosen=$(printf '%s\n' "$rows" | fzf --ansi --delimiter=$'\t' --with-nth=1 \
  --header='↑↓ 浏览 session/window/pane (预览实时更新)  ·  Enter 跳转 / Esc 取消' \
  --layout=reverse --height=100% \
  --preview "$BIN_DIR/preview-pane.sh '{2}' '{3}' '{4}' '{5}'" \
  --preview-window='right,60%,border-left,wrap' \
  --preview-label=' 实时预览 ')

[ -n "$chosen" ] || exit 0

kind=$(printf '%s' "$chosen" | awk -F'\t' '{print $2}')
session=$(printf '%s' "$chosen" | awk -F'\t' '{print $3}')
window_index=$(printf '%s' "$chosen" | awk -F'\t' '{print $4}')
pane_id=$(printf '%s' "$chosen" | awk -F'\t' '{print $5}')

target_pane=""
case "$kind" in
  P) target_pane="$pane_id" ;;
  W) target_pane=$(tmux list-panes -t "${session}:${window_index}" -F '#{pane_id}' 2>/dev/null | head -1) ;;
esac

if [ -n "${TMUX:-}" ]; then
  tmux switch-client -t "$session"
  if [ -n "$target_pane" ]; then
    tmux select-window -t "$target_pane"
    tmux select-pane -t "$target_pane"
  fi
else
  if [ -n "$target_pane" ]; then
    tmux attach -t "$session" \; select-window -t "$target_pane" \; select-pane -t "$target_pane"
  else
    tmux attach -t "$session"
  fi
fi
