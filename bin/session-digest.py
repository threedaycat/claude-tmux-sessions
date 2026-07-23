#!/usr/bin/env python3
"""Session-header preview: one compact card per tracked Claude pane in the
session, instead of raw screen dumps — title (name/status/age), a meta
line (model, context size, cwd) read from the pane's Claude Code
transcript, and a short recap: the tail of Claude's last text reply.

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


def transcript_info(entry):
    """(model, context_tokens, recap_text) from the pane's transcript, or
    (None, None, None) if it can't be found/parsed."""
    sid, cwd = entry.get("session_id"), entry.get("cwd")
    if not sid or not cwd:
        return None, None, None
    path = os.path.join(PROJECTS_DIR, cwd.replace("/", "-"), sid + ".jsonl")
    try:
        with open(path, "rb") as f:
            f.seek(0, 2)
            size = f.tell()
            f.seek(max(0, size - 400_000))
            lines = f.read().decode("utf-8", "replace").splitlines()
    except OSError:
        return None, None, None

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
        texts = [c.get("text", "") for c in m.get("content", []) if c.get("type") == "text"]
        if texts and texts[-1].strip():
            recap = texts[-1].strip()
            break
    return model, ctx, recap


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


def main():
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
    # per card: separator + title + meta = 3 lines of overhead
    recap_lines = max(2, min(6, avail // len(cards) - 3))

    first = True
    for _rank, _neg, pane, label, e in cards:
        if not first:
            print(DIM + "╌" * width + RESET)
        first = False

        age = int(now - e.get("updated_at", now))
        title = f"{label}  {BOLD}{clip(win_of[pane], width - 18)}{RESET}  {DIM}{age}s前{RESET}"
        print(title)

        model, ctx, recap = transcript_info(e)
        meta = []
        if model:
            meta.append(model.replace("claude-", ""))
        if ctx:
            meta.append(f"ctx {ctx / 1000:.0f}k")
        meta.append(e.get("cwd") or "")
        print(DIM + clip(" · ".join(m for m in meta if m), width) + RESET)

        if recap:
            for ln in wrap(recap, width - 2, recap_lines):
                print("  " + ln)
        else:
            print(DIM + "  (还没有回复内容)" + RESET)


if __name__ == "__main__":
    main()
