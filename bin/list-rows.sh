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

# Optional external item provider (see DESIGN.md, "External item provider").
# $CLAUDE_TMUX_EXTRA_CMD names an executable that contributes extra rows
# above the session list — a to-do queue, review requests, failing builds,
# whatever you point it at. This script knows nothing about what those rows
# mean: to it they are a line of text plus an opaque id, which it hands back
# when asking for a preview or running the Enter action.
#
# Three properties this block has to guarantee:
#   1. Unconfigured is untouched. No variable, missing file, not executable,
#      non-zero exit, timeout, or empty output all mean "no provider", and
#      the output below is then byte-for-byte what it always was.
#   2. It cannot hang the picker. This runs on the startup path, so the
#      provider gets a hard deadline and is dropped if it overruns.
#   3. It cannot corrupt the list. Provider output is filtered down to the
#      two row shapes the cursor logic understands, so a buggy provider
#      degrades to "fewer extra rows" rather than breaking navigation for
#      the real panes.
run_with_deadline() {  # $1 = seconds, rest = command
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then gtimeout "$secs" "$@"
  elif command -v perl >/dev/null 2>&1; then
    perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
  else "$@"
  fi
}

if [ -n "${CLAUDE_TMUX_EXTRA_CMD:-}" ] && [ -x "${CLAUDE_TMUX_EXTRA_CMD}" ]; then
  # Accepted shapes, and nothing else:
  #   item   >=6 fields, field 5 == "extra", field 6 a non-empty id
  #   label  <=4 fields, empty pane id and empty row number — a section
  #          title; the cursor treats it exactly like a session header
  extra="$(run_with_deadline "${CLAUDE_TMUX_EXTRA_TIMEOUT:-2}" \
             "$CLAUDE_TMUX_EXTRA_CMD" list 2>/dev/null \
           | awk -F'\t' '(NF>=6 && $5=="extra" && $6!="") || (NF<=4 && $2=="" && $4=="")' \
           || true)"
  [ -n "$extra" ] && printf '%s\n' "$extra"
fi

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
#
# Field 5 says what a row is when it isn't an ordinary pane: "extra" for an
# external provider item (above), "mate" for a team member's pane (below),
# which is a pane row the cursor deliberately doesn't stop on. $BIN_DIR is
# passed so the team reader sitting next to this script can be imported —
# but only when there is a team to read.
python3 - "$STATUS_FILE" "$BIN_DIR" <<'PYEOF'
import getpass, json, os, socket, sys, subprocess, time, unicodedata
from collections import defaultdict

status_file = sys.argv[1]
bin_dir = sys.argv[2] if len(sys.argv) > 2 else ""
with open(status_file) as f:
    data = json.load(f)

# Agent Teams support, and the gate that keeps it free for everyone else.
# The check is inlined instead of calling agent_teams.available(), because
# importing the module to ask whether the module is wanted would cost the
# very file read this is avoiding. For anyone who has never switched Agent
# Teams on, the whole feature is one stat: no import, no extra process, and
# every row below comes out byte-for-byte as it always did.
_claude_home = os.environ.get("CLAUDE_HOME") or os.path.expanduser("~/.claude")
teams_snap = None
if bin_dir and os.path.isdir(os.path.join(_claude_home, "teams")):
    try:
        sys.path.insert(0, bin_dir)
        import agent_teams
        teams_snap = agent_teams.snapshot()
    except Exception:
        teams_snap = None      # a broken read means "no teams", never a broken list
if teams_snap is not None and not teams_snap["teams"]:
    teams_snap = None          # the directory exists but holds nothing readable
members_by_pane = teams_snap["by_pane"] if teams_snap else {}

fmt = ("#{pane_id}\t#{session_name}\t#{window_index}\t#{window_name}"
       "\t#{pane_index}\t#{pane_current_path}\t#{pane_title}")
try:
    out = subprocess.check_output(["tmux", "list-panes", "-a", "-F", fmt], text=True)
except Exception:
    out = ""

