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

# Fields (tab-separated): display, pane_id, session_name, row_number
# `display` is fully pre-formatted/padded/colored below (CJK-width aware)
# and is the only field fzf shows (--with-nth=1). Header rows (one per
# session) have an empty pane_id field; pane rows carry their tmux pane
# id. Both carry the session name, so Enter on a header (session-select
# mode) knows where to jump and the preview can show the session's active
# pane. `row_number` repeats the gutter number as plain text so
# skip-header.sh can resolve a typed number without parsing ANSI back out
# of `display` — it matters because collapsing makes the numbers sparse.
# Archived panes are omitted entirely.
python3 - "$STATUS_FILE" <<'PYEOF'
import json, os, sys, subprocess, time, unicodedata
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
    """Pad to `width`, but always leave at least one trailing space: every
    use here is a column separator, and content that happens to fill the
    width exactly (`完成 16.9小时前` is exactly 15 cols, a 12-wide CJK
    window name exactly 24) would otherwise butt straight up against the
    next column with no gap."""
    w = vwidth(s)
    return s + " " * max(1, width - w)


def clip(s, width):
    """Truncate to `width` visual columns, marking the cut with `..`.

    pad() only ever pads, which was fine until a window name arrived longer
    than its column: Claude Code writes the *current task* into the tmux
    window title, so names are occasionally sentence-length ("workOS✳
    Configure desk assistant for decision logging"), and one of those used
    to shove the time and path columns off the right edge — breaking the
    alignment of that whole row while every other row stayed neat.

    Cut from the tail: a name's first few words are what identify it. ASCII
    `..` rather than `…`, whose East Asian width is Ambiguous and so renders
    double in a CJK-configured terminal — precisely the misalignment being
    fixed here."""
    if vwidth(s) <= width:
        return s
    out, w, keep = "", 0, width - 2
    for ch in s:
        cw = 2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1
        if w + cw > keep:
            break
        out += ch
        w += cw
    return out + ".."


def col(s, width):
    """One aligned column, `width` cells wide, guaranteed.

    Clipping to width-1 is what makes the guarantee hold: pad() always
    leaves a trailing separator space, so content that exactly fills the
    field would come out one cell too wide and shove every column to its
    right — which is how both of this list's alignment bugs happened (a
    sentence-long window name, and `完成 27.4小时前`, which is exactly 15
    cells). Both classes vanish if content can never reach the field width.

    NAME_W/AGE_W are sized so the clip is a backstop rather than an everyday
    event: real window names fit, and an age only reaches 16 cells once a
    pane has been idle for 100+ hours."""
    return pad(clip(s, width - 1), width)


NAME_W = 24   # window name
AGE_W = 17    # "完成 999.9小时前" is 16 cells; 17 keeps the separator


def tilde(path):
    """`/Users/you/repos/api` → `~/repos/api`. Every path in this list is
    under $HOME in practice, so spelling the home prefix out on every row
    costs ~10 columns of the one field that actually needs them — and with
    the preview taking its share, columns are the scarce resource here."""
    home = os.path.expanduser("~")
    if path == home:
        return "~"
    if path.startswith(home + "/"):
        return "~" + path[len(home):]
    return path


def fmt_age(rank, secs):
    """Say what the elapsed time *means* for this status, in human units —
    a bare '1098s前' answers neither question. updated_at is the moment
    the status last changed, so per status it reads naturally as:
    RUN = since the prompt was submitted (how long it's been running),
    WAIT = since the permission prompt appeared, DONE = since it
    finished (both the unread DONE and the already-seen READ)."""
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
    if rank == 1:
        return f"完成 {d}前"
    return f"{d}前"  # READ — since it last finished something


# An unread DONE left untouched this long has clearly been abandoned —
# Claude finished ages ago and you never came back. It stays listed (still
# reachable) but dimmed and sunk to the bottom (rank 4), and drops out of
# the ambient status bar entirely. Overridable via env.
IDLE_STALE = int(os.environ.get("CLAUDE_TMUX_IDLE_STALE_SECS", "7200"))  # 2h

# Four states, each with a distinct leading icon so it reads by shape, not
# just colour: WAIT ⏸ (blocked — needs your choice, top priority), RUN ▶
# (Claude busy), DONE ✔ (finished, unread — a result to look at), READ ✓
# (finished, already seen — quiet). "done" (Stop hook) and "input" (idle,
# waiting on your next message) both just mean "Claude finished, waiting on
# you", so they collapse into the single DONE/READ pair. ︎ forces the
# text (narrow, monochrome) presentation of the two media glyphs so they
# stay single-width in the aligned list and take our colour.
now = time.time()
by_session = defaultdict(list)
for pane, e in data.items():
    if pane not in live or e.get("archived"):
        continue
    _, session, win_idx, window_name, pane_idx, cwd = live[pane]
    age = int(now - e.get("updated_at", now))
    status = e.get("status", "running")
    if status == "blocked":
        label, rank = "\033[1;31m⏸︎ WAIT\033[0m", -1   # permission choice — top priority, notified
    elif status in ("done", "input") and e.get("read"):
        label, rank = "\033[34m✓︎ READ\033[0m", 3          # already visited once — quiet until it stirs again
    elif status in ("done", "input") and age >= IDLE_STALE:
        label, rank = None, 4                                    # aged-out unread DONE — dimmed (built in render)
    elif status in ("done", "input"):
        label, rank = "\033[1;32m✔︎ DONE\033[0m", 1         # finished, not seen yet
    else:
        label, rank = "\033[33m▶︎ RUN \033[0m", 2
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

