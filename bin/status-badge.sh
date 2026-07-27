#!/usr/bin/env bash
# Ambient tmux status-bar segment, wired into status-right via #(...):
# a compact 5-hour-quota readout (how much you have left and when it
# resets) followed by aggregate counts across ALL tracked panes — the
# whole state at a glance from any session/window, without opening the
# picker or relying on a macOS notification.
set -euo pipefail

STATUS_FILE="$HOME/.claude/tmux-claude-status.json"

# Clean out stale entries (dead pane / Claude exited) before counting —
# but only if there's a file to clean; the quota half still shows when no
# Claude pane is tracked at all.
SCRIPT_PATH="${BASH_SOURCE[0]}"
[ -L "$SCRIPT_PATH" ] && SCRIPT_PATH="$(readlink "$SCRIPT_PATH")"
BIN_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
if [ -s "$STATUS_FILE" ]; then
  python3 "$BIN_DIR/../hooks/tmux_status_update.py" prune 2>/dev/null || true
fi

python3 - "$STATUS_FILE" <<'PYEOF'
import json, os, sys, subprocess, time, unicodedata
from datetime import datetime

status_file = sys.argv[1]
try:
    with open(status_file) as f:
        data = json.load(f)
except Exception:
    data = {}          # no tracked panes yet — quota half still renders

# Live pane -> window name, so the banner can name the blocked window and
# do it from tmux's current truth (a rename after the status was recorded
# still shows correctly), same as the picker does.
try:
    out = subprocess.check_output(
        ["tmux", "list-panes", "-a", "-F", "#{pane_id}\t#{window_name}"], text=True)
except Exception:
    out = ""
win_of = {}
for line in out.splitlines():
    p = line.split("\t")
    if len(p) == 2:
        win_of[p[0]] = p[1]
live = set(win_of)


def fmt_dur(secs):
    secs = max(0, int(secs))
    if secs < 60:
        return f"{secs}秒"
    if secs < 3600:
        return f"{secs // 60}分钟"
    return f"{secs / 3600:.1f}".rstrip("0").rstrip(".") + "小时"


def clip(s, width=22):
    w, out = 0, ""
    for ch in s:
        cw = 2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1
        if w + cw > width:
            return out + "…"
        out += ch
        w += cw
    return out


# Idle panes older than this have clearly been abandoned (Claude finished
# ages ago and you never came back), so they age out of the ambient bar
# instead of piling up forever — you can still find them, dimmed, in the
# picker. Overridable via env for a tighter/looser window.
IDLE_STALE = int(os.environ.get("CLAUDE_TMUX_IDLE_STALE_SECS", "7200"))  # 2h

now = time.time()
blocked = []            # (elapsed_secs, window_name) for blocked-and-unread
idle = done_unread = running = read = 0
for pane, e in data.items():
    if pane not in live or e.get("archived"):
        continue
    status = e.get("status", "running")
    age = int(now - e.get("updated_at", now))
    # blocked respects `read` too: jumping to a blocked pane (prefix W /
    # the picker, both call mark-read) is how you dismiss its alert, so an
    # already-visited one shouldn't keep sounding the banner. A fresh
    # permission prompt overwrites the entry and clears read, re-alerting.
    if status == "blocked" and not e.get("read"):
        blocked.append((age, win_of.get(pane) or e.get("window_name") or pane))
    elif status in ("done", "input") and e.get("read"):
        read += 1                       # already visited once — quiet
    elif status == "input":
        if age < IDLE_STALE:
            idle += 1                   # fresh idle — still worth a glance
        # else: aged out — dropped from the bar entirely
    elif status == "done":
        done_unread += 1
    elif status == "running":
        running += 1


# Our own snapshot of the last live 5h reading. Claude Code's
# cachedUsageUtilization is account-scoped and it *wipes* the field the
# moment an instance on another account touches ~/.claude.json — so with
# claude-use l1/l2 alternating, the cache keeps vanishing. We mirror the
# last good reading here so the bar survives those wipes.
QUOTA_CACHE = os.path.expanduser("~/.claude/tmux-quota-cache.json")


def quota_bar(pct, colour, empty="#585858"):
    """10-cell bar filled with the amount *used* (▓ grows as consumed —
    same direction as /usage, the picker footer and the context meters)."""
    cells = 10
    fill = max(0, min(cells, round(pct / 100 * cells)))
    return (
        f"#[fg={colour}]{'▓' * fill}#[default]"
        f"#[fg={empty}]{'░' * (cells - fill)}#[default]"
    )


def quota_colour(pct):
    """The bar deepens as the 5h window fills — green (plenty left) →
    chartreuse → gold → orange → red (nearly spent) — so how close you are
    to the cap reads straight off the colour, no number needed."""
    if pct >= 90:
        return "#ff0000"   # nearly/at the cap — loud red
    if pct >= 75:
        return "#ff8700"   # orange
    if pct >= 55:
        return "#ffd700"   # gold
    if pct >= 35:
        return "#afd700"   # chartreuse
    return "#5fff00"       # green — lots of headroom


