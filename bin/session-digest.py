#!/usr/bin/env python3
"""Session-header preview: one compact card per tracked Claude pane in the
session, instead of raw screen dumps — title (name/status/age), a task
line (the session's first real prompt — what this pane is working on), a
meta line (model, context size, cwd) read from the pane's Claude Code
transcript, and a short recap: the tail of Claude's last text reply.
Cards are separated by a blank line plus a full-width rule.

args: session_name
env:  FZF_PREVIEW_LINES / FZF_PREVIEW_COLUMNS (set by fzf)

The transcript lives at ~/.claude/projects/<cwd with / -> ->/<session_id>.jsonl;
the hooks record session_id per pane exactly so this lookup works.
"""
import getpass
import json
import os
import socket
import subprocess
import sys
import time
import unicodedata

STATUS_FILE = os.path.expanduser("~/.claude/tmux-claude-status.json")
PROJECTS_DIR = os.path.expanduser("~/.claude/projects")

RESET = "\033[0m"
DIM = "\033[2m"
BOLD = "\033[1m"
CYAN = "\033[36m"


def _default_titles():
    """Values tmux and the shell leave in a pane title when nothing else
    set one. Computed at runtime so no machine's user or host name is ever
    written into this repo."""
    out = set()
    try:
        host = socket.gethostname()
        out.update((host, host.split(".")[0]))
    except Exception:
        pass
    try:
        out.add(getpass.getuser())
    except Exception:
        pass
    return out


_DEFAULT_TITLES = _default_titles()


def safe_title(title):
    """A pane title, or "" when it's really the shell's default.

    Deliberately duplicated from list-rows.sh rather than shared: the two
    renderers already keep their own copies of vwidth/clip/fmt_age for the
    same reason, which is that list-rows.sh's copy lives inside a heredoc
    and importing across that boundary would cost a file read on the path
    that must stay free. Keep the two in step.

    Why the guard is here and not in the pruner: prune() drops panes whose
    command is a shell, so these titles shouldn't reach a preview at all.
    That invariant lives in another file, guards a different problem, and
    was never written to hold this one — and the failure it would let
    through is a user and host name rendered into a screenshot. **Not
    redundant. Don't remove it because prune looks like it covers it.**"""
    t = (title or "").strip()
    if not t or t in _DEFAULT_TITLES:
        return ""
    try:
        if t.startswith(getpass.getuser() + "@"):
            return ""
    except Exception:
        pass
    return t


def load_teams():
    """Agent Teams state, or None when there is none.

    Same one-stat gate as list-rows.sh, and for the same reason: a preview
    runs on every cursor stop, so the cost of this feature for someone who
    never turned Agent Teams on has to be a stat and nothing else — no
    import, no extra process."""
    home = os.environ.get("CLAUDE_HOME") or os.path.expanduser("~/.claude")
    if not os.path.isdir(os.path.join(home, "teams")):
        return None
    try:
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        import agent_teams
        snap = agent_teams.snapshot()
    except Exception:
        return None
    return snap if snap["teams"] else None


_MANUAL_NAMES = None


def manual_names():
    """Level 1 of the naming chain: the names people chose themselves.

    Same one-stat gate and lazy import as load_teams(), and memoised for
    the same reason — but note where it is *not* called from. `--pane`
    prints no name, so the pane preview, which runs on every cursor stop
    and has the tightest budget in this file, never reaches this."""
    global _MANUAL_NAMES
    if _MANUAL_NAMES is not None:
        return _MANUAL_NAMES
    _MANUAL_NAMES = {}
    home = os.environ.get("CLAUDE_HOME") or os.path.expanduser("~/.claude")
    if os.path.isdir(os.path.join(home, "sessions")):
        try:
            sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
            import claude_sessions
            _MANUAL_NAMES = claude_sessions.manual_names()
        except Exception:
            _MANUAL_NAMES = {}
    return _MANUAL_NAMES


def display_name(pane, rec, window_name, pane_title, member):
    """The name for a pane, best source first — see list-rows.sh for the
    full reasoning. Kept in step with it so a pane is called the same thing
    in the list and in the preview of that same list."""
    manual = manual_names().get((rec.get("session_id") or "").strip(), "")
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


