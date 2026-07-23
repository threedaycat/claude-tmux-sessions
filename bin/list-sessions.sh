#!/usr/bin/env bash
# Top-level list for the picker: one row per tmux session that has at
# least one tracked, non-archived Claude Code pane.
set -euo pipefail

STATUS_FILE="$HOME/.claude/tmux-claude-status.json"
[ -s "$STATUS_FILE" ] || exit 0

# Fields (tab-separated): display, session_name, kind("S")
python3 - "$STATUS_FILE" <<'PYEOF'
import json, sys, subprocess, unicodedata
from collections import defaultdict

status_file = sys.argv[1]
with open(status_file) as f:
    data = json.load(f)

fmt = "#{pane_id}\t#{session_name}"
try:
    out = subprocess.check_output(["tmux", "list-panes", "-a", "-F", fmt], text=True)
except Exception:
    out = ""

live = {}
for line in out.splitlines():
    parts = line.split("\t")
    if len(parts) == 2:
        live[parts[0]] = parts[1]

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
    return sum(2 if unicodedata.east_asian_width(c) in ("W", "F") else 1 for c in s)


def pad(s, width):
    w = vwidth(s)
    return s if w >= width else s + " " * (width - w)


by_session = defaultdict(list)
for pane, e in data.items():
    session = live.get(pane)
    if session is None or e.get("archived"):
        continue
    status = e.get("status", "running")
    if status == "blocked":
        rank = -1
    elif status == "input":
        rank = 0
    elif status == "done" and e.get("read"):
        rank = 3
    elif status == "done":
        rank = 1
    else:
        rank = 2
    by_session[session].append(rank)

sessions_sorted = sorted(by_session.keys(), key=lambda s: session_order.get(s, 1 << 30))

for s in sessions_sorted:
    ranks = by_session[s]
    blocked = sum(1 for r in ranks if r == -1)
    idle = sum(1 for r in ranks if r == 0)
    d_unread = sum(1 for r in ranks if r == 1)
    run = sum(1 for r in ranks if r == 2)
    d_read = sum(1 for r in ranks if r == 3)
    sid = session_order.get(s)
    sid_label = f"${sid} " if sid is not None else ""
    display = (
        pad(f"{sid_label}{s}", 22)
        + f"🔴{blocked}  ⏳{idle}  ✅{d_unread}  \U0001f3c3{run}  \U0001f440{d_read}"
    )
    print(f"{display}\t{s}\tS")
PYEOF
