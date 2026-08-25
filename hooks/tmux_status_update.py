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
  mark-seen <pane>  called by the `pane-focus-in` tmux hook: you switched
                    to this pane, so a finished-and-unread one counts as
                    read. Unlike mark-read it leaves `blocked` alone —
                    cycling past a window must not dismiss a WAIT alert.
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
  sync-windows      recompute the per-window badge (@claude_win, rendered
                    inline by window-status-format) for every window from
                    the current state. Called automatically by every mode
                    that changes state; exposed on its own so a status-bar
                    render can refresh it too.
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
    """Hand the parsed dict at path to fn, which mutates it in place, and
    write the result back atomically under an exclusive lock.

    Atomicity is the whole point. The obvious version — truncate the file,
    then dump onto the same handle — leaves a window where the file is
    empty or half-written, and anything that kills the process inside that
    window makes the state file permanently 0 bytes. That is not
    hypothetical: status-badge.sh runs prune() on *every* status-bar
    render, tmux kills #() children that overrun its timeout, and the
    machine sleeps overnight. The next reader then parses an empty file,
    starts from {}, and writes back only its own entry — every other
    tracked pane silently vanishes, and since entries are only ever
    (re)written by a hook firing, an idle pane never comes back until you
    go talk to it. Write to a temp file and rename instead: rename is
    atomic, so a reader sees either the whole old file or the whole new
    one, never a stump.

    The lock lives on a *separate* .lock file rather than on the data file,
    because os.replace swaps the inode out from under anyone holding a lock
    on the old one — two writers would each hold a valid lock on different
    inodes and happily clobber each other. A fixed lock path can't be
    replaced, so it actually excludes."""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    lock_fd = os.open(path + ".lock", os.O_RDWR | os.O_CREAT, 0o600)
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX)
        try:
            with open(path) as f:
                raw = f.read()
            data = json.loads(raw) if raw.strip() else {}
        except FileNotFoundError:
            data = {}
        except Exception:
            # Non-empty but unparseable: with atomic writes this shouldn't
            # happen, so it means something outside this function mangled
            # it. Keep the evidence instead of overwriting it — silently
            # starting from {} is exactly the data loss we just fixed.
            try:
                os.replace(path, path + ".corrupt")
            except Exception:
                pass
            data = {}
        fn(data)
        tmp = f"{path}.{os.getpid()}.tmp"
        try:
            with open(tmp, "w") as f:
                json.dump(data, f, indent=2)
                f.flush()
                os.fsync(f.fileno())
            os.chmod(tmp, 0o600)
            os.replace(tmp, path)
        except Exception:
            try:
                os.unlink(tmp)
            except Exception:
                pass
            raise
    finally:
        os.close(lock_fd)


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
    # Before the restore bookkeeping and the (slower) blocked notification
    # path: the window list is the thing you're looking at, so it should
    # flip the moment the state does.
    sync_window_badges()

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
    sync_window_badges()


def mark_seen(pane):
    """Softer mark-read for the `pane-focus-in` tmux hook: switching to a
    pane means you're looking at its output, so a finished-and-unread pane
    is now read — but a `blocked` one is untouched. Cycling past a window
    must never silently dismiss a WAIT alert; that one you dismiss by
    dealing with the prompt (or by jumping to it on purpose, which is what
    the picker's mark-read is for)."""
    def apply(data):
        e = data.get(pane)
        if e and e.get("status") in ("done", "input"):
            e["read"] = True

    with_status_file(apply)
    sync_window_badges()


def mark_archived(pane):
    def apply(data):
        if pane in data:
            data[pane]["archived"] = True

    with_status_file(apply)
    sync_window_badges()


def clear_pane():
    pane = os.environ.get("TMUX_PANE")
    if not pane:
        return

    with_status_file(lambda data: data.pop(pane, None))
    sync_window_badges()

    # Graceful exit — also forget the restore mapping, so a later
    # tmux-resurrect restore doesn't resurrect a Claude you closed on
    # purpose. (After a tmux crash this never runs, and the mapping
    # survives for restore-claude.sh — by design.)
    info = tmux_display(pane)
    if info is not None:
        session_name, window_index, _wname, pane_index, _cwd = info
        key = f"{session_name}:{window_index}.{pane_index}"
        with_status_file(lambda data: data.pop(key, None), path=RESTORE_FILE)


# Per-window badge in tmux's own window list ---------------------------------
#
# status-badge.sh gives you the aggregate ("3 running, 1 waiting") but not
# *which window*, so answering "who's waiting?" still meant opening the
# picker. This writes each window's own state into a window-scoped user
# option, which the window list renders inline:
#
#     set -g window-status-format '#I#{E:@claude_win} #W'
#
# `E:` (expand twice) is required, not decoration: the RUN badge is itself
# a small format that reads the pane's live spinner glyph. Plain
# `#{@claude_win}` would print its source text.
#
# A user option costs nothing at render time (no #() subprocess per window),
# and every mutation below refreshes it, so the bar changes the instant a
# hook fires rather than at the next status-interval tick.
WINDOW_OPTION = "@claude_win"