def vwidth(s):
    w = 0
    for ch in s:
        w += 2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1
    return w


def clip(s, width):
    out, w = "", 0
    for ch in s:
        cw = 2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1
        if w + cw > width:
            return out + "…"
        out += ch
        w += cw
    return out


def wrap(text, width, max_lines):
    """CJK-width-aware wrap; collapses blank runs; appends … if cut off."""
    lines, cur, w = [], "", 0
    prev_blank = False
    for raw in text.replace("\r", "").split("\n"):
        raw = raw.rstrip()
        if not raw.strip():
            prev_blank = True
            continue
        if prev_blank and cur:
            lines.append(cur)
            cur, w = "", 0
        prev_blank = False
        if cur:
            lines.append(cur)
            cur, w = "", 0
        for ch in raw:
            cw = 2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1
            if w + cw > width:
                lines.append(cur)
                cur, w = ch, cw
            else:
                cur += ch
                w += cw
            if len(lines) >= max_lines:
                break
        if len(lines) >= max_lines:
            break
    if cur and len(lines) < max_lines:
        lines.append(cur)
    if len(lines) >= max_lines:
        lines = lines[:max_lines]
        lines[-1] = clip(lines[-1], width - 2) + " …"
    return lines


def first_prompt(path):
    """The session's first real user prompt, collapsed to one line — the
    closest thing to 'what is this pane working on'. Transcripts have no
    auto-summary records, and custom-title just mirrors the tmux window
    name, so the opening ask is the best task label available. Skips
    meta/command wrapper entries (isMeta, <command-name>…, Caveat:…)."""
    try:
        with open(path, "rb") as f:
            head = f.read(300_000).decode("utf-8", "replace")
    except OSError:
        return None
    for line in head.splitlines():
        try:
            obj = json.loads(line)
        except Exception:
            continue
        if obj.get("type") != "user" or obj.get("isMeta"):
            continue
        c = obj.get("message", {}).get("content")
        if isinstance(c, list):
            text = "\n".join(
                b.get("text", "") for b in c
                if isinstance(b, dict) and b.get("type") == "text"
            )
        else:
            text = c or ""
        text = text.strip()
        if not text or text.startswith("<") or text.startswith("Caveat:"):
            continue
        return " ".join(text.split())
    return None


def transcript_info(entry, want_text=True):
    """(model, context_tokens, recap_text, task) from the pane's
    transcript, or all-None if it can't be found/parsed. want_text=False
    is the cheap path for the one-line pane bar: a small tail read, stop
    at the first usage-bearing message, skip recap/first-prompt entirely
    (~10x less I/O — the preview runs on every cursor stop)."""
    sid, cwd = entry.get("session_id"), entry.get("cwd")
    if not sid or not cwd:
        return None, None, None, None
    path = os.path.join(PROJECTS_DIR, cwd.replace("/", "-"), sid + ".jsonl")
    try:
        with open(path, "rb") as f:
            f.seek(0, 2)
            size = f.tell()
            f.seek(max(0, size - (400_000 if want_text else 80_000)))
            lines = f.read().decode("utf-8", "replace").splitlines()
    except OSError:
        return None, None, None, None

    model = ctx = recap = None
    for line in reversed(lines):
        try:
            obj = json.loads(line)
        except Exception:
            continue
        if obj.get("type") != "assistant":
            continue
        m = obj.get("message", {})
        if model is None:
            model = m.get("model")
            u = m.get("usage", {})
            ctx = (
                (u.get("input_tokens") or 0)
                + (u.get("cache_read_input_tokens") or 0)
                + (u.get("cache_creation_input_tokens") or 0)
            ) or None
        if not want_text:
            if model is not None:
                break
            continue
        texts = [c.get("text", "") for c in m.get("content", []) if c.get("type") == "text"]
        if texts and texts[-1].strip():
            recap = texts[-1].strip()
            break
    return model, ctx, recap, first_prompt(path) if want_text else None


