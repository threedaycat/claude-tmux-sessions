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
import json
import os
import subprocess
import sys
import time
import unicodedata

STATUS_FILE = os.path.expanduser("~/.claude/tmux-claude-status.json")
PROJECTS_DIR = os.path.expanduser("~/.claude/projects")

RESET = "\033[0m"
DIM = "\033[2m"
BOLD = "\033[1m"


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


def pane_bar(pane):
    """--pane mode: one Claude-Code-statusline-style line for a single
    tracked pane, printed above the live screen dump in the pane preview
    — status · model · context size (± % of the window) · status-aware elapsed
    time · cwd, then a dim rule."""
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

    bits = []
    if model:
        bits.append(model.replace("claude-", ""))
    cb = ctx_bar(model, ctx)
    if cb:
        bits.append(cb)
    bits.append(fmt_age(rank, age))

    width = max(30, int(os.environ.get("FZF_PREVIEW_COLUMNS", 80)) - 2)
    cwd = e.get("cwd") or ""
    line = f"{label}  " + " · ".join(bits) + f"  {DIM}{clip(cwd, width)}{RESET}"
    print(line)
    print(DIM + "─" * width + RESET)


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
            ["tmux", "list-panes", "-a", "-F", "#{pane_id}\t#{session_name}\t#{window_name}"],
            text=True, stderr=subprocess.DEVNULL,
        )
    except Exception:
        return
    win_of = {}
    for line in out.splitlines():
        parts = line.split("\t")
        if len(parts) == 3 and parts[1] == session:
            win_of[parts[0]] = parts[2]

    now = time.time()
    cards = []
    for pane, e in data.items():
        if pane not in win_of or e.get("archived"):
            continue
        label, rank = label_of(e)
        cards.append((rank, -e.get("updated_at", 0), pane, label, e))
    cards.sort()
    if not cards:
        return

    width = max(30, int(os.environ.get("FZF_PREVIEW_COLUMNS", 80)) - 2)
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
        title = f"{label}  {BOLD}{clip(win_of[pane], width - 18)}{RESET}  {DIM}{fmt_age(_rank, age)}{RESET}"
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