live = {}
for line in out.splitlines():
    parts = line.split("\t")
    if len(parts) == 7:
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
    window title, so names are occasionally sentence-length ("api-server✳
    Refactor auth middleware for token rotation"), and one of those used
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


def _default_titles():
    """The values tmux and the shell put in a pane title when nothing else
    has. Computed at runtime, never written down: the whole point is to
    keep a machine's user and host names out of this repo *and* out of the
    list it prints."""
    out = set()
    try:
        host = socket.gethostname()
        out.add(host)
        out.add(host.split(".")[0])
    except Exception:
        pass
    try:
        out.add(getpass.getuser())
    except Exception:
        pass
    return out


_DEFAULT_TITLES = _default_titles()


def safe_title(title):
    """A pane title, or "" if it's really the shell's default.

    An unset `pane_title` falls back to the host name, and most shells
    keep it set to `user@host: cwd`. Neither says anything about what the
    pane is doing, and both put the operator's identity into a list that
    gets screenshotted — this repo ships one in its own README.

    Why the guard lives here and not in the pruner: prune() already drops
    panes whose command is a shell, so in normal operation none of these
    titles can reach a row. That invariant belongs to a different file and
    protects against a different thing (dead entries), and it was never
    written to hold this. The costs are also lopsided — a title falling
    through to the window name is invisible, a name and hostname appearing
    in a shared screenshot is not — so this does not lean on somebody
    else's guarantee. **Do not delete this on the grounds that prune covers
    it.**"""
    t = (title or "").strip()
    if not t or t in _DEFAULT_TITLES:
        return ""
    user = getpass.getuser() if _DEFAULT_TITLES else ""
    if user and t.startswith(user + "@"):
        return ""
    return t


def display_name(pane, rec, window_name, pane_title, member):
    """What to call this pane in the name column, best source first.

    Five levels. Each one falls through for a *different* reason, which is
    what makes this a chain rather than a couple of branches:

      1. a hand-picked session name — the only source where somebody stated
         outright what this session is called, so it outranks everything
         automatic. **Today this is always empty:** the status file has no
         such field yet, so the lookup misses and level 2 answers. The slot
         is here so that if the name ever starts being recorded, nothing in
         this function has to change. It is not dead code — it is the
         reason the rest of the chain won't need rewriting.
      2. the team roster's name — the only source that says *who* a pane
         is. Falls through when the pane isn't on a team, or is a lead
         (whose roster entry holds a placeholder where a pane id would go).
      3. pane_title — per-pane and clean. Falls through when empty, or when
         it's really the shell's default (see safe_title).
      4. window_name — the old source. Several Claude panes sharing one
         tmux window all write to it, so it arrives as their titles
         concatenated in an order none of them agree on.
      5. the session id, shortened — falls through to the pane id.

    Levels 1 and 2 can in principle both answer; a hand-picked name wins
    because it is chosen later than the roster name, which is fixed when a
    teammate is spawned. In practice they barely overlap: teammates don't
    get renamed by hand.

    Level 2 subsumes "is this pane on a team": a roster hit *is*
    membership, so nothing tests for it separately. The lead needs no
    special case either — it falls to level 3, and its pane_title is the
    session summary, which is exactly what its row should say. A branch for
    the lead would replace a right answer with a bespoke one.

    Level 5's only job is to guarantee this function has no path that
    returns an empty string; a row with an ugly name is recoverable, a row
    with no name is not. It prefers the session id because that survives
    what a pane id doesn't — a tmux server restart renumbers every pane,
    while the session id is the same value before and after. The trailing
    `or pane` is there because the session id is a recorded *value* and can
    be missing, whereas the pane id is the key the record is filed under
    and structurally cannot be."""
    manual = (rec.get("session_name") or "").strip()
    if manual:
        return manual
    if member and member.get("name"):
        return member["name"]
    return (
        safe_title(pane_title)
        or (window_name or "").strip()
        or (rec.get("session_id") or "")[:8]
        or pane
    )


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
# Which teams have a pane in which session. Derived from the panes rather
# than asked of the roster, because the roster records no session: the only
# thing tying a team to a place in this list is a member's pane id, so a
# team is "in" whichever session its members turned up in.
teams_in_session = defaultdict(set)
for pane, e in data.items():
    if pane not in live or e.get("archived"):
        continue
    _, session, win_idx, window_name, pane_idx, cwd, pane_title = live[pane]
    member = members_by_pane.get(pane)
    if member:
        teams_in_session[session].add(member["team"])
    wname = display_name(pane, e, window_name, pane_title, member)
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
    by_session[session].append((seq, rank, pane, label, age, wname, cwd, member))

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

# `f` in the picker: show only the teams and the panes belonging to them.
# Same shape as `a` — a per-instance file, because every keypress is its own
# process — and the same rule about numbering: rows are numbered before the
# filter, so a pane keeps the digit you learned whether or not `f` is on.
team_only = False
team_only_file = os.environ.get("CLAUDE_TMUX_TEAM_ONLY_FILE")
if team_only_file and teams_snap:
    try:
        with open(team_only_file) as f:
            team_only = f.read().strip() == "1"
    except OSError:
        pass

# How much further right a teammate's row starts than everything else, so
# it reads as belonging to the lead above it rather than standing beside
# it. Taken back out of the name column rather than added to the row, so
# the indent moves the left edge only: the age column and the free-form
# tail stay at the same x as every other row. Widening the row instead
# would make those columns ragged wherever a team happens to be.
#
# Spaces, not a box-drawing or arrow glyph: everything in that range is
# East-Asian Ambiguous and renders double-width on a CJK-configured
# terminal, which would push the whole row out of line.
#
# Two cells while a word-shaped role tag was also on the row; four now that
# it isn't. The five cells the tag used to hold are freed, so paying four of
# them back into the indent still leaves a member's name column *wider* than
# it was, and moves the one part of the row that sits at a fixed x on every
# other line — the status label — twice as far as before.
MATE_INDENT = 4


def name_colour(member):
    """The SGR wrapper for a member's name, or a plain string.

    A teammate's row used to open with a four-cell word ("队员") saying it
    was one. That word cost every member row five cells of the only column
    that ever runs out of them, to repeat on each row of a team what the
    row's position under its lead, its empty number gutter and its session
    header already said once. It is replaced by the colour the official
    roster hands each teammate at spawn — the one per-member identity that
    costs no columns, and one that says *which* teammate rather than just
    "a teammate".

    Colour cannot be the only thing carrying that, and here it isn't. Four
    other signals survive the word, three of them absolute rather than a
    comparison against a neighbouring row:

      - **no number in the gutter.** Every other pane row shows one; a
        teammate's is blank. Visible with no colour at all.
      - **`j`/`k` walks straight past it**, which no other pane row does.
      - **the pane preview names the team and the member in words**
        (`session-digest.py --pane`).
      - the indent, which is the relative one: it needs a non-teammate row
        nearby to read against, and under `f` there may not be one.

    An unrecognised colour degrades to no colour, which loses the fourth
    signal and keeps the other three."""
    sgr = member.get("sgr") or ""
    return (f"\033[{sgr}m", "\033[0m") if sgr else ("", "")


def member_tail(member, counts):
    """What a member's row says in the trailing free-form field, which is
    the one place in this list nothing has to line up — so it's the only
    place variable-length text can go.

    For a member that's the task they're on; `activeForm` is already
    present-tense, so it reads as a status rather than a title. For the
    lead it's the team's own backlog, since the lead's "task" is the team.
    A queued-message count leads either one when there is one: a backlog is
    an exception worth interrupting the sentence for, which is also exactly
    why it doesn't get a column of its own — a field that's empty 95% of
    the time costs every row its width to report an occasional event.

    Nothing to say means the cwd, the same as any other row. An empty slot
    would be louder than the fallback."""
    bits = []
    if member.get("inbox"):
        bits.append(f"✉{member['inbox']}")
    if member.get("is_lead"):
        if counts.get("in_progress"):
            bits.append(f"{counts['in_progress']} 人在做")
        for key, word in (("pending", "待领"), ("blocked", "挡住")):
            if counts.get(key):
                bits.append(f"{word} {counts[key]}")
    elif member.get("doing"):
        num = f"#{member['doing_id']} " if member.get("doing_id") else ""
        bits.append(num + member["doing"])
    return " · ".join(bits)


# A team is summarised on the header of the session it is running in, not
# in a block of its own.
#
# The block used to sit above the list, and it drew the same thing twice: a
# team is spawned by splitting the window its lead is already in, so the
# team and that session are one object, and there is no arrangement in
# which they are two rows worth looking at. Worse, the block wasn't a
# destination — it occupied a row that couldn't take you anywhere, while
# the session header directly below it could. Folding it in costs nothing
# and removes an entire row kind, along with the cursor, Enter and preview
# special cases that kind needed.
#
# What the block's second line used to say — the members with no pane of
# their own — moves into the preview, which is the one surface with room
# to name them. It must not simply vanish: it's the part of a team this
# list structurally cannot show.
counts_of = {t["team"]: t["counts"] for t in (teams_snap["teams"] if teams_snap else ())}
team_by_name = {t["team"]: t for t in (teams_snap["teams"] if teams_snap else ())}


def team_summary(team):
    """The team's own counts, for the tail of its session's header.

    Only the numbers that are about the *team* rather than the panes: the
    session's own status counts are already there and say how the panes
    are doing. Zero counts are dropped, the same as those."""
    t = team_by_name.get(team)
    if not t:
        return ""
    c = t["counts"]
    n_mate = sum(1 for m in t["members"] if not m["is_lead"])
    bits = []
    if n_mate:
        bits.append(f"{agent_teams.MEMBER_LABEL} {n_mate}")
    for key, word in (("in_progress", "在做"), ("pending", "待领"),
                      ("blocked", "挡住")):
        if c.get(key):
            bits.append(f"{word} {c[key]}")
    inbox_total = sum(m["inbox"] for m in t["members"])
    if inbox_total:
        bits.append(f"信箱 {inbox_total}")
    if not bits:
        return ""
    return "  \033[36m编队\033[0m \033[2m" + " · ".join(bits) + "\033[0m"

row_num = 0  # global 1-based pane-row counter (the digit-jump number)
for s in sessions_sorted:
    entries = sorted(by_session[s], key=lambda x: x[0])   # by tmux window.pane
    # Under `f`, a session with nobody from a team in it disappears whole —
    # header included. Its panes still consume their numbers on the way
    # past, so nothing renumbers when the filter goes on or off.
    if team_only and not any(e[7] for e in entries):
        row_num += len(entries)
        continue
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
    # `f` never collapses: you asked to see the team, and a quiet member is
    # still a member. Collapsing there would hide the very rows the filter
    # was turned on to find.
    collapse = (not show_all) and (not team_only) and len(hideable) >= MIN_COLLAPSE
    hidden_ids = {e[2] for e in hideable} if collapse else set()
    # The session keeps its own identity — `▾ $7 7` — with the team's
    # numbers appended. Replacing the name with the team's would cost the
    # coordinate people actually navigate by; a team is something this
    # session *has*, not something it stops being.
    header = (
        "\033[1;36m" + pad(f"▾ {sid_label}{s}", 22) + "\033[0m" + counts
        + "".join(team_summary(t) for t in sorted(teams_in_session.get(s, ())))
    )
    print(f"{header}\t\t{s}")

    # Pane rows are indented deeper than headers on purpose: with the
    # left/right mode toggle either row type can hold the cursor, and the
    # horizontal offset is what makes "am I picking a session or a pane"
    # legible at a glance. Window name leads the row — "what is this one
    # doing" is the first thing you scan for — with the status right
    # after it.
    for _seq, rank, pane, label, age, wname, cwd, member in entries:
        # Teammates are the one kind of pane that gets no number.
        #
        # This looks like an exception to "number everything" but it is the
        # rule holding: a number must not change because something else
        # appeared or went away. Teammates are the most short-lived things
        # in this list — a lead spawns three, they finish, they're gone —
        # and every one of them that took a number would push the number of
        # every session below it. Spending the stable numbering of long-
        # lived sessions on rows that live for minutes is the wrong trade.
        #
        # They stay reachable: they are still pane rows, so j/k and Enter
        # work on them, and they sit together under their lead. Only the
        # digit shortcut is gone, and the lead — which is a real session
        # you'd want to jump to — keeps its number.
        is_mate = bool(member) and not member.get("is_lead")
        # Numbered BEFORE the visibility test, on purpose: a pane's number
        # must not change when you collapse or expand the list, or the number
        # you learned is a lie the moment you press `a`. The cost is that
        # visible numbers go sparse (1, 4, 7, 12…), which is why
        # skip-header.sh matches the digits you type against the number in
        # field 4 rather than counting pane rows.
        if not is_mate:
            row_num += 1
        if pane in hidden_ids:
            continue
        if team_only and not member:
            continue
        # The name column. For a member the name *is* the marker, so it is
        # printed in that member's own colour and at full width — no prefix
        # eating the front of the column, and nothing added to the row, so a
        # member row and an ordinary row still put their names at the same x.
        #
        # It is no longer dimmed either. Dimming was right while a coloured
        # role tag sat in front of it and was the part worth scanning for;
        # with the tag gone the name is that part, and receding is the one
        # thing it must not do.
        if member:
            on, off = name_colour(member)
            width = NAME_W - (MATE_INDENT if is_mate else 0)
            name_cell = on + col(wname, width) + off
            trailing = member_tail(member, counts_of.get(member["team"], {}))
        else:
            name_cell = col(wname, NAME_W)
            trailing = ""
        # Dim number gutter — the digits you press to jump straight here.
        # Three wide, not two: with 100 panes a 2-wide field silently drops
        # the leading digit *and* shifts every column on that row.
        #
        # A teammate gets blanks instead, and MATE_INDENT more of them —
        # the gutter is where the indent is spent. Empty space costs
        # nothing and reads as "indented" just as well as any glyph, none
        # of which are safe at this width (see MATE_INDENT).
        num = (" " * (7 + MATE_INDENT) if is_mate
               else f"  \033[2m{row_num:>3}\033[0m  ")
        if rank == 4:
            # Aged-out unread DONE: build the row from plain text and dim
            # the whole thing in one wrap (no embedded colour codes that
            # would reset the dim early), so it recedes but stays
            # selectable. "✔ DONE  " matches the icon+label width above.
            # A member's name colour is dropped here rather than dimmed
            # alongside the rest: this row's point is to recede, and the
            # signals that survive it are the ones that cost no ink — the
            # blank gutter and the indent, both still below.
            #
            # The gutter follows the same rule as every other row: a
            # teammate has no number, so it gets blanks, and the same
            # MATE_INDENT step in — again paid for out of the name column
            # so the age stays where it is. Printing row_num here
            # regardless would print the number of the row *above* — it was
            # never incremented for this one — and two rows claiming the
            # same digit is worse than none.
            body = ("✔︎ DONE  "
                    + col(wname, NAME_W - (MATE_INDENT if is_mate else 0))
                    + col(fmt_age(1, age), AGE_W) + (trailing or tilde(cwd)))
            display = (f"  \033[2m{'' if is_mate else row_num:>3}  "
                       + (" " * MATE_INDENT if is_mate else "")
                       + body + "\033[0m")
        else:
            display = (
                num
                + label
                + "  "
                + name_cell
                + col(fmt_age(rank, age), AGE_W)
                + "\033[2m" + (trailing or tilde(cwd)) + "\033[0m"
            )
        # Field 4 is what skip-header.sh matches typed digits against, so a
        # teammate leaves it empty: no number in the gutter, no number to
        # resolve.
        #
        # Field 5 "mate" takes it out of the cursor's path as well. It
        # still carries its pane id in field 2 — the preview needs it, and
        # a search hit can still act on it — so the marker, not the absence
        # of a pane id, is what says "not a stop". A teammate row and its
        # lead were competing for the same j/k step, and the lead is the
        # one you want: the teammates are inside its window, one native
        # tmux pane-switch away, so stopping on each of them in turn made
        # you walk past the destination to reach rows that only repeat what
        # the lead's row already told you.
        #
        # Under `f` the marker is deliberately not emitted. That mode
        # exists to look at teammates, so there they are the destinations
        # and the cursor must stop on them. Encoding it here rather than
        # teaching skip-header.sh about the filter keeps one rule — field 5
        # says what a row is — instead of two that have to agree.
        # Appended only when it has a value, never as an empty trailing
        # field: an ordinary pane row has to keep emitting exactly four
        # fields, or every row in the list gains a tab and the "nothing
        # changes for people without teams" guarantee dies on a character
        # nobody can see.
        suffix = "\tmate" if (is_mate and not team_only) else ""
        print(f"{display}\t{pane}\t{s}\t{'' if is_mate else row_num}{suffix}")

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
