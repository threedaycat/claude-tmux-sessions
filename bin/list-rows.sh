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


def fmt_age(rank, secs):
    """Say what the elapsed time *means* for this status, in human units —
    a bare '1098s前' answers neither question. updated_at is the moment
    the status last changed, so per status it reads naturally as:
    RUN = since the prompt was submitted (how long it's been running),
    WAIT = since the permission prompt appeared, IDLE = since it started
    waiting on input, DONE = since it finished."""
    secs = max(0, int(secs))
    if secs < 60:
        d = f"{secs}秒"
    elif secs < 3600:
        d = f"{secs // 60}分钟"
    else:
        d = f"{secs / 3600:.1f}".rstrip("0").rstrip(".") + "小时"
    if rank == 2:
        return f"已运行 {d}"
    if rank == -1:
        return f"等确认 {d}"
    if rank == 0:
        return f"等输入 {d}"
    if rank == 1:
        return f"完成 {d}前"
    return f"{d}前"  # READ — since it last finished something


# Idle panes older than this have clearly been abandoned — Claude finished
# ages ago and you never came back. They stay listed (still reachable) but
# dimmed and sunk to the bottom (rank 4), and drop out of the ambient
# status bar entirely. Overridable via env.
IDLE_STALE = int(__import__("os").environ.get("CLAUDE_TMUX_IDLE_STALE_SECS", "7200"))  # 2h

now = time.time()
by_session = defaultdict(list)
for pane, e in data.items():
    if pane not in live or e.get("archived"):
        continue
    _, session, win_idx, window_name, pane_idx, cwd = live[pane]
    age = int(now - e.get("updated_at", now))
    status = e.get("status", "running")
    if status == "blocked":
        label, rank = "\033[1;31mWAIT\033[0m", -1   # permission choice — top priority, notified
    elif status in ("done", "input") and e.get("read"):
        label, rank = "\033[34mREAD\033[0m", 3      # already visited once — quiet until it stirs again
    elif status == "input" and age >= IDLE_STALE:
        label, rank = "\033[2mIDLE\033[0m", 4       # aged-out idle — dimmed (still in tmux order)
    elif status == "input":
        label, rank = "\033[35mIDLE\033[0m", 0      # idle, waiting on your next message
    elif status == "done":
        label, rank = "\033[1;32mDONE\033[0m", 1    # done, not seen yet
    else:
        label, rank = "\033[33mRUN \033[0m", 2
    # Rows sort by tmux's own window.pane index (not status priority), so
    # the picker mirrors the order you see in tmux itself — predictable,
    # and it lines up with the digit-jump numbers. `rank` is kept only for
    # the label colour and the header count dots.
    try:
        seq = (int(win_idx), int(pane_idx))
    except ValueError:
        seq = (1 << 30, 1 << 30)
    by_session[session].append((seq, rank, pane, label, age, window_name, cwd))

sessions_sorted = sorted(by_session.keys(), key=lambda s: session_order.get(s, 1 << 30))

row_num = 0  # global 1-based pane-row counter (the digit-jump number)
for s in sessions_sorted:
    entries = sorted(by_session[s], key=lambda x: x[0])   # by tmux window.pane
    blocked = sum(1 for _seq, rank, *_ in entries if rank == -1)
    idle = sum(1 for _seq, rank, *_ in entries if rank == 0)
    d_unread = sum(1 for _seq, rank, *_ in entries if rank == 1)
    r = sum(1 for _seq, rank, *_ in entries if rank == 2)
    d_read = sum(1 for _seq, rank, *_ in entries if rank == 3)
    stale = sum(1 for _seq, rank, *_ in entries if rank == 4)
    sid = session_order.get(s)
    sid_label = f"${sid} " if sid is not None else ""
    # Bold cyan headers vs plain, deeper-indented pane rows: the two row
    # kinds have to read apart instantly, since either can hold the
    # cursor depending on the left/right mode.
    # Counts as ●N dots in the exact colours of the row labels below
    # (red=WAIT, magenta=IDLE, green=DONE, yellow=RUN, blue=READ) — one
    # glyph, colour carries the meaning, and zero counts are simply
    # omitted instead of parading a row of 0s.
    counts = "  ".join(
        f"\033[{colour}m● {n}\033[0m"
        for colour, n in (
            ("1;31", blocked), ("35", idle), ("1;32", d_unread),
            ("33", r), ("34", d_read), ("2", stale),
        )
        if n
    )
    header = (
        "\033[1;36m" + pad(f"▾ {sid_label}{s}", 22) + "\033[0m" + counts
    )
    print(f"{header}\t\t{s}")

    # Pane rows are indented deeper than headers on purpose: with the
    # left/right mode toggle either row type can hold the cursor, and the
    # horizontal offset is what makes "am I picking a session or a pane"
    # legible at a glance. Window name leads the row — "what is this one
    # doing" is the first thing you scan for — with the status right
    # after it.
    for _seq, rank, pane, label, age, wname, cwd in entries:
        row_num += 1
        # Dim number gutter (6 visible cols, same indent pane rows always
        # had) — the digit you press to jump straight here (1-9; press / to
        # search for the rest). Global top-to-bottom, so it matches the
        # Nth-pane-row count skip-header.sh uses for pos()+accept.
        num = f"  \033[2m{row_num:>2}\033[0m  "
        if rank == 4:
            # Aged-out idle: build the row from plain text and dim the
            # whole thing in one wrap (no embedded colour codes that would
            # reset the dim early), so it recedes but stays selectable.
            body = "IDLE  " + pad(wname, 24) + pad(fmt_age(0, age), 15) + cwd
            display = f"  \033[2m{row_num:>2}  " + body + "\033[0m"
        else:
            display = (
                num
                + label
                + "  "
                + pad(wname, 24)
                + pad(fmt_age(rank, age), 15)
                + "\033[2m" + cwd + "\033[0m"
            )
        print(f"{display}\t{pane}\t{s}")
PYEOF
