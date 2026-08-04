#!/usr/bin/env python3
"""Where the tokens went: a token report built from the local transcripts,
no API calls.

Two blocks, in the order the question actually gets asked. First an
overview of the window (turns, and the four token classes split out).
Then a per-session ranking — because "which of my two dozen Claudes is
expensive" is the only version of the question you can act on.

Cost is roughly turns x the context each turn carried, and ~98% of the
tokens are cache reads: re-reading the context that already exists. So
turn count alone misjudges badly — a session with a third of the turns
outranks its neighbours when every one of those turns hauls half a
megabyte of context. That's why 均/轮 (mean context per turn) is a
column of its own, highlighted: it's the driver, and it's the one number
that says *why* a session is expensive rather than just that it is.

Data: ~/.claude/projects/<sanitized-cwd>/<session-id>.jsonl, one JSON
object per line. Lines carrying message.usage are API responses; the
usage block gives input_tokens / cache_creation_input_tokens /
cache_read_input_tokens / output_tokens, and the line's timestamp (UTC)
places it in a day.

Read-only, and never loads a transcript into memory: files are streamed
line by line and skipped entirely unless mtime falls inside the window
(a file untouched since before the window cannot contain a line inside
it). Lines are pre-filtered on the '"usage"' substring before paying for
json.loads — most lines are user turns and tool results.

**The scan is separated from the rendering by a cache file**, because the
page around it (bin/token-page.sh) is an fzf list now: it re-renders the
row list and the header on a cursor move or a window switch, and a scan
per keypress is what made that page feel like it was chewing. One scan
writes the cache; every render after it is a small JSON read.

usage: token-report.py [--days N] [--top N] [--width N]
                       [--cache FILE [--force]]
                       [--scan | --overview | --rows | --detail SID]
       --days 1 (default) = since local midnight; 7 = the last 7 days
       no mode flag       = print the whole thing as static text
"""
import calendar
import glob
import json
import os
import subprocess
import sys
import time
import unicodedata
from bisect import bisect_right
from collections import defaultdict

BIN_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECTS_DIR = os.path.expanduser("~/.claude/projects")
STATUS_FILE = os.path.expanduser("~/.claude/tmux-claude-status.json")
HOME = os.path.expanduser("~")

RESET = "\033[0m"
DIM = "\033[2m"
BOLD = "\033[1m"
CYAN = "\033[36m"
YELLOW = "\033[33m"

BAR_W = 22
SPARK = "▁▂▃▄▅▆▇█"

# How many un-named sessions get their opening prompt read as a last-resort
# name. Bounded because that is a file read per session and the ranking's
# tail is not what anybody is looking at — everything past this keeps the
# short session id it always had.
NAME_PROBE_LIMIT = 30

_sd = None


def sd():
    """session-digest.py, imported lazily by path (the hyphen in the name
    makes it un-importable the normal way).

    Same rule as everywhere else in this repo: names, status words and
    elapsed-time phrasing come from the one module that owns them, so a
    session is called the same thing here as in the picker's list. Lazy
    because `--scan` needs it and `--overview` does not."""
    global _sd
    if _sd is None:
        import importlib.util
        spec = importlib.util.spec_from_file_location(
            "session_digest", os.path.join(BIN_DIR, "session-digest.py"))
        mod = importlib.util.module_from_spec(spec)
        sys.path.insert(0, BIN_DIR)
        spec.loader.exec_module(mod)
        _sd = mod
    return _sd


def vwidth(s):
    return sum(2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1 for ch in s)


def pad(s, width, right=False):
    gap = " " * max(0, width - vwidth(s))
    return gap + s if right else s + gap


def clip(s, width):
    """Truncate to `width` visual columns *including* the `..` marker — the
    marker has to be paid for out of the budget, or a clipped cell ends up
    two columns wider than its column and shifts everything after it."""
    if vwidth(s) <= width:
        return s
    out, w = "", 0
    for ch in s:
        cw = 2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1
        if w + cw > width - 2:
            break
        out, w = out + ch, w + cw
    return out + ".."


def fmt_tok(n):
    """Same scale vocabulary as the picker's usage footer: k/M/B, never raw
    ten-digit numbers — nothing here is read digit by digit."""
    if n >= 1_000_000_000:
        return f"{n / 1_000_000_000:.2f}B"
    if n >= 1_000_000:
        return f"{n / 1_000_000:.1f}M"
    if n >= 1_000:
        return f"{n / 1_000:.0f}k"
    return str(n)