# Collapsing the quiet ones. With a dozen panes the list fits; with 24 it
# doesn't, and the ones you scroll past are always the same two kinds: READ
# (rank 3 — you've already looked) and aged-out unread DONE (rank 4 — you
# haven't looked in hours, so it isn't urgent). Those collapse by default;
# WAIT/RUN/unread-DONE are never hidden, because those are the whole point.
# `a` in the picker toggles (via SHOW_ALL_FILE, written per picker instance
# the same way MODE_FILE is); CLAUDE_TMUX_SHOW_ALL=1 restores the old
# always-everything behaviour as the default.
HIDDEN_RANKS = (3, 4)
MIN_COLLAPSE = 2   # see `collapse` below — hiding one row saves zero rows
# The pane you're standing in is never collapsed, even when it's a quiet one
# (it usually is — visiting a pane is what marks it READ). Opening the picker
# and not finding yourself in the list is disorienting, and it's also where
# the cursor wants to start.
caller = os.environ.get("CALLER_PANE", "")
show_all = os.environ.get("CLAUDE_TMUX_SHOW_ALL") == "1"
show_all_file = os.environ.get("CLAUDE_TMUX_SHOW_ALL_FILE")
if show_all_file:
    try:
        with open(show_all_file) as f:
            show_all = f.read().strip() == "1"
    except OSError:
        pass

row_num = 0  # global 1-based pane-row counter (the digit-jump number)
for s in sessions_sorted:
    entries = sorted(by_session[s], key=lambda x: x[0])   # by tmux window.pane
    blocked = sum(1 for _seq, rank, *_ in entries if rank == -1)
    d_unread = sum(1 for _seq, rank, *_ in entries if rank == 1)
    r = sum(1 for _seq, rank, *_ in entries if rank == 2)
    d_read = sum(1 for _seq, rank, *_ in entries if rank == 3)
    stale = sum(1 for _seq, rank, *_ in entries if rank == 4)
    sid = session_order.get(s)
    sid_label = f"${sid} " if sid is not None else ""
    # Bold cyan headers vs plain, deeper-indented pane rows: the two row
    # kinds have to read apart instantly, since either can hold the
    # cursor depending on the left/right mode.
    # Counts carry the same icon+colour as the row labels below, so the
    # header summarises the session in the very glyphs you'll then scan for
    # (⏸ WAIT, ✔ DONE-unread, ▶ RUN, ✓ READ, dim ✔ = aged-out DONE) —
    # ordered most-important-first, and zero counts are simply omitted
    # instead of parading a row of 0s.
    counts = "  ".join(
        f"\033[{colour}m{icon} {n}\033[0m"
        for icon, colour, n in (
            ("⏸︎", "1;31", blocked), ("✔︎", "1;32", d_unread),
            ("▶︎", "33", r), ("✓︎", "34", d_read), ("✔︎", "2", stale),
        )
        if n
    )
    # Which of this session's panes collapsing would actually remove. The
    # caller's own pane never counts — it's never hidden.
    hideable = [e for e in entries if e[1] in HIDDEN_RANKS and e[2] != caller]
    # Collapsing one row costs one row: the "⋯ 收起 N 个" line replaces it
    # exactly, so hiding a single pane saves nothing and only makes you press
    # `a` to see something that was already on screen. Two is where it starts
    # paying.
    collapse = (not show_all) and len(hideable) >= MIN_COLLAPSE
    hidden_ids = {e[2] for e in hideable} if collapse else set()
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
        # Numbered BEFORE the visibility test, on purpose: a pane's number
        # must not change when you collapse or expand the list, or the number
        # you learned is a lie the moment you press `a`. The cost is that
        # visible numbers go sparse (1, 4, 7, 12…), which is why
        # skip-header.sh matches the digits you type against the number in
        # field 4 rather than counting pane rows.
        row_num += 1
        if pane in hidden_ids:
            continue
        # Dim number gutter — the digits you press to jump straight here.
        # Three wide, not two: with 100 panes a 2-wide field silently drops
        # the leading digit *and* shifts every column on that row.
        num = f"  \033[2m{row_num:>3}\033[0m  "
        if rank == 4:
            # Aged-out unread DONE: build the row from plain text and dim
            # the whole thing in one wrap (no embedded colour codes that
            # would reset the dim early), so it recedes but stays
            # selectable. "✔ DONE  " matches the icon+label width above.
            body = ("✔︎ DONE  " + col(wname, NAME_W)
                    + col(fmt_age(1, age), AGE_W) + tilde(cwd))
            display = f"  \033[2m{row_num:>3}  " + body + "\033[0m"
        else:
            display = (
                num
                + label
                + "  "
                + col(wname, NAME_W)
                + col(fmt_age(rank, age), AGE_W)
                + "\033[2m" + tilde(cwd) + "\033[0m"
            )
        print(f"{display}\t{pane}\t{s}\t{row_num}")

    if collapse:
        # Its own line, so the number is readable rather than implied by two
        # icon counts in the header. Empty pane field + `-` in the row-number
        # field marks it: skip-header.sh stops the cursor on neither kind of
        # row, and everything that keys off an empty pane id (the preview's
        # session card, Enter jumping to the session) already does the right
        # thing for it.
        kinds = []
        n_read = sum(1 for e in hideable if e[1] == 3)
        n_stale = len(hideable) - n_read
        if n_read:
            kinds.append(f"{n_read} 已读")
        if n_stale:
            kinds.append(f"{n_stale} 搁置")
        note = f"⋯ 收起 {len(hideable)} 个({' · '.join(kinds)}) · a 展开"
        print(f"       \033[2m{note}\033[0m\t\t{s}\t-")
PYEOF
