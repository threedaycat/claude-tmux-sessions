#!/usr/bin/env python3
"""The picker's overview: one screen that answers "I'm back — what's the
situation", opened with `o`.

Three modes, because the page around it (bin/overview-page.sh) is an fzf
list:

  --head        the greeting and the counts, as fzf's header
  --rows        one card per tmux session, as the list itself
  --card <ref>  everything known about whatever the cursor is on, as the
                preview

**Cards, one per session.** The first version of this page grouped panes by
*state* — a 等你 block and a 在跑 block — which answered "what needs me"
and then left you to work out where those panes actually live. Grouping by
session answers both at once: a session is a place you go, so its card is
the unit you act on. The states are still what decides the order — the
session holding the longest-waiting pane comes first — so the page still
reads urgency-first from the top.

**Session order here is urgency, unlike the picker's list**, where it is
tmux's own creation order specifically so the list doesn't reshuffle under
you while you work. This screen is read once, on arrival, and then acted on;
"who needs me" is the only order worth having for that.

**Nothing here classifies a pane by itself.** `display_name`, `label_of`,
`fmt_age` and `ctx_bar` are imported from bin/session-digest.py, so a pane is
called the same thing and its state is worded the same way as in the list and
in the preview of that list. The only local rules are which bucket a pane
lands in and how the cards are ordered, which is this screen's own editorial
judgement.

Read-only: the status file, the roster, `tmux list-panes`, the transcripts it
reads a tail of, and — when the page passes one in — a token-report cache. It
marks nothing read: looking at the bridge is not visiting a pane.
"""
import importlib.util
import json
import os
import subprocess
import sys
import time

BIN_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BIN_DIR)
import agent_teams                                            # noqa: E402

# session-digest.py can't be imported by name (the hyphen isn't a legal
# module name), and it is worth the four lines: it is where the naming and
# state-wording rules already live, guarded by a __main__ check so importing
# it runs nothing. Copying them here instead would make a third copy of
# rules DESIGN.md already calls out as dangerous to duplicate.
_spec = importlib.util.spec_from_file_location(
    "session_digest", os.path.join(BIN_DIR, "session-digest.py"))
sd = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(sd)

STATUS_FILE = os.path.expanduser("~/.claude/tmux-claude-status.json")
# Same threshold and env override as the row list and the ambient bar: an
# unread DONE nobody came back to for this long is abandoned, not pending.
IDLE_STALE = int(os.environ.get("CLAUDE_TMUX_IDLE_STALE_SECS", "7200"))

DIM = "\033[2m"
RESET = "\033[0m"
BOLD = "\033[1m"
RED = "\033[1;31m"
GREEN = "\033[1;32m"
YELLOW = "\033[33m"
CYAN = "\033[36m"

# rank -> the icon the row list puts in front of the label. Keyed on rank,
# not on status, so the state logic itself stays in one place: label_of
# answers *what* this pane is, this only says how to draw it.
ICON = {-1: "⏸︎", 1: "✔︎", 2: "▶︎", 3: "✓︎"}

# `input` (Claude idle, waiting on your next message) is rendered as DONE,
# the way the row list renders it: both mean "it finished, it's your turn".
# session-digest's own preview keeps them apart because there the subject is
# one pane in detail; here a second word for the same situation would just
# make the list and the overview disagree about what a pane is called.
IDLE_RANK, DONE_RANK = 0, 1
DONE_LABEL = "\033[1;32mDONE\033[0m"

# How urgent each bucket is — the order of the cards, and of the rows inside
# one. The only ranking this file owns.
PRIO = {"wait": 0, "done": 1, "run": 2, "stale": 3, "read": 4}
BUCKET_ICON = {"wait": ("⏸︎", RED), "done": ("✔︎", GREEN), "run": ("▶︎", YELLOW),
               "stale": ("✔︎", DIM), "read": ("✓︎", DIM)}

WHERE_W = 14
LABEL_W = 8


def load_status():
    try:
        with open(STATUS_FILE) as f:
            return json.load(f)
    except Exception:                                          # noqa: BLE001
        return {}


def live_panes():
    """pane -> (session, window_index, window_name, pane_title) from tmux
    itself rather than from the recorded entry: a window renamed after the
    status was written still reads correctly. Same choice as the ambient bar
    and the picker."""
    try:
        out = subprocess.check_output(
            ["tmux", "list-panes", "-a", "-F",
             "#{pane_id}\t#{session_name}\t#{window_index}\t#{window_name}"
             "\t#{pane_title}"], text=True, stderr=subprocess.DEVNULL)
    except Exception:                                          # noqa: BLE001
        return {}
    live = {}
    for line in out.splitlines():
        p = line.split("\t")
        if len(p) == 5:
            live[p[0]] = tuple(p[1:])
    return live


