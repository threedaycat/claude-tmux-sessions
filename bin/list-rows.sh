#!/usr/bin/env bash
# Generate the picker's row list (session headers + pane rows) to stdout.
# Standalone so it can be used both as fzf's initial input and re-invoked
# via fzf's reload() action (e.g. after archiving a pane) to refresh the
# list in place.
set -euo pipefail

STATUS_FILE="$HOME/.claude/tmux-claude-status.json"
[ -s "$STATUS_FILE" ] || exit 0

# Drop stale entries first (pane gone, or Claude exited and the pane is
# back to a plain shell) — otherwise quitting Claude and resuming it in a
# sibling pane shows the same window twice.
SCRIPT_PATH="${BASH_SOURCE[0]}"
[ -L "$SCRIPT_PATH" ] && SCRIPT_PATH="$(readlink "$SCRIPT_PATH")"
BIN_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
python3 "$BIN_DIR/../hooks/tmux_status_update.py" prune 2>/dev/null || true
[ -s "$STATUS_FILE" ] || exit 0

# Fields (tab-separated): display, pane_id, session_name
# `display` is fully pre-formatted/padded/colored below (CJK-width aware)
# and is the only field fzf shows (--with-nth=1). Header rows (one per
# session) have an empty pane_id field; pane rows carry their tmux pane
# id. Both carry the session name, so Enter on a header (session-select
# mode) knows where to jump and the preview can show the session's active
# pane. Archived panes are omitted entirely.
python3 - "$STATUS_FILE" <<'PYEOF'
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

# Session display order follows tmux's own session_id (creation order —
# the same stable order tmux itself lists sessions in), not "most urgent
# session first". Nobody wants the sidebar reshuffling every time a pane
# finishes.
session_order = {}
try:
    out = subprocess.check_output(
        ["tmux", "list-sessions", "-F", "#{session_name}\t#{session_id}"], text=True
    )
    for line in out.splitlines():
        name, sid = line.split("\t")
        session_order[name] = int(sid.lstrip("$"))
except Exception:
    pass


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
    if pane not in live or e.get("archived"):
        continue
    _, session, _win_idx, window_name, _pane_idx, cwd = live[pane]
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
    by_session[session].append((key, pane, label, age, window_name, cwd))

sessions_sorted = sorted(by_session.keys(), key=lambda s: session_order.get(s, 1 << 30))

for s in sessions_sorted:
    entries = sorted(by_session[s], key=lambda x: x[0])
    blocked = sum(1 for key, *_ in entries if key[0] == -1)
    idle = sum(1 for key, *_ in entries if key[0] == 0)
    d_unread = sum(1 for key, *_ in entries if key[0] == 1)
    r = sum(1 for key, *_ in entries if key[0] == 2)
    d_read = sum(1 for key, *_ in entries if key[0] == 3)
    sid = session_order.get(s)
    sid_label = f"${sid} " if sid is not None else ""
    header = pad(f"▾ {sid_label}{s}", 22) + f"🔴{blocked}  ⏳{idle}  ✅{d_unread}  \U0001f3c3{r}  \U0001f440{d_read}"
    print(f"{header}\t\t{s}")

    # Pane rows are indented deeper than headers on purpose: with the
    # left/right mode toggle either row type can hold the cursor, and the
    # horizontal offset is what makes "am I picking a session or a pane"
    # legible at a glance.
    for _key, pane, label, age, wname, cwd in entries:
        display = (
            "    "
            + label
            + "  "
            + pad(f"{age}s前", 8)
            + pad(wname, 24)
            + "  "
            + cwd
        )
        print(f"{display}\t{pane}\t{s}")
PYEOF