def bar(frac, width=BAR_W):
    fill = max(1, round(frac * width)) if frac > 0 else 0
    return CYAN + "█" * fill + RESET + DIM + "░" * (width - fill) + RESET


def spark(values):
    peak = max(values) if values else 0
    if not peak:
        return ""
    return "".join(
        SPARK[min(len(SPARK) - 1, int(v / peak * (len(SPARK) - 1) + 0.5))]
        for v in values
    )


def window_start(days):
    """Local midnight, days-1 days back — 'the last 7 days' means today
    plus the six before it, not a rolling 168 hours; a day boundary is
    what people compare against."""
    lt = time.localtime()
    midnight = time.mktime((lt.tm_year, lt.tm_mon, lt.tm_mday, 0, 0, 0, 0, 0, -1))
    return midnight - (max(1, days) - 1) * 86400


def _iso(ts):
    return time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(ts))


def _local_of(iso):
    """Local epoch seconds for a transcript timestamp, or 0."""
    try:
        return calendar.timegm(time.strptime(iso[:19], "%Y-%m-%dT%H:%M:%S"))
    except Exception:                                          # noqa: BLE001
        return 0


def collect(days):
    start = window_start(days)
    # Timestamps in the transcript are UTC ISO ("...Z"), so the cutoff is
    # compared as a string against the same encoding of local midnight —
    # lexical order on a fixed-width ISO stamp is chronological order, and
    # it saves parsing a datetime per line.
    cutoff = _iso(start)

    # Day buckets, as the same kind of string: which day a line belongs to
    # is then a bisect over at most seven cut points instead of a parsed
    # datetime per line.
    day_cuts, day_labels = [], []
    for k in range(max(1, days)):
        t = start + k * 86400
        day_cuts.append(_iso(t))
        day_labels.append(time.strftime("%m-%d", time.localtime(t)))

    totals = defaultdict(int)
    turns = 0
    sessions = {}
    files = 0
    # One API response is written to the transcript as several lines — one
    # per content block (thinking, text, each tool_use) — and every one of
    # them repeats the same usage block. Counting per line inflates the
    # totals by ~1.9x, so responses are counted once, keyed by message.id.
    seen = set()

    for path in glob.glob(os.path.join(PROJECTS_DIR, "*", "*.jsonl")):
        try:
            if os.path.getmtime(path) < start:
                continue
        except OSError:
            continue
        sid = os.path.basename(path)[:-6]
        files += 1
        try:
            fh = open(path, errors="replace")
        except OSError:
            continue
        with fh:
            for line in fh:
                if '"usage"' not in line:
                    continue
                try:
                    obj = json.loads(line)
                except ValueError:
                    continue
                if obj.get("type") != "assistant":
                    continue
                ts = obj.get("timestamp") or ""
                if ts < cutoff:
                    continue
                msg = obj.get("message") or {}
                mid = msg.get("id")
                if mid:
                    if mid in seen:
                        continue
                    seen.add(mid)
                u = msg.get("usage") or {}
                inp = u.get("input_tokens") or 0
                read = u.get("cache_read_input_tokens") or 0
                create = u.get("cache_creation_input_tokens") or 0
                out = u.get("output_tokens") or 0

                turns += 1
                totals["input"] += inp
                totals["read"] += read
                totals["create"] += create
                totals["output"] += out

                # Context carried by this turn: everything that went *in*,
                # cached or not. That is what the turn was billed against.
                ctx = inp + read + create
                s = sessions.get(sid)
                if s is None:
                    s = sessions[sid] = {
                        "sid": sid, "path": path, "turns": 0, "read": 0,
                        "create": 0, "output": 0, "input": 0, "ctx": 0,
                        "peak": 0, "proj": "", "cwd": "", "model": "",
                        "last": "", "by_day": [0] * len(day_cuts),
                    }
                s["turns"] += 1
                s["read"] += read
                s["create"] += create
                s["output"] += out
                s["input"] += inp
                s["ctx"] += ctx
                s["peak"] = max(s["peak"], ctx)
                s["by_day"][max(0, bisect_right(day_cuts, ts) - 1)] += ctx
                s["last"] = ts
                if msg.get("model"):
                    s["model"] = msg["model"]
                # Last cwd seen, not the first: a long session can move
                # between directories, and taking the first one made the
                # same session show a different project in the 1-day and
                # 7-day views. The most recent is also the more useful
                # answer to "what is this one working on".
                cwd = (obj.get("cwd") or "").rstrip("/")
                if cwd:
                    s["cwd"] = cwd
                    s["proj"] = "~" if cwd == HOME else (os.path.basename(cwd) or cwd)

    ranked = sorted(sessions.values(), key=lambda s: -s["read"])
    name_sessions(ranked)
    return {"days": days, "start": start, "generated": time.time(),
            "turns": turns, "files": files, "totals": dict(totals),
            "day_labels": day_labels, "sessions": ranked}