def bucket_of(e, age):
    status = e.get("status", "running")
    if status == "blocked" and not e.get("read"):
        return "wait"
    if status == "blocked":
        # Blocked but already visited: the prompt is still up, but you have
        # seen it, so it is not what this screen should shout about.
        return "read"
    if status in ("done", "input") and e.get("read"):
        return "read"
    if status in ("done", "input") and age >= IDLE_STALE:
        return "stale"
    if status in ("done", "input"):
        return "done"
    return "run"


def collect():
    """Every tracked, live, unarchived pane, grouped into session cards.
    Panes that are gone or archived are dropped rather than counted: the
    question on this screen is what is in front of you *now*."""
    data = load_status()
    live = live_panes()
    snap = agent_teams.snapshot()
    now = time.time()

    rows, by_pane = [], {}
    for pane, e in data.items():
        if pane not in live or e.get("archived"):
            continue
        session, win_idx, win_name, pane_title = live[pane]
        member = snap["by_pane"].get(pane)
        age = int(now - e.get("updated_at", now))
        kind = bucket_of(e, age)
        label, rank = sd.label_of(e)
        if rank == IDLE_RANK:
            label, rank = DONE_LABEL, DONE_RANK
        row = {
            "pane": pane, "session": session, "where": f"{session}:{win_idx}",
            "age": age, "kind": kind, "rank": rank, "label": label,
            "sid": (e.get("session_id") or "").strip(), "entry": e,
            "member": member,
            "name": sd.display_name(pane, e, win_name, pane_title, member),
        }
        rows.append(row)
        by_pane[pane] = row

    sessions = {}
    for r in rows:
        sessions.setdefault(r["session"], []).append(r)
    for rs in sessions.values():
        rs.sort(key=lambda r: (PRIO[r["kind"]], -r["age"]))

    # Which teams sit in which session — derived from the panes, the way
    # session-digest derives it, because the roster records no session.
    teams_in = {}
    for pane, m in snap["by_pane"].items():
        r = by_pane.get(pane)
        if r:
            teams_in.setdefault(r["session"], set()).add(m["team"])

    def key(name):
        rs = sessions[name]
        best = min(PRIO[r["kind"]] for r in rs)
        oldest = max(r["age"] for r in rs if PRIO[r["kind"]] == best)
        return (best, -oldest, name)

    order = sorted(sessions, key=key)
    return {"sessions": sessions, "order": order, "by_pane": by_pane,
            "teams_in": teams_in, "snap": snap, "rows": rows}


# ------------------------------------------------------------------ head

def counts_of(rows):
    c = {}
    for r in rows:
        c[r["kind"]] = c.get(r["kind"], 0) + 1
    return c


def render_head(st, width):
    """The greeting: the one-line answer, readable without looking at
    anything below it. The good case is said out loud rather than left to be
    inferred from an empty list."""
    c = counts_of(st["rows"])
    need = c.get("wait", 0) + c.get("done", 0)
    if c.get("wait"):
        head = f"{RED}{c['wait']} 个等你确认{RESET}"
    elif c.get("done"):
        head = f"{GREEN}{c['done']} 个有结果等你看{RESET}"
    elif c.get("run"):
        head = f"{DIM}没人等你 · {c['run']} 个还在跑{RESET}"
    else:
        head = f"{DIM}没人等你 · 也没人在跑{RESET}"
    out = [f" {BOLD}舰桥{RESET}  {DIM}{time.strftime('%H:%M')}{RESET}  {head}"]
    tail = (f"{len(st['order'])} 个 session · 在册 {len(st['rows'])} · "
            f"在跑 {c.get('run', 0)} · 等你 {need} · 已读 {c.get('read', 0)}")
    if c.get("stale"):
        tail += f" · 放久了 {c['stale']}"
    out.append(f" {DIM}{sd.clip(tail, max(20, width - 2))}{RESET}")
    return "\n".join(out)


# ------------------------------------------------------------------ rows

def state_cell(row):
    """`⏸︎ WAIT` plus the age worded for that state — both from
    session-digest, so this screen cannot drift from the other two."""
    icon = ICON.get(row["rank"], "·")
    label, when = row["label"], sd.fmt_age(row["rank"], row["age"])
    if row["kind"] == "stale":
        # Aged-out unread: still listed, dimmed, exactly as the row list
        # treats it — reachable, but not competing for attention.
        return f"{DIM}{icon} DONE{RESET}", f"{DIM}{when}{RESET}"
    return f"{icon} {label}", when


