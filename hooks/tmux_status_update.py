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
  clear             called by the SessionEnd hook: Claude Code exited in
                    this pane ($TMUX_PANE), so drop its entry. Without
                    this, quitting Claude and resuming it in another pane
                    of the same window leaves a stale row behind (the old
                    pane is still alive, so liveness checks don't catch
                    it) and the window shows up twice in the picker.
  prune             remove entries whose pane is gone, or whose pane is
                    now just running a plain shell (Claude exited without
                    SessionEnd firing — crash, kill, or a session started
                    before the hook existed). Called by list-rows.sh /
                    status-badge.sh / jump-top.sh before they read, as a
                    safety net behind the SessionEnd hook.
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

# Maps stable pane coordinates ("session:window.pane" + cwd) to the Claude
# session_id last seen running there. Unlike STATUS_FILE (keyed by volatile
# %pane ids, pruned aggressively) this survives a tmux server crash, so
# restore-claude.sh can `claude --resume` each pane after tmux-resurrect
# rebuilds the layout. Entries are removed on graceful Claude exit
# (SessionEnd -> clear) — if you quit on purpose, a restore shouldn't
# bring it back; if tmux died under you, SessionEnd never fired and the
# entry is still here. Which is exactly the semantics you want.
RESTORE_FILE = os.path.expanduser("~/.claude/tmux-claude-restore.json")

RESTORE_TTL = 14 * 24 * 3600  # drop mappings not refreshed in two weeks


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


def with_status_file(fn, path=STATUS_FILE):
    """Open path read-write under an exclusive lock and hand the
    parsed dict to fn, which mutates it in place; write the result back."""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o600)
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
    """Uses lsappinfo (plain Launch Services query) instead of an
    AppleScript 'tell application "System Events"' — the latter sends an
    Apple Event and triggers macOS's Automation permission prompt every
    time it isn't durably granted; lsappinfo needs no such permission."""
    try:
        front_id = subprocess.check_output(
            ["lsappinfo", "front"], stderr=subprocess.DEVNULL, text=True,
        ).strip()
        info = subprocess.check_output(
            ["lsappinfo", "info", "-only", "name", front_id],
            stderr=subprocess.DEVNULL, text=True,
        ).strip()
        return info.split("=", 1)[1].strip('"') if "=" in info else None
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
        # Target the pane id throughout (tmux resolves it to its session)
        # — session names may contain ':'/'.' which break name targets.
        jump = (
            f'osascript -e {shlex.quote("tell application " + json.dumps(app) + " to activate")}; '
            f"tmux switch-client -t {shlex.quote(pane)}; "
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


def tmux_flash(session_name, window_name, pane):
    """In-tmux notification: flash a status-line message on every attached
    client, so a `blocked` pane is noticeable without leaving tmux (the
    macOS notification covers the you're-in-another-app case; this covers
    full-screen terminal / Do Not Disturb). Skips any client currently
    looking at the notifying pane — the permission prompt itself is
    already on that screen. `prefix W` (jump-top) then jumps straight to
    it, since `blocked` ranks first there."""
    try:
        clients = subprocess.check_output(
            ["tmux", "list-clients", "-F", "#{client_name}"],
            stderr=subprocess.DEVNULL, text=True,
        ).split()
    except Exception:
        return

    msg = f"● Claude 等你确认 · {session_name} · {window_name} — prefix W 跳转"
    for client in clients:
        try:
            active = subprocess.check_output(
                ["tmux", "display-message", "-p", "-c", client, "#{pane_id}"],
                stderr=subprocess.DEVNULL, text=True,
            ).strip()
            if active == pane:
                continue
            subprocess.run(
                ["tmux", "display-message", "-c", client, "-d", "5000", msg],
                check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            )
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

    sid = stdin_data.get("session_id")
    if sid:
        key = f"{session_name}:{window_index}.{pane_index}"

        def update_restore(data):
            now = time.time()
            for k in [k for k, v in data.items()
                      if now - v.get("updated_at", 0) > RESTORE_TTL]:
                del data[k]
            data[key] = {
                "session_id": sid,
                "cwd": cwd,
                "window_name": window_name,
                "updated_at": now,
            }

        with_status_file(update_restore, path=RESTORE_FILE)

    if status == "blocked":
        tmux_flash(session_name, window_name, pane)
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


def clear_pane():
    pane = os.environ.get("TMUX_PANE")
    if not pane:
        return

    with_status_file(lambda data: data.pop(pane, None))

    # Graceful exit — also forget the restore mapping, so a later
    # tmux-resurrect restore doesn't resurrect a Claude you closed on
    # purpose. (After a tmux crash this never runs, and the mapping
    # survives for restore-claude.sh — by design.)
    info = tmux_display(pane)
    if info is not None:
        session_name, window_index, _wname, pane_index, _cwd = info
        key = f"{session_name}:{window_index}.{pane_index}"
        with_status_file(lambda data: data.pop(key, None), path=RESTORE_FILE)


# What a pane's foreground command looks like once Claude Code has exited
# and dropped back to the shell. While Claude runs (even mid-tool-call)
# tmux reports the claude process itself, not the shell.
SHELLS = {"zsh", "bash", "fish", "sh", "dash", "ksh", "tcsh", "nu"}


def prune():
    try:
        out = subprocess.check_output(
            ["tmux", "list-panes", "-a", "-F", "#{pane_id}\t#{pane_current_command}"],
            stderr=subprocess.DEVNULL, text=True,
        )
    except Exception:
        return  # can't reach a tmux server — don't wipe the file blind

    cmd_of = {}
    for line in out.splitlines():
        parts = line.split("\t")
        if len(parts) == 2:
            cmd_of[parts[0]] = parts[1]

    def apply(data):
        for pane in list(data):
            if pane not in cmd_of or cmd_of[pane] in SHELLS:
                del data[pane]

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
    elif mode == "clear":
        clear_pane()
    elif mode == "prune":
        prune()


if __name__ == "__main__":
    main()