def live_panes():
    """(sid -> pane, pane -> (where, window_name, pane_title)) for panes
    tmux still has open and the hooks have seen — the join that lets a
    transcript be called what the picker calls it."""
    try:
        with open(STATUS_FILE) as f:
            status = json.load(f)
    except Exception:                                          # noqa: BLE001
        status = {}
    try:
        out = subprocess.check_output(
            ["tmux", "list-panes", "-a", "-F",
             "#{pane_id}\t#{session_name}:#{window_index}\t#{window_name}\t#{pane_title}"],
            text=True, stderr=subprocess.DEVNULL,
        )
    except Exception:                                          # noqa: BLE001
        out = ""
    where = {}
    for line in out.splitlines():
        parts = line.split("\t")
        if len(parts) == 4:
            where[parts[0]] = (parts[1], parts[2], parts[3])
    by_sid = {}
    for pane, e in status.items():
        sid = (e.get("session_id") or "").strip()
        if sid and pane in where:
            by_sid.setdefault(sid, pane)
    return by_sid, where, status


def name_sessions(ranked):
    """Fill in `name`, `pane` and `where` on every session in the ranking.

    The old ranking named a session by the first eight characters of its
    id, which is not a name — it is the one thing about a session that
    means nothing to the person reading it. The chain here is the picker's
    chain (see list-rows.sh), with one extra level at the bottom: a
    session's opening prompt, which is the only human-readable label a
    transcript with no live pane has left."""
    m = sd()
    by_sid, where, status = live_panes()
    teams = m.load_teams() or {}
    by_pane = teams.get("by_pane", {}) if teams else {}
    manual = m.manual_names()

    probes = 0
    for s in ranked:
        sid = s["sid"]
        pane = by_sid.get(sid, "")
        s["pane"] = pane
        w, wname, ptitle = where.get(pane, ("", "", ""))
        s["where"] = w
        member = by_pane.get(pane)
        name = (
            manual.get(sid, "")
            or (member or {}).get("name", "")
            or m.safe_title(ptitle)
            or (wname or "").strip()
        )
        if not name and probes < NAME_PROBE_LIMIT:
            probes += 1
            name = (m.first_prompt(s["path"]) or "")[:200]
            # A prompt is a sentence, not a label: mark it so a long
            # truncated line doesn't read as somebody's chosen name.
            if name:
                s["from_prompt"] = True
        s["name"] = name or sid[:8]


# ---------------------------------------------------------------- cache

def ensure(path, days, force=False, days_given=True):
    """Write the cache for this window if it isn't there already.

    Atomic, because two of these can be in flight at once: the page warms
    the 7-day window in the background while you look at today, and
    pressing `7` before that finishes starts a second scan of the same
    window. Duplicated work, but never a half-written file that the next
    render would fail to parse.

    A forced rescan with no `--days` takes the window from the cache it is
    replacing. That is what lets the page's refresh key be one string for
    both windows: it knows which cache the visible list came from (the rows
    carry it) and doesn't have to also track which window that was."""
    if path and os.path.exists(path) and os.path.getsize(path) > 0:
        if not force:
            return load(path)
        if not days_given:
            try:
                days = load(path).get("days", days)
            except Exception:                                  # noqa: BLE001
                pass
    data = collect(days)
    if path:
        tmp = f"{path}.{os.getpid()}"
        try:
            with open(tmp, "w") as f:
                json.dump(data, f)
            os.replace(tmp, path)
        except OSError:
            try:
                os.unlink(tmp)
            except OSError:
                pass
    return data


def load(path):
    with open(path) as f:
        return json.load(f)


# --------------------------------------------------------------- render