def render_rows(st, width):
    """One card per session: a title line carrying the session's state
    counts, then its panes, most urgent first.

    Tab-separated: field 1 is what you see, field 2 is the pane Enter jumps
    to (empty where there is nothing to jump to — the card title of a session
    whose active pane can't be resolved, or a teammate with no pane), field 3
    is what the preview should draw."""
    name_w = max(12, min(30, width - 44))
    out = []
    for i, session in enumerate(st["order"]):
        rows = st["sessions"][session]
        c = counts_of(rows)
        # Only the three states that mean something to you get a chip. The
        # quiet ones are one dim count: `✔︎ 3` next to a dim `✔︎ 6` was the
        # same glyph twice in one line, distinguishable only by intensity,
        # and the difference it was hiding (unread vs aged-out) is exactly
        # the one that must not need a second look.
        bits = []
        for kind in ("wait", "done", "run"):
            if c.get(kind):
                icon, colour = BUCKET_ICON[kind]
                bits.append(f"{colour}{icon} {c[kind]}{RESET}")
        quiet = c.get("stale", 0) + c.get("read", 0)
        if quiet:
            bits.append(f"{DIM}+{quiet} 安静{RESET}")
        teams = sorted(st["teams_in"].get(session, ()))
        team_bit = f"  {CYAN}编队 {sd.clip(teams[0], 20)}{RESET}" if teams else ""
        if len(teams) > 1:
            team_bit += f"{CYAN}+{len(teams) - 1}{RESET}"
        # A blank line between cards, except before the first: the gap is
        # what makes them read as cards. It is a row like any other, so it
        # points at the card it is about to introduce — walking down through
        # the gap shows the next session's card before you reach its title —
        # and it has no jump target, so Enter there says so.
        if i:
            out.append(f"\t\ts:{session}")
        title = (f"{BOLD}▾ {sd.pad(sd.clip(session, 20), 21)}{RESET}"
                 f"{'  '.join(bits)}{team_bit}")
        out.append(f"{title}\t{active_pane(session)}\ts:{session}")
        for r in rows:
            label, when = state_cell(r)
            line = (f"   {label}  {sd.pad(sd.clip(r['name'], name_w), name_w)}"
                    f"  {DIM}{sd.pad(r['where'], WHERE_W)}{RESET}{when}")
            out.append(f"{line}\t{r['pane']}\tp:{r['pane']}")
        # Teammates the roster knows about that have no pane of their own.
        # **This is the only surface that can show them** — every row in the
        # picker's list is a jump target, and one that silently swallowed
        # Enter would be worse than not listing it. Here Enter says why.
        for team in teams:
            t = next((x for x in st["snap"]["teams"] if x["team"] == team), None)
            for m in (t["members"] if t else []):
                if m["pane"] and m["pane"] in st["by_pane"]:
                    continue
                sgr = f"\033[{m['sgr']}m" if m.get("sgr") else ""
                off = RESET if sgr else ""
                why = "没有 pane" if not m["pane"] else f"{m['pane']} 没在跟踪"
                line = (f"   {DIM}——{RESET}      {sgr}"
                        f"{sd.pad(sd.clip(m['name'], name_w), name_w)}{off}"
                        f"  {DIM}{why}{RESET}")
                out.append(f"{line}\t\tm:{team}|{m['name']}")
    return "\n".join(out)


_active = None


def active_pane(session):
    """The session's active pane — where you last were in it, which is what
    Enter on a card title should mean. Resolved by exact string match over
    list-panes rather than a `=session:` target, because tmux allows ':' and
    '.' in session names and those derail target parsing."""
    global _active
    if _active is None:
        _active = {}
        try:
            out = subprocess.check_output(
                ["tmux", "list-panes", "-a", "-F",
                 "#{session_name}\t#{window_active}#{pane_active}\t#{pane_id}"],
                text=True, stderr=subprocess.DEVNULL)
        except Exception:                                      # noqa: BLE001
            out = ""
        for line in out.splitlines():
            p = line.split("\t")
            if len(p) == 3 and p[1] == "11":
                _active.setdefault(p[0], p[2])
    return _active.get(session, "")


# ----------------------------------------------------------------- cards

def tokens_index(path):
    """{session_id: session record} from a token-report cache, or {}.

    Optional on purpose: the page warms the cache in the background, so a
    card drawn in the first half-second simply has no 今日 line rather than
    waiting for one."""
    if not path:
        return {}
    try:
        with open(path) as f:
            data = json.load(f)
    except Exception:                                          # noqa: BLE001
        return {}
    return {s["sid"]: s for s in data.get("sessions", []) if s.get("sid")}