def fmt_age(rank, secs):
    """Say what the elapsed time *means* for this status, in human units
    (same logic as list-rows.sh): RUN = how long it's been running since
    the prompt was submitted, WAIT = since the permission prompt appeared,
    IDLE = since it started waiting on input, DONE = since it finished."""
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


def label_of(entry):
    status = entry.get("status", "running")
    if status == "blocked":
        return "\033[1;31mWAIT\033[0m", -1
    if status in ("done", "input") and entry.get("read"):
        return "\033[34mREAD\033[0m", 3
    if status == "input":
        return "\033[35mIDLE\033[0m", 0
    if status == "done":
        return "\033[1;32mDONE\033[0m", 1
    return "\033[33mRUN \033[0m", 2


# Context-window sizes we know how to scale the meter against, smallest
# first. There is no authoritative limit anywhere in the transcript (no
# field records it, and compactMetadata only ever shows *manual* compacts,
# so it teaches us nothing about the ceiling), and hardcoding a model->size
# table is exactly what rotted last time: the [1m] suffix that used to mark
# long-context models no longer appears in model ids at all, so every
# model was being measured against 200k and pinned at a permanent 100%.
# Instead we infer from evidence — a context of 357k *proves* the window is
# bigger than 200k — which needs no model knowledge and so can't go stale.
CTX_TIERS = (200_000, 1_000_000)


def ctx_limit(model, ctx):
    """Best guess at this session's context window. An explicit override
    always wins; the legacy [1m] marker is still honoured; otherwise pick
    the smallest tier the current context actually fits in.

    The one blind spot: under 200k a big window is indistinguishable from a
    small one, so a 1M session sitting at 170k is scaled against 200k and
    warns early. That's the deliberate direction to be wrong in — a
    spurious "consider compacting" costs you a glance, while staying quiet
    on a genuinely full 200k window costs you a surprise auto-compact
    mid-task — and it corrects itself the moment the context passes 200k."""
    override = os.environ.get("CLAUDE_TMUX_CONTEXT_LIMIT")
    if override:
        try:
            return int(override)
        except ValueError:
            pass
    if "[1m]" in (model or ""):
        return 1_000_000
    for tier in CTX_TIERS:
        if ctx <= tier:
            return tier
    return CTX_TIERS[-1]