def render_overview(data, width):
    """The window's totals — the fzf list's header, and the top of the
    static page. Sized for the list side of a split picker (~half the
    terminal), so nothing here may assume a full-width screen."""
    totals, turns = data["totals"], data["turns"]
    get = lambda k: totals.get(k, 0)                           # noqa: E731
    incoming = get("input") + get("read") + get("create")
    grand = incoming + get("output")

    days = data["days"]
    label = "今日" if days <= 1 else f"近 {days} 天"
    span = time.strftime("%m-%d", time.localtime(data["start"]))
    today = time.strftime("%m-%d")
    span = today if days <= 1 else f"{span} → {today}"

    out = []
    head = (f"{BOLD}{label} token 消耗{RESET}   {DIM}{span} · "
            f"{len(data['sessions'])} 个会话{RESET}")
    ranked = data["sessions"]
    # The concentration figure is the first thing to go when the list side
    # is narrow: fzf truncates a header line rather than wrapping it, and
    # losing the tail of the date range to keep this would be a worse trade.
    if get("read") and width >= 62:
        top5 = sum(s["read"] for s in ranked[:5])
        head += f"{DIM} · 前 5 名占读入 {top5 / get('read') * 100:.0f}%{RESET}"
    out.append(head)

    if not turns:
        out.append("")
        out.append(f"{DIM}这个窗口里没有记录到任何一轮对话。{RESET}")
        return "\n".join(out)

    out.append(f"  {pad('轮数', 10)}{pad(f'{turns:,}', 9, right=True)}"
               f"   {DIM}平均每轮上下文 {fmt_tok(incoming // turns)}{RESET}")
    # Bar sized to what's left after the two number columns and the
    # percentage — a fixed 22 cells overflowed the list side of a
    # 100-column terminal and fzf clipped the bars mid-fill.
    cells = min(BAR_W, max(6, width - 31))
    for name, n in (("缓存读取", get("read")), ("缓存写入", get("create")),
                    ("输出", get("output")), ("新输入", get("input"))):
        share = n / grand if grand else 0
        out.append(f"  {pad(name, 10)}{pad(fmt_tok(n), 9, right=True)}   "
                   f"{bar(share, cells)} {DIM}{share * 100:4.1f}%{RESET}")
    return "\n".join(out)


