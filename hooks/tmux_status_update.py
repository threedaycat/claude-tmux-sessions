#!/usr/bin/env python3
"""Record Claude Code session status (running/done/read) keyed by tmux pane,
so claude-tmux-picker.sh can list which sessions just finished and jump to
them.

Modes:
  running / done   called by hooks (UserPromptSubmit / Stop) for the pane
                    they're running in ($TMUX_PANE); overwrites the entry,
                    which naturally clears any stale "read" flag.
  mark-read <pane>  called by claude-tmux-picker.sh right after it jumps to
                    <pane>, so a "done" pane the user has actually visited
                    once shows as already-seen instead of unread.
"""
import sys
import os
import json
import time
import fcntl
import subprocess

STATUS_FILE = os.path.expanduser("~/.claude/tmux-claude-status.json")


def tmux_display(pane):
    fmt = "#{session_name}\t#{window_index}\t#{window_name}\t#{pane_index}\t#{pane_current_path}"
    try:
        out = subprocess.check_output(
            ["tmux", "display-message", "-p", "-t", pane, fmt],
            stderr=subprocess.DEVNULL, text=True,
        ).strip()
    except Exception:
        return None
    parts = out.split("\t")
    if len(parts) != 5:
        return None
    return parts


def with_status_file(fn):
    """Open STATUS_FILE read-write under an exclusive lock and hand the
    parsed dict to fn, which mutates it in place; write the result back."""
    os.makedirs(os.path.dirname(STATUS_FILE), exist_ok=True)
    fd = os.open(STATUS_FILE, os.O_RDWR | os.O_CREAT, 0o600)
    with os.fdopen(fd, "r+") as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        try:
            f.seek(0)
            raw = f.read()
            data = json.loads(raw) if raw.strip() else {}
        except Exception:
            data = {}
        fn(data)
        f.seek(0)
        f.truncate()
        json.dump(data, f, indent=2)
        fcntl.flock(f, fcntl.LOCK_UN)


def record_status(status):
    pane = os.environ.get("TMUX_PANE")
    if not pane:
        return  # not running inside tmux, nothing to track

    stdin_data = {}
    try:
        stdin_data = json.load(sys.stdin)
    except Exception:
        pass

    info = tmux_display(pane)
    if info is None:
        return
    session_name, window_index, window_name, pane_index, cwd = info

    entry = {
        "pane": pane,
        "session": session_name,
        "window": window_index,
        "window_name": window_name,
        "pane_index": pane_index,
        "cwd": cwd,
        "status": status,
        "updated_at": time.time(),
        "session_id": stdin_data.get("session_id"),
    }

    with_status_file(lambda data: data.__setitem__(pane, entry))


def mark_read(pane):
    def apply(data):
        if pane in data:
            data[pane]["read"] = True

    with_status_file(apply)


def main():
    if len(sys.argv) < 2:
        return
    mode = sys.argv[1]

    if mode in ("running", "done"):
        record_status(mode)
    elif mode == "mark-read" and len(sys.argv) == 3:
        mark_read(sys.argv[2])


if __name__ == "__main__":
    main()