# An unread DONE nobody came back to in this long has been abandoned; it
# stays in the bar but greys out, same threshold and reasoning as the picker
# and status-badge.sh.
IDLE_STALE = int(os.environ.get("CLAUDE_TMUX_IDLE_STALE_SECS", "7200"))  # 2h

# Same icons and colours as the picker's labels, so one vocabulary covers
# both: ⏸ WAIT (blocked on a permission choice), ✔ DONE (finished, unread),
# ▶ RUN (Claude busy), ✓ READ (finished, already visited), dim ✔ (unread but
# aged out). ︎ forces the narrow text glyph so the bar keeps its widths.
#
# RUN is deliberately the quietest of the three live states: it's the one
# you can do nothing about, and it's also the one that moves (see
# run_spinner) — a moving thing in the corner of your eye earns attention
# it doesn't deserve, so it gets muted gold instead of the picker's bright
# yellow. WAIT and DONE keep full brightness; those are the ones that want
# you.
#
# READ and the aged-out DONE get no colour at all, just dimness — colour is
# how this bar says "look here", and a pane you've already looked at has no
# claim on that. They keep distinct glyphs (✓ seen / ✔ unread-but-old) so
# the two are still tellable apart up close.
DIM = "#585858"
BADGE_STYLES = [
    ("wait",  "⏸︎", "#[fg=#ff5f5f,bold]"),
    ("done",  "✔︎", "#[fg=#5fff00,bold]"),
    ("run",   "▶︎", "#[fg=#af8700]"),
    ("read",  "✓︎", f"#[fg={DIM}]"),
    ("stale", "✔︎", f"#[fg={DIM}]"),
]

# States that make no claim on you. A window with nothing but these fades
# out entirely — name included (see render_badge).
QUIET_STATES = {"read", "stale"}


def badge_state(entry, now):
    """Which of the five badge states a status entry is in — the same
    branch order list-rows.sh uses to pick a row's label."""
    status = entry.get("status", "running")
    if status == "blocked":
        return "wait"
    if status in ("done", "input"):
        if entry.get("read"):
            return "read"
        return "stale" if now - entry.get("updated_at", now) >= IDLE_STALE else "done"
    return "run"


def run_spinner(pane):
    """A RUN icon that *moves*: Claude Code writes a spinner character at
    the head of its terminal title while it works, so instead of a static
    ▶ we borrow that pane's own live glyph. It animates for free — the
    title changes at Claude's spinner rate, each change redraws the status
    line — and it costs no timer and no process of ours.

    This is a tmux format, not a finished string, so the window list has to
    read the option through #{E:...} (expand twice) for it to run.

    `#{s|^.||:pane_id}` drops the leading `%` before comparing: a literal
    `%23` in a format is eaten by the strftime pass (it arrives at the
    comparison as `23`) and would never match `#{pane_id}`'s `%23`.

    The inner test is the fallback: if the pane's title doesn't start with
    a non-ASCII character then Claude isn't drawing a spinner there (no
    title support, a plain shell title) and we show the static ▶ instead,
    so this degrades on its own rather than printing a stray letter."""
    num = pane.lstrip("%")
    return ("#{P:#{?#{==:#{s|^.||:pane_id}," + num + "},"
            "#{?#{m:[ -~],#{=1:pane_title}},▶︎,#{=1:pane_title}},}}")


def render_badge(counts, run_panes=()):
    """One window's badge: every state present, worst first, each with its
    count when a window holds more than one pane in that state (agent teams
    put four Claudes in one window). Empty when nothing is tracked.

    The lone-running case — one window, one busy Claude, by far the common
    one — gets the live spinner; several at once stay a static ▶ with a
    count, because four spinners in a window list is a light show, not
    information."""
    parts = []
    for state, icon, style in BADGE_STYLES:
        n = counts.get(state, 0)
        if not n:
            continue
        if state == "run" and n == 1 and len(run_panes) == 1:
            icon = run_spinner(run_panes[0])
        if state in QUIET_STATES:
            # Dim everywhere except the window you're in — that entry is a
            # bright highlight bar, and #585858 on it is unreadable. Empty
            # branch = inherit the entry's own style.
            style = "#{?window_active,,%s}" % style
        parts.append(f"{style}{icon}{n if n > 1 else ''}#[default]")
    if not parts:
        return ""
    # Nothing in this window wants anything from you, so the whole entry
    # fades — the badge ends on the dim colour instead of #[default] and
    # the window name after it inherits it. Safe to leave hanging: tmux
    # re-applies window-status-style at the start of every window entry, so
    # the dimming stops at this window's edge.
    # ...except for the window you're actually in: the current-window entry
    # is a bright highlight bar, and dim grey on it is unreadable. #{E:}
    # expansion is what makes this test possible at render time.
    if set(counts) <= QUIET_STATES:
        return (" " + "".join(parts)
                + "#{?window_active,#[default],#[fg=%s]}" % DIM)
    return " " + "".join(parts)