def row_widths(width):
    """Name and project columns, from whatever is left after the numbers.

    The numbers are the point of the table and their widths are fixed, so
    the two text columns absorb every bit of narrowness — down to a list
    side of ~46 columns, which is what a 50% preview leaves on a 100-column
    terminal."""
    rest = max(14, width - 30)
    name_w = min(28, max(8, rest * 2 // 3))
    # Both columns are capped: past this the numbers drift so far right that
    # the eye loses which row they belong to, and a full-width terminal
    # reading the static report has no more to say with the space than a
    # 50%-preview picker does.
    return name_w, min(22, max(6, rest - name_w - 1))


def rank_header(width):
    """The column head, printed as the last line of the fzf header so it
    stays pinned above the rows. Its left offset has to match the rows'
    exactly — three columns for the rank, one for the status glyph."""
    name_w, proj_w = row_widths(width)
    return (f"{DIM} {pad('#', 3, right=True)}   {pad('会话', name_w)} "
            f"{pad('项目', proj_w)} {pad('轮数', 5, right=True)} "
            f"{pad('读入', 6, right=True)} {pad('均/轮', 6, right=True)}{RESET}")


def render_rows(data, width, tag=""):
    """The ranking, one fzf row per session.

    Tab-separated: field 1 is what you see, field 2 is the session id the
    preview needs, field 3 is `tag` — the cache file this list was built
    from, so the preview and the refresh key can find it without the page
    having to keep the current window in a state file — and field 4 is the
    pane to jump to, empty for a session that is no longer open anywhere.
    Every session in the window gets a row: the list scrolls, so the old
    "还有 N 个会话未显示" footnote has nothing left to say."""
    name_w, proj_w = row_widths(width)
    m = sd()
    try:
        with open(STATUS_FILE) as f:
            status = json.load(f)
    except Exception:                                          # noqa: BLE001
        status = {}
    # Status glyph, not a word: "is this one still burning" is the reason
    # you are looking at the list, and the ranking has no room for a
    # column. The vocabulary is label_of's, one letter of it.
    glyph = {-1: f"{DIM}⏸{RESET}", 0: f"{DIM}·{RESET}", 1: "\033[32m✔\033[0m",
             2: f"{YELLOW}▶{RESET}", 3: f"{DIM}·{RESET}"}

    out = []
    for i, s in enumerate(data["sessions"], 1):
        e = status.get(s.get("pane") or "")
        mark = " "
        if e and not e.get("archived"):
            mark = glyph.get(m.label_of(e)[1], " ")
        avg = s["ctx"] // s["turns"] if s["turns"] else 0
        # Padded by hand rather than through pad(): a name that came from
        # the opening prompt is wrapped in DIM, and the escape codes would
        # otherwise be counted as width.
        text = clip(s["name"].replace("\t", " "), name_w)
        gap = " " * max(0, name_w - vwidth(text))
        name = (DIM + text + RESET if s.get("from_prompt") else text) + gap
        disp = (f" {pad(str(i), 3, right=True)} {mark} {name} "
                f"{DIM}{pad(clip(s['proj'] or '?', proj_w), proj_w)}{RESET} "
                f"{pad('{:,}'.format(s['turns']), 5, right=True)} "
                f"{pad(fmt_tok(s['read']), 6, right=True)} "
                f"{YELLOW}{pad(fmt_tok(avg), 6, right=True)}{RESET}")
        pane = s.get("pane") or ""
        if not (e and not e.get("archived")):
            # Archived, or never seen by the hooks: the pane id in the cache
            # may still be live but it is not this session's any more, and
            # Enter must not send you somewhere else's screen.
            pane = ""
        out.append(f"{disp}\t{s['sid']}\t{tag}\t{pane}")
    return "\n".join(out)


def render_detail(data, sid, width, lines):
    """One session's card, for the preview window: who it is, what it was
    asked to do, where its tokens went — and, when it is still open in a
    pane, its live screen underneath.

    The screen goes *last* here, the opposite of preview-row.sh, because
    this preview is not a screen dump with a footnote: the numbers are what
    the page is for, and they are what must survive a short window. The
    capture is trimmed to what is actually left over rather than relying on
    fzf's `follow`."""
    s = next((x for x in data["sessions"] if x["sid"] == sid), None)
    if s is None:
        return ""
    m = sd()
    w = max(30, width - 2)
    out = []

    try:
        with open(STATUS_FILE) as f:
            status = json.load(f)
    except Exception:                                          # noqa: BLE001
        status = {}
    e = status.get(s.get("pane") or "")
    if e and not e.get("archived"):
        label, rank = m.label_of(e)
        age = m.fmt_age(rank, int(time.time() - e.get("updated_at", time.time())))
    else:
        label, age = f"{DIM}——{RESET}", "已经不在 tmux 里了"

    # A name that came from the opening prompt is not a name, and the card
    # has the room to say so — the ❯ line right below carries the prompt in
    # full, so repeating it here as a title would only be the same sentence
    # twice, once truncated.
    title = "未命名会话" if s.get("from_prompt") else clip(s["name"], w - 22)
    out.append(f"{BOLD}{title}{RESET}  {label} {DIM}{age}{RESET}")
    where = " · ".join(x for x in (s.get("where"), s.get("pane"), s["sid"][:8]) if x)
    out.append(f"{DIM}{clip(where, w)}{RESET}")
    out.append(f"{DIM}{clip(s.get('cwd') or '', w)}{RESET}")

    model, ctx, recap, task = m.transcript_info({}, path=s["path"])
    if task:
        out.append(f"{CYAN}❯{RESET} {clip(task, w - 2)}")

    out.append(f"{DIM}{'─' * w}{RESET}")
    avg = s["ctx"] // s["turns"] if s["turns"] else 0
    bits = [f"轮数 {s['turns']:,}", f"{YELLOW}均/轮 {fmt_tok(avg)}{RESET}",
            f"峰值 {fmt_tok(s['peak'])}"]
    if model:
        bits.append(model.replace("claude-", ""))
    if s.get("last"):
        bits.append(time.strftime("%m-%d %H:%M", time.localtime(_local_of(s["last"]))))
    out.append(clip(" · ".join(bits), w + 20))

    grand = s["read"] + s["create"] + s["output"] + s["input"]
    for name, n in (("缓存读取", s["read"]), ("缓存写入", s["create"]),
                    ("输出", s["output"]), ("新输入", s["input"])):
        share = n / grand if grand else 0
        out.append(f"{pad(name, 10)}{pad(fmt_tok(n), 8, right=True)}  "
                   f"{bar(share, min(BAR_W, w - 26))} {DIM}{share * 100:4.1f}%{RESET}")

    by_day = s.get("by_day") or []
    if len(by_day) > 1:
        labels = data.get("day_labels") or []
        out.append(f"{pad('分天', 10)}{CYAN}{spark(by_day)}{RESET}  "
                   f"{DIM}{labels[0] if labels else ''} → "
                   f"{labels[-1] if labels else ''} · 按每轮上下文{RESET}")

    total_read = data["totals"].get("read", 0)
    if total_read:
        out.append(f"{DIM}占窗口读入量 {s['read'] / total_read * 100:.1f}%{RESET}")

    # Whatever depth is left goes to the live screen — or, for a session
    # that has already closed, to the tail of its last reply, which is the
    # nearest thing to "what came of it".
    room = max(0, lines - len(out) - 2)
    if room >= 3:
        out.append(f"{DIM}{'─' * w}{RESET}")
        if e and not e.get("archived") and s.get("pane"):
            try:
                cap = subprocess.check_output(
                    ["tmux", "capture-pane", "-p", "-e", "-S", f"-{room}",
                     "-t", s["pane"]], text=True, stderr=subprocess.DEVNULL)
                # `-S -N` starts N lines above the *visible screen*, so it
                # returns N + pane height lines — a 30-row budget came back
                # as 75 and pushed the card that this page is actually for
                # off the top. The tail is the part worth keeping.
                out.extend(cap.rstrip("\n").split("\n")[-room:])
            except Exception:                                  # noqa: BLE001
                out.append(f"{DIM}(pane 已关闭或无法读取){RESET}")
        elif recap:
            for ln in m.wrap(recap, w - 2, room):
                out.append(f"{DIM}▎{RESET} {ln}")
        else:
            out.append(f"{DIM}(没有留下回复内容){RESET}")
    return "\n".join(out)


def render_static(data, top_n, width):
    """The whole report as plain text, for reading it outside the picker."""
    out = [render_overview(data, width), ""]
    if not data["turns"]:
        return "\n".join(out)
    ranked = data["sessions"]
    out.append(f"{BOLD}会话排行{RESET} {DIM}· 按读入量{RESET}")
    out.append(rank_header(width))
    out.extend(render_rows({**data, "sessions": ranked[:top_n]}, width)
               .split("\n"))
    out = [ln.split("\t")[0] for ln in out]
    tail = len(ranked) - min(top_n, len(ranked))
    out.append("")
    if tail > 0:
        out.append(f"{DIM}  还有 {tail} 个会话未显示{RESET}")
    out.append(f"{DIM}  ~98% 的 token 是重读已有上下文,所以「均/轮」比轮数更能解释谁贵。{RESET}")
    return "\n".join(out)


def main(argv):
    days, top_n, width, lines = 1, 12, 100, 40
    cache, force, mode, sid, tag = "", False, "", "", ""
    days_given = False
    i = 1
    while i < len(argv):
        a = argv[i]
        if a == "--days" and i + 1 < len(argv):
            days = int(argv[i + 1]); days_given = True; i += 2
        elif a == "--top" and i + 1 < len(argv):
            top_n = int(argv[i + 1]); i += 2
        elif a == "--width" and i + 1 < len(argv):
            width = int(argv[i + 1]); i += 2
        elif a == "--lines" and i + 1 < len(argv):
            lines = int(argv[i + 1]); i += 2
        elif a == "--cache" and i + 1 < len(argv):
            cache = argv[i + 1]; i += 2
        elif a == "--tag" and i + 1 < len(argv):
            tag = argv[i + 1]; i += 2
        elif a == "--detail" and i + 1 < len(argv):
            mode, sid = "detail", argv[i + 1]; i += 2
        elif a in ("--scan", "--overview", "--rows", "--header"):
            mode = a.lstrip("-").replace("header", "overview"); i += 1
        elif a == "--force":
            force = True; i += 1
        else:
            i += 1

    # Renders read the cache and never scan on their own: a missing cache
    # means the page's own `--scan` hasn't finished, and quietly scanning
    # here would put the cost back on the keypress this split exists to
    # make cheap.
    if mode in ("detail", "rows", "overview") and cache:
        try:
            data = load(cache)
        except Exception:                                      # noqa: BLE001
            return 0
    else:
        data = ensure(cache, days, force, days_given)

    if mode == "scan":
        return 0
    if mode == "overview":
        print(render_overview(data, width))
        if data["sessions"]:
            print(rank_header(width))
    elif mode == "rows":
        rows = render_rows(data, width, tag or cache)
        if rows:
            print(rows)
    elif mode == "detail":
        text = render_detail(data, sid, width, lines)
        if text:
            print(text)
    else:
        print(render_static(data, top_n, width))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
