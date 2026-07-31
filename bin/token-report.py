#!/usr/bin/env python3
"""Where the tokens went: a one-screen token report built from the local
transcripts, no API calls.

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

usage: token-report.py [--days N] [--top N] [--width N]
       --days 1 (default) = since local midnight; 7 = the last 7 days
"""
import glob
import json
import os
import sys
import time
import unicodedata
from collections import defaultdict

PROJECTS_DIR = os.path.expanduser("~/.claude/projects")
HOME = os.path.expanduser("~")

RESET = "\033[0m"
DIM = "\033[2m"
BOLD = "\033[1m"
CYAN = "\033[36m"
YELLOW = "\033[33m"

BAR_W = 22


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


def window_start(days):
    """Local midnight, days-1 days back — 'the last 7 days' means today
    plus the six before it, not a rolling 168 hours; a day boundary is
    what people compare against."""
    lt = time.localtime()
    midnight = time.mktime((lt.tm_year, lt.tm_mon, lt.tm_mday, 0, 0, 0, 0, 0, -1))
    return midnight - (max(1, days) - 1) * 86400


def collect(days):
    start = window_start(days)
    # Timestamps in the transcript are UTC ISO ("...Z"), so the cutoff is
    # compared as a string against the same encoding of local midnight —
    # lexical order on a fixed-width ISO stamp is chronological order, and
    # it saves parsing a datetime per line.
    cutoff = time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(start))

    totals = defaultdict(int)
    turns = 0
    sessions = defaultdict(lambda: {"turns": 0, "read": 0, "ctx": 0, "peak": 0, "proj": ""})
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
                if (obj.get("timestamp") or "") < cutoff:
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
                s = sessions[sid]
                s["turns"] += 1
                s["read"] += read
                s["ctx"] += ctx
                s["peak"] = max(s["peak"], ctx)
                # Last cwd seen, not the first: a long session can move
                # between directories, and taking the first one made the
                # same session show a different project in the 1-day and
                # 7-day views. The most recent is also the more useful
                # answer to "what is this one working on".
                cwd = (obj.get("cwd") or "").rstrip("/")
                if cwd:
                    s["proj"] = "~" if cwd == HOME else (os.path.basename(cwd) or cwd)

    return {"turns": turns, "totals": totals, "sessions": sessions, "files": files,
            "start": start}


def render(days, top_n, width):
    data = collect(days)
    totals, turns = data["totals"], data["turns"]
    incoming = totals["input"] + totals["read"] + totals["create"]
    grand = incoming + totals["output"]

    label = "今日" if days <= 1 else f"近 {days} 天"
    span = time.strftime("%m-%d", time.localtime(data["start"]))
    today = time.strftime("%m-%d")
    span = today if days <= 1 else f"{span} → {today}"

    out = []
    out.append(f"{BOLD}{label} token 消耗{RESET}   {DIM}{span} · "
               f"{data['files']} 个 transcript · {len(data['sessions'])} 个会话{RESET}")
    out.append("")

    if not turns:
        out.append(f"{DIM}这个窗口里没有记录到任何一轮对话。{RESET}")
        return "\n".join(out)

    rows = [
        ("缓存读取", totals["read"]),
        ("缓存写入", totals["create"]),
        ("输出", totals["output"]),
        ("新输入", totals["input"]),
    ]
    out.append(f"  {pad('轮数', 10)}{pad(f'{turns:,}', 9, right=True)}"
               f"   {DIM}平均每轮上下文 {fmt_tok(incoming // turns)}{RESET}")
    for name, n in rows:
        share = n / grand if grand else 0
        out.append(f"  {pad(name, 10)}{pad(fmt_tok(n), 9, right=True)}   "
                   f"{bar(share)} {DIM}{share * 100:4.1f}%{RESET}")
    out.append("")

    # The ranking. Sorted by tokens read in, not by turns — see the module
    # docstring for why those disagree.
    ranked = sorted(data["sessions"].items(), key=lambda kv: -kv[1]["read"])
    shown = ranked[:top_n]

    name_w = max(0, min(22, width - 62))
    head = (f"  {pad('#', 3, right=True)}  {pad('会话', 8)}  {pad('项目', name_w)}"
            f"  {pad('轮数', 6, right=True)}  {pad('读入', 7, right=True)}"
            f"  {pad('均/轮', 7, right=True)}  {pad('峰值', 7, right=True)}")
    out.append(f"{BOLD}会话排行{RESET} {DIM}· 按读入量{RESET}")
    out.append(f"{DIM}{head}{RESET}")
    for i, (sid, s) in enumerate(shown, 1):
        avg = s["ctx"] // s["turns"] if s["turns"] else 0
        n_turns = "{:,}".format(s["turns"])
        out.append(
            f"  {pad(str(i), 3, right=True)}  {DIM}{sid[:8]}{RESET}  "
            f"{pad(clip(s['proj'] or '?', name_w), name_w)}  "
            f"{pad(n_turns, 6, right=True)}  "
            f"{pad(fmt_tok(s['read']), 7, right=True)}  "
            f"{YELLOW}{pad(fmt_tok(avg), 7, right=True)}{RESET}  "
            f"{pad(fmt_tok(s['peak']), 7, right=True)}"
        )

    top5 = sum(s["read"] for _, s in ranked[:5])
    tail = len(ranked) - len(shown)
    note = f"前 5 名占读入量 {top5 / totals['read'] * 100:.0f}%" if totals["read"] else ""
    if tail > 0:
        note += f" · 还有 {tail} 个会话未显示"
    out.append("")
    out.append(f"{DIM}  {note}{RESET}")
    out.append(f"{DIM}  ~98% 的 token 是重读已有上下文,所以「均/轮」比轮数更能解释谁贵。{RESET}")
    return "\n".join(out)


def main(argv):
    days, top_n, width = 1, 12, 100
    i = 1
    while i < len(argv):
        a = argv[i]
        if a == "--days" and i + 1 < len(argv):
            days = int(argv[i + 1]); i += 2
        elif a == "--top" and i + 1 < len(argv):
            top_n = int(argv[i + 1]); i += 2
        elif a == "--width" and i + 1 < len(argv):
            width = int(argv[i + 1]); i += 2
        else:
            i += 1
    print(render(days, top_n, width))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