def fmt_tok(n):
    if n >= 1_000_000:
        return f"{n / 1_000_000:.1f}M"
    if n >= 1_000:
        return f"{n / 1_000:.0f}k"
    return str(n)


def field(label, value):
    return f"{CYAN}{sd.pad(label, LABEL_W)}{RESET}{value}"


def token_line(rec):
    if not rec:
        return None
    avg = rec["ctx"] // rec["turns"] if rec.get("turns") else 0
    return (f"读入 {fmt_tok(rec.get('read', 0))} · {rec.get('turns', 0):,} 轮 · "
            f"{YELLOW}均/轮 {fmt_tok(avg)}{RESET}")


def rule(w):
    return f"{DIM}{'─' * w}{RESET}"


def pane_card(st, pane, w, tok):
    """One pane, in full — **and deliberately without its screen.** The row
    list's own preview is the live screen; asking this page for the same
    thing would make `o` a second copy of it. What this answers instead is
    the question the screen can't: what state is this in, how long has it
    been there, how full is its context, what team owns it, and what has it
    cost today."""
    r = st["by_pane"].get(pane)
    if r is None:
        return f"{DIM}这个 pane 已经不在了。{RESET}"
    e = r["entry"]
    label, when = state_cell(r)
    out = [f"{label}  {BOLD}{sd.clip(r['name'], w - 24)}{RESET}  {DIM}{when}{RESET}",
           rule(w)]

    out.append(field("位置", f"{r['where']}  {DIM}{pane}{RESET}"))
    cwd = e.get("cwd") or ""
    if cwd:
        home = os.path.expanduser("~")
        if cwd.startswith(home):
            cwd = "~" + cwd[len(home):]
        out.append(field("目录", sd.clip(cwd, w - LABEL_W)))

    model, ctx, _recap, task = sd.transcript_info(e)
    bits = [x for x in ((model or "").replace("claude-", "") or None,
                        sd.ctx_bar(model, ctx)) if x]
    if bits:
        out.append(field("模型", "  ".join(bits)))

    m = r["member"]
    if m:
        head = f"{m['label']} {m['name']}"
        if m.get("type"):
            head += f" · 类型 {m['type']}"
        out.append(field("编队", f"{sd.clip(m['team'], 20)} · {head}"))
        if m.get("doing"):
            num = f"#{m['doing_id']} " if m.get("doing_id") else ""
            out.append(field("在做", sd.clip(num + m["doing"], w - LABEL_W)))
        if m.get("inbox"):
            out.append(field("信箱", f"{RED}{m['inbox']} 条未读{RESET}"))

    line = token_line(tok.get(r["sid"]))
    if line:
        out.append(field("今日", line))
    if task:
        out.append(field("开场", sd.clip(task, w - LABEL_W)))
    out.append(field("更新", time.strftime(
        "%m-%d %H:%M", time.localtime(e.get("updated_at", time.time())))
        + (f"  {DIM}已读{RESET}" if e.get("read") else "")))
    if r["sid"]:
        out.append(field("会话", f"{DIM}{r['sid'][:8]}{RESET}"))
    return "\n".join(out)