def watched_panes():
    """Panes a human is looking at *right now*: the active pane of every
    attached client whose terminal actually has the OS focus.

    tmux reports that focus in `client_flags` (needs `focus-events on`,
    which is the default in most configs). Without it the set comes back
    empty and nothing is auto-read — the old picker-only behaviour."""
    try:
        out = subprocess.check_output(
            ["tmux", "list-clients", "-F", "#{client_flags}\t#{pane_id}"],
            stderr=subprocess.DEVNULL, text=True,
        )
    except Exception:
        return set()
    panes = set()
    for line in out.splitlines():
        parts = line.split("\t")
        if len(parts) == 2 and "focused" in parts[0].split(","):
            panes.add(parts[1])
    return panes


def mark_watched_read(data):
    """Reading a pane's output *is* reading it. Until this existed, `read`
    only got set by the picker and `prefix W` — so a pane you simply
    switched to and read stayed a bright unread DONE, which is exactly the
    nagging the inbox model is supposed to remove.

    `blocked` is deliberately excluded: the WAIT alert is dismissed by
    dealing with the prompt, not by having it on screen. Mutates `data` in
    place so the caller's badge render sees the new flags."""
    fresh = [p for p in watched_panes()
             if p in data and not data[p].get("read")
             and data[p].get("status") in ("done", "input")]
    if not fresh:
        return

    def apply(stored):
        for p in fresh:
            if p in stored:
                stored[p]["read"] = True

    with_status_file(apply)
    for p in fresh:
        data[p]["read"] = True


def sync_window_badges():
    """Recompute every window's badge from the status file and write the
    ones that changed. Called after each mutation (instant feedback) and
    from status-badge.sh's render (self-healing: aging, panes that died
    without SessionEnd, options left behind by an older build)."""
    try:
        panes = subprocess.check_output(
            ["tmux", "list-panes", "-a", "-F", "#{pane_id}\t#{window_id}"],
            stderr=subprocess.DEVNULL, text=True,
        )
        windows = subprocess.check_output(
            ["tmux", "list-windows", "-a", "-F", "#{window_id}\t#{%s}" % WINDOW_OPTION],
            stderr=subprocess.DEVNULL, text=True,
        )
    except Exception:
        return  # no reachable tmux server — nothing to draw on

    win_of = {}
    for line in panes.splitlines():
        p = line.split("\t")
        if len(p) == 2:
            win_of[p[0]] = p[1]

    try:
        with open(STATUS_FILE) as f:
            data = json.load(f)
    except Exception:
        data = {}

    # Pane ids only mean something relative to one tmux server. If the file
    # is non-empty yet overlaps this server by nothing, we're looking at the
    # wrong server (or a restart renumbered everything) — same ambiguity
    # prune() refuses to act on, so leave the badges alone rather than
    # clearing them all.
    if data and not any(pane in win_of for pane in data):
        return

    mark_watched_read(data)

    now = time.time()
    counts = {}
    run_panes = {}
    for pane, entry in data.items():
        win = win_of.get(pane)
        if win is None or entry.get("archived"):
            continue
        state = badge_state(entry, now)
        counts.setdefault(win, {})
        counts[win][state] = counts[win].get(state, 0) + 1
        if state == "run":
            run_panes.setdefault(win, []).append(pane)

    cmd = []
    for line in windows.splitlines():
        parts = line.split("\t", 1)
        win = parts[0]
        current = parts[1] if len(parts) == 2 else ""
        wanted = render_badge(counts.get(win, {}), run_panes.get(win, ()))
        if wanted == current:
            continue                      # no redraw for an unchanged bar
        if cmd:
            cmd.append(";")
        if wanted:
            cmd += ["set-option", "-w", "-t", win, WINDOW_OPTION, wanted]
        else:
            cmd += ["set-option", "-wqu", "-t", win, WINDOW_OPTION]

    if cmd:
        subprocess.run(["tmux"] + cmd, check=False,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


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
    # prune runs from status-badge.sh on every status render, which makes
    # this the badges' heartbeat: it retires panes that died without
    # SessionEnd and ages unread DONEs into their dim form.
    sync_window_badges()


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
    elif mode == "mark-seen" and len(sys.argv) == 3:
        mark_seen(sys.argv[2])
    elif mode == "mark-archived" and len(sys.argv) == 3:
        mark_archived(sys.argv[2])
    elif mode == "clear":
        clear_pane()
    elif mode == "prune":
        prune()
    elif mode == "sync-windows":
        sync_window_badges()


if __name__ == "__main__":
    main()