def ctx_bar(model, ctx, cells=10):
    """Claude-Code-statusline-style context meter: ▓▓▓▓░░░░░░ 47% (93k),
    plus a red ⚠ /compact when you're actually near the ceiling.

    The trigger is *remaining headroom*, not a percentage, because a
    percentage doesn't survive the jump from 200k to 1M windows: 80% of
    200k leaves 40k and is worth acting on, while 80% of 1M leaves 200k —
    more room than an entire small window — and nagging there is noise.
    Warning under ~40k left reproduces the old 80% behaviour exactly on a
    200k window, and scales to ~95% on 1M (a bit more absolute slack, since
    one large tool result goes further toward filling what's left)."""
    if not ctx:
        return None
    limit = ctx_limit(model, ctx)
    frac = min(1.0, ctx / limit)
    fill = round(frac * cells)
    s = (
        "▓" * fill + DIM + "░" * (cells - fill) + RESET
        + f" {frac * 100:.0f}% ({ctx // 1000}k)"
    )
    if limit - ctx < max(40_000, limit // 20):
        s += " \033[31m⚠ /compact\033[0m"
    return s


def teams_of_session(session, data, teams_snap):
    """Which teams have a member pane sitting in this tmux session.

    Derived exactly the way `list-rows.sh` derives it — from the panes,
    because the roster records no session — so the preview cannot claim a
    team the session header above it doesn't show. The one difference is
    the source of a pane's session: the row list has live tmux open
    already, this reads the name the hooks recorded. They disagree only for
    a pane that has been moved between tmux sessions since its last status
    update, and paying a tmux round-trip on a path that runs at every
    cursor stop to close that gap is the wrong trade."""
    if not session or not teams_snap:
        return []
    out = set()
    for p, m in teams_snap["by_pane"].items():
        e = data.get(p)
        if e and not e.get("archived") and (e.get("session") or "") == session:
            out.add(m["team"])
    return sorted(out)


def pane_team_lines(pane, data, width, limit=4):
    """The few lines that say a pane is not working alone, printed with its
    status bar under the live screen in the pane preview.

    Capped at `limit` lines and every one of them conditional: this sits
    against a live screen dump, which is what the preview is actually for,
    so it may only spend rows when it has something to say. A member with
    no queued messages and no claimed task gets one line, not four with two
    of them empty — a blank labelled slot reads as louder than no slot.

    Two cases, because a team has two kinds of pane in it:

      - **the pane is a member.** Say which member, and what it is on.
      - **the pane is not, but its session hosts a team.** Then this is the
        lead's pane, or one sitting beside it — "which one is the lead" is
        not knowable, since a lead's roster entry holds the literal string
        `leader` where a pane id belongs, so the honest test is the session
        rather than the pane. One line, the same counts the session header
        carries, so that looking at a lead's screen answers "and how is the
        team doing" without going back to the list. The roster itself is
        deliberately *not* repeated here: the session header's preview
        already carries it in full, and rebuilding it against a live screen
        would be the duplication that folding the team block removed."""
    teams_snap = load_teams()
    if not teams_snap:
        return
    m = teams_snap["by_pane"].get(pane)
    if m:
        lines = []
        head = f"编队 {m['team']} · {m['label']} {m['name']}"
        if m.get("type"):
            head += f" · 类型 {m['type']}"
        lines.append(CYAN + clip(head, width) + RESET)
        if m.get("doing"):
            num = f"#{m['doing_id']} " if m.get("doing_id") else ""
            lines.append("在做 " + clip(num + m["doing"], width - 5))
        if m.get("inbox"):
            lines.append(f"信箱 {m['inbox']} 条未读")
        for ln in lines[:limit]:
            print(ln)
        return

    session = (data.get(pane) or {}).get("session") or ""
    by_team = {t["team"]: t for t in teams_snap["teams"]}
    for team in teams_of_session(session, data, teams_snap)[:limit]:
        t = by_team.get(team)
        if not t:
            continue
        c = t["counts"]
        bits = []
        n_mate = sum(1 for x in t["members"] if not x["is_lead"])
        if n_mate:
            bits.append(f"{agent_teams_module().MEMBER_LABEL} {n_mate}")
        # The same four counts the session header carries, in the same
        # order and with zeroes dropped the same way — this is a second
        # view of one number, not a second number.
        for key, word in (("in_progress", "在做"), ("pending", "待领"),
                          ("blocked", "挡住")):
            if c.get(key):
                bits.append(f"{word} {c[key]}")
        inbox = sum(x["inbox"] for x in t["members"])
        if inbox:
            bits.append(f"信箱 {inbox}")
        head = f"编队 {team}"
        if bits:
            head += " · " + " · ".join(bits)
        print(CYAN + clip(head, width) + RESET)


def agent_teams_module():
    """The already-imported team reader. load_teams() has run by the time
    anything needs this, so the import is a dict lookup in sys.modules."""
    import agent_teams
    return agent_teams


def team_board(team):
    """The roster, forming the top half of a team session's preview.

    A member with no pane appears *here and nowhere else*. It has no pane
    to jump to, so giving it a row in a list whose every row is a jump
    target would mean a row that silently swallows Enter. Saying so
    somewhere that isn't a jump target is the honest version — and once
    the standalone team block was folded into the session header, this
    became the only place left that can."""
    teams_snap = load_teams()
    if not teams_snap:
        return
    t = next((x for x in teams_snap["teams"] if x["team"] == team), None)
    if not t:
        return
    width = max(30, int(os.environ.get("FZF_PREVIEW_COLUMNS", 80)) - 2)

    try:
        with open(STATUS_FILE) as f:
            data = json.load(f)
    except Exception:
        data = {}

    print(BOLD + CYAN + clip(f"编队 {t['team']}", width) + RESET)
    now = time.time()
    for m in t["members"]:
        e = data.get(m["pane"]) if m["pane"] else None
        if e:
            label, rank = label_of(e)
            when = fmt_age(rank, int(now - e.get("updated_at", now)))
        elif m["pane"]:
            # In the roster with a pane, but the pane has not reported in.
            # A teammate only lands in the status file once it has been
            # through a full turn, so this is the normal look of one that
            # started moments ago — not an error, and not worth alarming
            # about.
            label, when = DIM + "— " + RESET, "状态未知"
        else:
            label, when = DIM + "— " + RESET, "没有对应 pane"
        tail = []
        if m.get("doing"):
            num = f"#{m['doing_id']} " if m.get("doing_id") else ""
            tail.append(num + m["doing"])
        if m.get("inbox"):
            tail.append(f"✉{m['inbox']}")
        # The name carries the member's own colour, the same one its row in
        # the list is printed in. That is where the association is learned:
        # the list has room for a colour and not for a word, so the surface
        # that does have room has to be the one that says which is which.
        on = f"\033[{m['sgr']}m" if m.get("sgr") else ""
        off = RESET if on else ""
        row = (f"{CYAN}{pad(m['label'], 5)}{RESET}"
               f"{on}{pad(clip(m['name'], 15), 16)}{off}"
               f"{label} {pad(when, 15)}{DIM}{m['pane'] or ''}{RESET}")
        print(clip(row, width + 40))
        if tail:
            print("      " + DIM + clip(" · ".join(tail), width - 6) + RESET)

    ts = [x for x in t["tasks"] if x.get("status") != "completed"]
    if not ts:
        return
    print(DIM + "─" * width + RESET)
    print(f"共享任务表(未完成 {len(ts)})")
    # "Still blocking" is asked the positive way round — is this id among the
    # tasks that are open — because finishing a task can *delete its file*,
    # and "not in the completed set" then answers yes for work that is done
    # and gone. See agent_teams.task_counts, which decides the same thing for
    # the counts; the two must not drift, or the header says `挡住 1` while
    # the list below it says `待领`.
    open_ids = {str(x.get("id")) for x in t["tasks"] if x.get("status") != "completed"}
    for x in ts[:12]:
        owner = x.get("owner") or ""
        status = x.get("status")
        waiting = [b for b in x.get("blockedBy") or [] if str(b) in open_ids]
        word = "在做" if status == "in_progress" else ("挡住" if waiting else "待领")
        # An unclaimed task shows a dash rather than a guess. The value of
        # this column is that you can act on it; a name that might be wrong
        # is worse than an obvious blank.
        who = clip(owner, 11) if owner else "——"
        line = f" {word}  {pad(who, 12)}{clip(x.get('subject') or '', width - 22)}"
        if waiting:
            line += DIM + f"  等 #{waiting[0]}" + RESET
        print(line)


def pad(s, width):
    """Pad to `width` visual columns, always leaving one trailing space so
    adjacent columns can't butt together (same rule as list-rows.sh)."""
    return s + " " * max(1, width - vwidth(s))


def pane_bar(pane):
    """--pane mode: a Claude-Code-statusline-style summary for one tracked
    pane — status · model · context size (± % of the window) · status-aware
    elapsed time · cwd — preceded by a dim rule and by whatever
    `pane_team_lines` has to say.

    **Printed below the screen dump, not above it, and that is the whole
    reason it is visible.** `preview-row.sh` writes the captured screen
    first; see the note in that file for why the top of a pane preview is
    not a place anything can be put."""
    try:
        with open(STATUS_FILE) as f:
            data = json.load(f)
    except Exception:
        return
    e = data.get(pane)
    if not e:
        return

    label, rank = label_of(e)
    age = int(time.time() - e.get("updated_at", time.time()))
    model, ctx, _recap, _task = transcript_info(e, want_text=False)

    width = max(30, int(os.environ.get("FZF_PREVIEW_COLUMNS", 80)) - 2)
    # A reset first: the screen dump above arrives via `capture-pane -e` and
    # can end mid-attribute — an unterminated colour there would otherwise
    # bleed into every line of this bar.
    print(RESET + DIM + "─" * width + RESET)
    pane_team_lines(pane, data, width)

    bits = []
    if model:
        bits.append(model.replace("claude-", ""))
    cb = ctx_bar(model, ctx)
    if cb:
        bits.append(cb)
    bits.append(fmt_age(rank, age))

    cwd = e.get("cwd") or ""
    line = f"{label}  " + " · ".join(bits) + f"  {DIM}{clip(cwd, width)}{RESET}"
    print(line)


def main():
    if len(sys.argv) == 3 and sys.argv[1] == "--pane":
        pane_bar(sys.argv[2])
        return
    if len(sys.argv) != 2:
        return
    session = sys.argv[1]

    try:
        with open(STATUS_FILE) as f:
            data = json.load(f)
    except Exception:
        return

    try:
        out = subprocess.check_output(
            ["tmux", "list-panes", "-a", "-F",
             "#{pane_id}\t#{session_name}\t#{window_name}\t#{pane_title}"],
            text=True, stderr=subprocess.DEVNULL,
        )
    except Exception:
        return
    win_of = {}
    for line in out.splitlines():
        parts = line.split("\t")
        if len(parts) == 4 and parts[1] == session:
            win_of[parts[0]] = (parts[2], parts[3])

    teams_snap = load_teams()
    by_pane = teams_snap["by_pane"] if teams_snap else {}

    now = time.time()
    cards = []
    for pane, e in data.items():
        if pane not in win_of or e.get("archived"):
            continue
        # A teammate gets no card of its own here. The roster above already
        # gives its name, status, age and current task in one line, and a
        # full card would repeat all of that at five times the height — the
        # duplication this preview was split in two to remove. Its live
        # screen is still one keypress away: `f`, then the pane row.
        if pane in by_pane:
            continue
        label, rank = label_of(e)
        cards.append((rank, -e.get("updated_at", 0), pane, label, e))
    cards.sort()

    width = max(30, int(os.environ.get("FZF_PREVIEW_COLUMNS", 80)) - 2)

    # Two halves, team first: "who is here" is the question you open this
    # preview asking, and the panes below only make sense once it's
    # answered. This is also the only surface that names the members with
    # no pane of their own — nothing in the row list can show them.
    teams_here = sorted({by_pane[p]["team"] for p in win_of if p in by_pane})
    for i, team in enumerate(teams_here):
        if i:
            print()
        team_board(team)
    if teams_here and cards:
        print()
        print(DIM + "─" * width + RESET)

    if not cards:
        return

    avail = int(os.environ.get("FZF_PREVIEW_LINES", 40))
    # per card: separator (blank + rule) + title + task + meta = 5 lines
    # of overhead
    recap_lines = max(2, min(6, avail // len(cards) - 5))

    first = True
    for _rank, _neg, pane, label, e in cards:
        # A blank line plus a full-width rule between cards — the old
        # single thin dashed line wasn't enough visual separation to tell
        # where one pane's card ended and the next began.
        if not first:
            print()
            print(DIM + "─" * width + RESET)
        first = False

        age = int(now - e.get("updated_at", now))
        wname, ptitle = win_of[pane]
        member = by_pane.get(pane)
        name = display_name(pane, e, wname, ptitle, member)
        role = f"{CYAN}{member['label']}{RESET} " if member else ""
        title = (f"{label}  {role}{BOLD}{clip(name, width - 18)}{RESET}"
                 f"  {DIM}{fmt_age(_rank, age)}{RESET}")
        print(title)

        model, ctx, recap, task = transcript_info(e)

        # What this pane is working on — its first real prompt.
        if task:
            print("\033[36m❯\033[0m " + clip(task, width - 2))

        # Model + context meter in normal intensity (the meter is the
        # single most triage-relevant number), cwd dimmed after them.
        left = " ".join(
            x for x in (model.replace("claude-", "") if model else None,
                        ctx_bar(model, ctx)) if x
        )
        cwd_room = max(10, width - 36)
        cwd = clip(e.get("cwd") or "", cwd_room)
        print((left + "  " if left else "") + DIM + cwd + RESET)

        if recap:
            for ln in wrap(recap, width - 2, recap_lines):
                print(DIM + "▎" + RESET + " " + ln)
        else:
            print(DIM + "▎ (还没有回复内容)" + RESET)



if __name__ == "__main__":
    main()