def session_card(st, session, w, tok):
    """A whole session at a glance: how many panes are in each state, which
    team is running in it, what the most urgent thing in it is, and what the
    lot of them have cost today."""
    rows = st["sessions"].get(session)
    if not rows:
        return f"{DIM}这个 session 已经不在了。{RESET}"
    c = counts_of(rows)
    out = [f"{BOLD}{sd.clip(session, w - 12)}{RESET}  {DIM}{len(rows)} 个 pane{RESET}",
           rule(w)]
    bits = []
    for kind, word in (("wait", "等确认"), ("done", "有结果"), ("run", "在跑")):
        if c.get(kind):
            icon, colour = BUCKET_ICON[kind]
            bits.append(f"{colour}{icon} {word} {c[kind]}{RESET}")
    # The quiet two get words and no icon: aged-out DONE and READ would
    # otherwise be drawn with the same tick as the unread ones, and telling
    # them apart by intensity alone is exactly the mistake to avoid here.
    for kind, word in (("stale", "放久了"), ("read", "已读")):
        if c.get(kind):
            bits.append(f"{DIM}{word} {c[kind]}{RESET}")
    out.append(field("状态", " · ".join(bits) if bits else "—"))

    wins = sorted({r["where"] for r in rows})
    out.append(field("窗口", sd.clip(" ".join(wins), w - LABEL_W)))

    top = rows[0]
    label, when = state_cell(top)
    out.append(field("最急", f"{label}  {sd.clip(top['name'], 20)}  {DIM}{when}{RESET}"))

    for team in sorted(st["teams_in"].get(session, ())):
        t = next((x for x in st["snap"]["teams"] if x["team"] == team), None)
        if not t:
            continue
        k = t["counts"]
        out.append(field("编队", f"{CYAN}{sd.clip(team, 20)}{RESET} {DIM}· 队员 "
                                f"{len(t['members'])} · 在做 {k['in_progress']} · 待领 "
                                f"{k['pending']} · 挡住 {k['blocked']} · 完成 "
                                f"{k['completed']}{RESET}"))
        inbox = sum(x["inbox"] for x in t["members"])
        if inbox:
            out.append(field("信箱", f"{RED}{inbox} 条未读{RESET}"))

    read = sum((tok.get(r["sid"]) or {}).get("read", 0) for r in rows)
    turns = sum((tok.get(r["sid"]) or {}).get("turns", 0) for r in rows)
    if turns:
        out.append(field("今日", f"读入 {fmt_tok(read)} · {turns:,} 轮"))

    # The same panes as the list on the left, with one column the list has
    # no room for: what each has read in today. Without it this block would
    # be a second copy of what the cursor is already sitting next to.
    out.append(rule(w))
    for r in rows:
        label, when = state_cell(r)
        rec = tok.get(r["sid"]) or {}
        spend = fmt_tok(rec["read"]) if rec.get("read") else "—"
        out.append(f"  {label}  {sd.pad(sd.clip(r['name'], 20), 21)}"
                   f"{DIM}{sd.pad(spend, 8)}{RESET}{when}")
    return "\n".join(out)


def member_card(st, ref, w):
    """A teammate the roster knows about but tmux doesn't. It has no pane, so
    it has no screen, no status and nothing to jump to — saying that plainly
    is the whole job of this card."""
    team, _, name = ref.partition("|")
    t = next((x for x in st["snap"]["teams"] if x["team"] == team), None)
    m = next((x for x in (t["members"] if t else []) if x["name"] == name), None)
    if not m:
        return f"{DIM}花名册里已经没有这个成员了。{RESET}"
    sgr = f"\033[{m['sgr']}m" if m.get("sgr") else ""
    out = [f"{sgr}{BOLD}{sd.clip(name, w - 14)}{RESET}  {DIM}没有 pane{RESET}", rule(w)]
    out.append(field("编队", sd.clip(team, w - LABEL_W)))
    out.append(field("角色", m.get("label") or "—"))
    if m.get("type"):
        out.append(field("类型", m["type"]))
    if m.get("doing"):
        num = f"#{m['doing_id']} " if m.get("doing_id") else ""
        out.append(field("在做", sd.clip(num + m["doing"], w - LABEL_W)))
    if m.get("inbox"):
        out.append(field("信箱", f"{RED}{m['inbox']} 条未读{RESET}"))
    out.append("")
    if m["pane"]:
        out.append(f"{DIM}花名册里写着 {m['pane']},但那个 pane 没在跟踪 —— "
                   f"可能已经关了,或者里面的 Claude 从没发过 hook。{RESET}")
    else:
        out.append(f"{DIM}花名册里有它,但没有对应的 tmux pane,所以跳不过去。"
                   f"队员只有真正跑起来过才会有 pane。{RESET}")
    return "\n".join(out)


def render_card(st, ref, width, tokens_path):
    w = max(30, width - 2)
    tok = tokens_index(tokens_path)
    kind, _, rest = ref.partition(":")
    if kind == "p":
        return pane_card(st, rest, w, tok)
    if kind == "s":
        return session_card(st, rest, w, tok)
    if kind == "m":
        return member_card(st, rest, w)
    return ""


def main():
    width, mode, ref, tokens = 100, "rows", "", ""
    args = sys.argv[1:]
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--width" and i + 1 < len(args):
            width = max(40, int(args[i + 1])); i += 2
        elif a == "--card" and i + 1 < len(args):
            mode, ref = "card", args[i + 1]; i += 2
        elif a == "--tokens" and i + 1 < len(args):
            tokens = args[i + 1]; i += 2
        elif a in ("--head", "--rows"):
            mode = a.lstrip("-"); i += 1
        else:
            i += 1

    # An empty ref is what fzf substitutes on an empty list; drawing nothing
    # is the right answer, and cheaper than collecting first.
    if mode == "card" and not ref:
        return

    st = collect()
    if mode == "head":
        print(render_head(st, width))
    elif mode == "card":
        text = render_card(st, ref, width, tokens)
        if text:
            print(text)
    else:
        rows = render_rows(st, width)
        if rows:
            print(rows)


if __name__ == "__main__":
    main()
