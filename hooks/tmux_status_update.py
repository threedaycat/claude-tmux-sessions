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


def play_sound():
    """A short audible cue when a pane goes blocked. Uses afplay on a
    system sound directly rather than the notification's own sound —
    afplay rings regardless of whether the terminal has macOS notification
    permission, which the -sound path silently depends on. Best-effort,
    backgrounded so it never delays the hook."""
    snd = "/System/Library/Sounds/Ping.aiff"
    if not (shutil.which("afplay") and os.path.exists(snd)):
        return
    try:
        subprocess.Popen(
            ["afplay", snd],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
    except Exception:
        pass


def _shorten(s, limit):
    s = " ".join(str(s).split())
    return s if len(s) <= limit else s[: limit - 1] + "…"


def _describe_tool(name, inp):
    """One line naming what a tool call would actually do.

    The tool name alone is what Claude Code's own notification already says
    ("Claude needs your permission to use Bash") and it's the part you can
    guess; the argument is the part you're actually deciding about. Bash
    especially — approving `ls` and approving `rm -rf build` are not the same
    decision, and the notification is where that difference has to show up."""
    inp = inp if isinstance(inp, dict) else {}
    # mcp__server__tool is machine-readable, not human-readable — name the
    # tool and put the server in parentheses. Done first so the argument
    # branches below decorate the readable label, not the raw id.
    label = name
    if name.startswith("mcp__"):
        parts = name.split("__")
        if len(parts) >= 3:
            label = f"{parts[2]} ({parts[1]})"
    if name == "Bash":
        return "Bash · " + _shorten(inp.get("command", ""), 90)
    for key in ("file_path", "notebook_path", "path"):
        if inp.get(key):
            return f"{label} · " + _shorten(rel_path(inp[key]), 70)
    for key in ("url", "pattern", "query", "description", "prompt"):
        if inp.get(key):
            return f"{label} · " + _shorten(inp[key], 70)
    return label


def rel_path(p):
    """Paths read better shortened: the interesting part of
    /Users/you/projects/api/handlers/users.go is the tail, and a notification
    is ~60 characters wide."""
    p = str(p)
    home = os.path.expanduser("~")
    if p.startswith(home + "/"):
        p = "~" + p[len(home):]
    parts = p.split("/")
    return "/".join(parts[-3:]) if len(parts) > 3 else p


def pending_action(transcript_path):
    """What Claude is stuck asking about, read from the transcript.

    A tool call that has been answered leaves a matching tool_result behind,
    so the one still unanswered is the one holding up the pane. That test
    beats "the newest tool call" outright: it can't name something you
    already approved five minutes ago, which would be worse than saying
    nothing at all. Returns (action, task) — both may be None, and the caller
    keeps its old wording in that case.

    Only the tail of the file is read: transcripts run to megabytes, and this
    is on the path of a notification the user is waiting for."""
    if not transcript_path or not os.path.exists(transcript_path):
        return None, None
    try:
        with open(transcript_path, "rb") as f:
            f.seek(0, 2)
            f.seek(max(0, f.tell() - 512_000))
            lines = f.read().decode("utf-8", "replace").splitlines()
    except OSError:
        return None, None

    calls = {}       # tool_use id -> description, in order
    answered = set()
    task = None
    for line in lines:
        if '"' not in line:
            continue
        try:
            obj = json.loads(line)
        except Exception:
            continue
        msg = obj.get("message") or {}
        content = msg.get("content")
        if not isinstance(content, list):
            # A plain-string user message is a typed prompt — the task line.
            if obj.get("type") == "user" and isinstance(content, str) and content.strip():
                task = content
            continue
        for block in content:
            if not isinstance(block, dict):
                continue
            if block.get("type") == "tool_use":
                calls[block.get("id")] = _describe_tool(
                    block.get("name", "?"), block.get("input")
                )
            elif block.get("type") == "tool_result":
                answered.add(block.get("tool_use_id"))
            elif (block.get("type") == "text" and obj.get("type") == "user"
                    and block.get("text", "").strip()):
                task = block["text"]

    pending = [d for cid, d in calls.items() if cid not in answered]
    action = pending[-1] if pending else None
    # Drop the local-command noise Claude Code injects for slash commands.
    if task and task.lstrip().startswith("<"):
        task = None
    return action, _shorten(task, 60) if task else None


def notify_blocked(session_name, pane, window_name, message, action=None, task=None):
    """macOS notification — 'blocked' means Claude's progress is actually
    stalled on a decision only the user can make, unlike a quiet 'done'.
    Clicking it (via terminal-notifier's -execute) jumps straight to the
    pane; a plain osascript notification can't do that."""
    # Say *what* it wants, not that it wants something. The hook's own
    # `message` is boilerplate ("Claude needs your permission to use Bash"),
    # which tells you nothing you couldn't guess and makes every one of these
    # look identical — the complaint that prompted this. The action comes
    # first because it's the decision; the task line under it says which of a
    # dozen panes this is, in words you wrote.
    title = f"⏸ 等你确认 · {session_name}:{window_name}"
    if action:
        body = action if not task else f"{action}\n↳ {task}"
    else:
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
            # No -sound here: play_sound() handles the audible cue via
            # afplay, which doesn't depend on notification permission.
            subprocess.run(
                ["terminal-notifier", "-title", title, "-message", body,
                 "-execute", jump],
                check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            )
            return
        except Exception:
            pass

    script = (
        f'display notification {json.dumps(body)} '
        f'with title {json.dumps(title)}'
    )  # sound comes from play_sound()/afplay, not the notification
    try:
        subprocess.run(["osascript", "-e", script], check=False,
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception:
        pass


def tmux_flash(session_name, window_name, pane, action=None):
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

    # Same reasoning as the macOS notification: name the action. This line
    # is one status-line wide, so the action is clipped harder and the task
    # line is dropped entirely — window name plus "what it wants" is what
    # makes it decidable without switching.
    what = f" — {_shorten(action, 60)}" if action else ""
    msg = f"● 等你确认 · {session_name} · {window_name}{what} — prefix W 跳转"
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
        transcript = stdin_data.get("transcript_path")
        play_sound()
        # Read the transcript once and hand the result to both channels —
        # they're saying the same thing to two different places, and the tail
        # read shouldn't happen twice on a path the user is waiting on.
        action, task = pending_action(transcript)
        tmux_flash(session_name, window_name, pane, action)
        notify_blocked(session_name, pane, window_name,
                       stdin_data.get("message"), action, task)


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
        # A pane id is only meaningful relative to one tmux server, and we
        # have no way to ask "is this MY server?" — so require the file and
        # the server to overlap by at least one pane before believing a
        # missing id means the pane died. Without this check, running any
        # reader while $TMUX points at a *different* server (a second server
        # for screenshots, a nested session, a stale env var) makes every id
        # look dead and silently wipes the whole file. Observed: it ate 20
        # live panes' worth of state.
        #
        # No overlap is ambiguous — wrong server, or a tmux restart that
        # renumbered everything — so do nothing. That's self-correcting
        # either way: entries whose pane is absent are invisible in the UI
        # anyway (every reader joins against list-panes), and the moment one
        # live pane registers again there IS an overlap, so the next prune
        # clears the corpses.
        if data and not any(pane in cmd_of for pane in data):
            return
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
