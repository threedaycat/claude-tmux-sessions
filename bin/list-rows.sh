#!/usr/bin/env bash
# List the tracked, non-archived panes belonging to ONE tmux session — the
# "drilled in" view after Tab on a session row in claude-tmux-picker.sh.
# Also used standalone by session-preview.sh to render the summary shown
# in the right-hand preview while still browsing at the session level.
set -euo pipefail

SESSION="${1:-}"
if [ -z "$SESSION" ]; then
  echo "usage: list-rows.sh <session-name>" >&2
  exit 1
fi

STATUS_FILE="$HOME/.claude/tmux-claude-status.json"
[ -s "$STATUS_FILE" ] || exit 0

# Fields (tab-separated): display, pane_id, kind("P")
# `display` is fully pre-formatted/padded/colored below (CJK-width aware)
# and is the only field fzf shows (--with-nth=1).
python3 - "$STATUS_FILE" "$SESSION" <<'PYEOF'
import json, sys, subprocess, time, unicodedata

status_file, session_filter = sys.argv[1], sys.argv[2]
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
rows = []
for pane, e in data.items():
    if pane not in live or e.get("archived"):
        continue
    _, session, _win_idx, window_name, _pane_idx, cwd = live[pane]
    if session != session_filter:
        continue
    age = int(now - e.get("updated_at", now))
    status = e.get("status", "running")
    if status == "blocked":
        label, rank = "\033[1;31mWAIT\033[0m", -1   # permission choice — top priority, notified
    elif status == "input":
        label, rank = "\033[35mIDLE\033[0m", 0      # idle, waiting on your next message
    elif status == "done" and e.get("read"):
        label, rank = "\033[34mREAD\033[0m", 3      # done, already visited once
    elif status == "done":
        label, rank = "\033[1;32mDONE\033[0m", 1    # done, not seen yet
    else:
        label, rank = "\033[33mRUN \033[0m", 2
    key = (rank, -e.get("updated_at", 0))
    display = (
        label
        + "  "
        + pad(f"{age}s前", 8)
        + pad(window_name, 24)
        + "  "
        + cwd
    )
    rows.append((key, f"{display}\t{pane}\tP"))

for _key, line in sorted(rows, key=lambda x: x[0]):
    print(line)
PYEOF