def reset_suffix(resets_at):
    """(rendered ↻HH:MM suffix, parsed datetime) for a resets_at ISO
    string; ('', None) if it can't be parsed."""
    try:
        dt = datetime.fromisoformat(resets_at).astimezone()
    except Exception:
        return "", None
    fmt = "%H:%M" if dt.date() == datetime.now().astimezone().date() else "%m-%d %H:%M"
    return f" #[fg=#8a8a8a]↻{dt.strftime(fmt)}#[default]", dt


def quota_segment():
    """A compact 5-hour-window readout: how much of the window you've used
    and when it resets. Primary source is Claude Code's own cache
    (cachedUsageUtilization in ~/.claude.json). When that's present we use
    it and snapshot it; when it's been wiped (see QUOTA_CACHE) we fall back
    to the snapshot, shown muted with a ~ 'last known' marker, until fresh
    data returns — so the segment never just blinks out. A full window
    still shows a full red bar; only a genuinely empty data source falls
    through to the quiet placeholder."""
    live = None
    try:
        cfg = json.load(open(os.path.expanduser("~/.claude.json")))
        fh = (((cfg.get("cachedUsageUtilization") or {}).get("utilization") or {})
              .get("five_hour")) or {}
        pct = fh.get("utilization")
        if pct is not None:
            live = {"pct": float(pct), "resets_at": fh.get("resets_at")}
    except Exception:
        live = None

    if live is not None:
        # Mirror it for the next wipe. Atomic replace (unique tmp + rename)
        # so concurrent renders on multiple attached clients never tear it.
        try:
            tmp = f"{QUOTA_CACHE}.{os.getpid()}.tmp"
            with open(tmp, "w") as f:
                json.dump(live, f)
            os.replace(tmp, QUOTA_CACHE)
        except Exception:
            pass
        pct = live["pct"]
        colour = quota_colour(pct)
        reset, _ = reset_suffix(live.get("resets_at") or "")
        return (f"#[fg=#8a8a8a]5h#[default] {quota_bar(pct, colour)} "
                f"#[fg={colour}]{int(round(pct))}%#[default]{reset}")

    # No live data — fall back to our snapshot if the window it belongs to
    # hasn't rolled over yet (a past resets_at means the cached % is stale).
    try:
        snap = json.load(open(QUOTA_CACHE))
    except Exception:
        snap = None
    if snap and snap.get("pct") is not None:
        reset, dt = reset_suffix(snap.get("resets_at") or "")
        if dt is None or dt > datetime.now().astimezone():
            pct = float(snap["pct"])
            # Muted grey bar + ~ marker: last known reading, not live.
            return (f"#[fg=#585858]5h#[default] {quota_bar(pct, '#8a8a8a')} "
                    f"#[fg=#8a8a8a]~{int(round(pct))}%#[default]{reset}")

    # Nothing usable — a quiet placeholder so the segment doesn't vanish;
    # it refills once the active account fetches usage again (/usage).
    return "#[fg=#585858]5h ░░░░░░░░░░ ?#[default]"


# A blocked pane is the one thing that actually stalls you, so it gets a
# loud, persistent segment (badge style: a white-on-red WAIT chip, the
# window's name, and how long it's been waiting) that re-renders every
# status refresh until you go deal with it — that's the "don't vanish on
# its own" a passing display-message couldn't give. Everything else stays
# a quiet theme-coloured dot. tmux honours #[...] style directives inside
# #() output; #[default] restores the status-right style after.
parts = []
q = quota_segment()
if q:
    parts.append(q)
if blocked:
    blocked.sort(reverse=True)          # longest-waiting named first
    age, name = blocked[0]
    n = len(blocked)
    chip = f"#[fg=#e4e4e4,bg=#d70000,bold] WAIT{f' {n}' if n > 1 else ''} #[default]"
    label = clip(name) + (f" +{n - 1}" if n > 1 else "")
    parts.append(
        f"{chip} #[fg=#e4e4e4]{label}#[default]  #[fg=#8a8a8a]{fmt_dur(age)}#[default]"
    )
# Dots left-to-right in the picker's own priority order — most important
# first, so you only ever have to read the left of the segment and can
# ignore whatever's to the right: idle (magenta, waiting on you to reply),
# done-unread (green, finished — a result to look at), running (yellow,
# Claude's busy, nothing to do), read (blue, already seen — quietest).
# The blocked WAIT chip above outranks them all and leads the segment.
# Same colours as the picker's labels, so the whole state matches it.
if idle:
    parts.append(f"#[fg=#ff00af]● {idle}")
if done_unread:
    parts.append(f"#[fg=#5fff00]● {done_unread}")
if running:
    parts.append(f"#[fg=#ffff00]● {running}")
if read:
    parts.append(f"#[fg=#00afff]● {read}")

if parts:
    print("  ".join(parts) + "#[default] ")
PYEOF
