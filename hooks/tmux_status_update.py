#!/usr/bin/env python3
"""Record Claude Code session status (running/done/read) keyed by tmux pane,
so claude-tmux-picker.sh can list which sessions just finished and jump to
them.

Modes:
  running / done   called by hooks (UserPromptSubmit / Stop) for the pane
                    they're running in ($TMUX_PANE); overwrites the entry,
                    which naturally clears any stale "read" flag.
  notify           called by the Notification hook. Branches on the
                    hook's own "notification_type" field:
                      permission_prompt -> "blocked" (top priority, and
                        fires a macOS notification — Claude's progress is
                        actually stalled on a decision only the user can
                        make)
                      idle_prompt / anything else -> "input" (Claude
                        finished and is just waiting on the next message —
                        worth a glance, not urgent, no notification)
  mark-read <pane>  called by claude-tmux-picker.sh right after it jumps to
                    <pane>, so a "done" pane the user has actually visited
                    once shows as already-seen instead of unread.
  mark-archived <pane>  called from within the picker (a bound key) to
                    hide a pane you're done caring about from the list.
                    Cleared automatically the next time that pane goes
                    "running" or "done" again, since those overwrite the
                    whole entry.
"""
import sys
import os
import json
import time
import fcntl
import shlex
import shutil
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


def frontmost_app():
    try:
        return subprocess.check_output(
            ["osascript", "-e",
             'tell application "System Events" to name of first process whose frontmost is true'],
            stderr=subprocess.DEVNULL, text=True,
        ).strip()
    except Exception:
        return None


def notify_blocked(session_name, pane, window_name, message):
    """macOS notification — 'blocked' means Claude's progress is actually
    stalled on a decision only the user can make, unlike a quiet 'done'.
    Clicking it (via terminal-notifier's -execute) jumps straight to the
    pane; a plain osascript notification can't do that."""
    title = f"Claude 需要你处理 · {session_name}:{window_name}"
    body = message or "有权限确认或问题在等你回复"

    if shutil.which("terminal-notifier"):
        app = frontmost_app() or "iTerm2"
        jump = (
            f'osascript -e {shlex.quote("tell application " + json.dumps(app) + " to activate")}; '
            f"tmux switch-client -t {shlex.quote(session_name)}; "
            f"tmux select-window -t {shlex.quote(pane)}; "
            f"tmux select-pane -t {shlex.quote(pane)}"
        )
        try:
            subprocess.run(
                ["terminal-notifier", "-title", title, "-message", body,
                 "-sound", "Ping", "-execute", jump],
                check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            )
            return
        except Exception:
            pass

    script = (
        f'display notification {json.dumps(body)} '
        f'with title {json.dumps(title)} sound name "Ping"'
    )
    try:
        subprocess.run(["osascript", "-e", script], check=False,
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception:
        pass


def record_status(status, stdin_data):
    pane = os.environ.get("TMUX_PANE")
    if not pane:
        return  # not running inside tmux, nothing to track

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

    if status == "blocked":
        notify_blocked(session_name, pane, window_name, stdin_data.get("message"))


def record_notification():
    stdin_data = {}
    try:
        stdin_data = json.load(sys.stdin)
    except Exception:
        pass

    # permission_prompt: Claude is stuck waiting for an approve/deny choice
    # — actually blocks progress. idle_prompt (or anything unrecognized):
    # Claude's done and just waiting on the next message — worth noticing,
    # not urgent.
    status = "blocked" if stdin_data.get("notification_type") == "permission_prompt" else "input"
    record_status(status, stdin_data)


def mark_read(pane):
    def apply(data):
        if pane in data:
            data[pane]["read"] = True

    with_status_file(apply)


def mark_archived(pane):
    def apply(data):
        if pane in data:
            data[pane]["archived"] = True

    with_status_file(apply)


def main():
    if len(sys.argv) < 2:
        return
    mode = sys.argv[1]

    if mode in ("running", "done"):
        stdin_data = {}
        try:
            stdin_data = json.load(sys.stdin)
        except Exception:
            pass
        record_status(mode, stdin_data)
    elif mode == "notify":
        record_notification()
    elif mode == "mark-read" and len(sys.argv) == 3:
        mark_read(sys.argv[2])
    elif mode == "mark-archived" and len(sys.argv) == 3:
        mark_archived(sys.argv[2])


if __name__ == "__main__":
    main()
