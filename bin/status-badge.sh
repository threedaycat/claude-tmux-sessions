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
#
# prune also refreshes the per-window badges (@claude_win), which makes this
# their heartbeat — hooks flip them the instant a state changes, this catches
# what no hook fires for (an unread DONE ageing out, a pane killed without
# SessionEnd). With no status file at all there's nothing to prune but there
# may still be badges left over from before it was emptied, so sync alone.
#
# One argument picks which half to print, so the two can sit in different
# places on the bar (e.g. Claude states next to the session name on the
# left, quota at the far right):
#   status-badge.sh           both (quota first), as before
#   status-badge.sh states    WAIT / ✔ / ▶ only
#   status-badge.sh quota     5h / 7d only — skips the prune, so running
#                             both halves doesn't prune twice per refresh
MODE="${1:-all}"
if [ "$MODE" != quota ]; then
  if [ -s "$STATUS_FILE" ]; then
    python3 "$BIN_DIR/../hooks/tmux_status_update.py" prune 2>/dev/null || true
  else
    python3 "$BIN_DIR/../hooks/tmux_status_update.py" sync-windows 2>/dev/null || true
  fi
fi

MODE="$MODE" BIN_DIR="$BIN_DIR" python3 - "$STATUS_FILE" <<'PYEOF'
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

# 队员的窗格不进这几个计数。状态栏只说主 Claude —— team leader 和没有编队的普通 Claude
# （用户 2026-09-29：「我们只展示那些 team leader 的，不要展示 teammates 的」）。
# 队员是 lead 派出去的手，它们跑完、在跑、被看过，都不是「有件事在等你」；
# 而且一个队一开就是四五个，计数会被它们整个淹掉。队员的状态在 picker 里 lead 那一行上
# 单独有一格（list-rows.sh 的 mate_cell）。
#
# 门槛和 list-rows.sh 那边一样：没开过 Agent Teams 的人连 import 都不会发生，
# 这个文件对他们一个字节的开销都不加。读不出来就当没有队员，计数退回原样 ——
# 编队读坏了不该让状态栏变空。
mate_panes = set()
_claude_home = os.environ.get("CLAUDE_HOME") or os.path.expanduser("~/.claude")
if os.environ.get("BIN_DIR") and os.path.isdir(os.path.join(_claude_home, "teams")):
    try:
        sys.path.insert(0, os.environ["BIN_DIR"])
        import agent_teams
        _snap = agent_teams.snapshot()
        if _snap:
            mate_panes = {m["pane"] for m in _snap["by_pane"].values()
                          if m.get("is_mate") and m.get("pane")}
    except Exception:
        mate_panes = set()

now = time.time()
blocked = []            # (elapsed_secs, window_name, pane_id) for blocked-and-unread
done_unread = running = read_count = 0
for pane, e in data.items():
    if pane not in live or e.get("archived") or pane in mate_panes:
        continue
    status = e.get("status", "running")
    age = int(now - e.get("updated_at", now))
    # blocked respects `read` too: jumping to a blocked pane (prefix a /
    # the picker, both call mark-read) is how you dismiss its alert, so an
    # already-visited one shouldn't keep sounding the banner. A fresh
    # permission prompt overwrites the entry and clears read, re-alerting.
    if status == "blocked" and not e.get("read"):
        blocked.append((age, win_of.get(pane) or e.get("window_name") or pane, pane))
    elif status in ("done", "input") and e.get("read"):
        read_count += 1                 # already seen — quiet, but you do go back to these
    elif status in ("done", "input"):
        # "done" (Stop hook) and "input" (idle, waiting on your next
        # message) both mean "Claude finished, unread" — one DONE count.
        if age < IDLE_STALE:
            done_unread += 1            # a result worth a look
        # else: aged out — dropped from the bar entirely
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


LIVE_FILE = os.path.expanduser("~/.claude/tmux-usage-live.json")
REFRESH = os.path.join(os.environ.get("BIN_DIR", ""), "usage-refresh.py")


def usage_now():
    """The freshest usage reading we have, as {window: {utilization,
    resets_at}} plus fetched_at_ms. Two sources, newest wins:
      - Claude Code's own cache (cachedUsageUtilization in ~/.claude.json),
        updated whenever Claude Code fetches — e.g. when you run /usage;
      - usage-refresh.py's LIVE_FILE, updated every 30 min in the background
        and on a click on the quota segment.
    The older QUOTA_CACHE snapshot (5h only) is the last resort, for when
    both are gone."""
    best = None
    try:
        cached = json.load(open(os.path.expanduser("~/.claude.json"))).get("cachedUsageUtilization") or {}
        util = cached.get("utilization") or {}
        if (util.get("five_hour") or {}).get("utilization") is not None:
            best = {"five_hour": util.get("five_hour"), "seven_day": util.get("seven_day") or {},
                    "fetched_at_ms": cached.get("fetchedAtMs") or 0}
    except Exception:
        pass
    try:
        live = json.load(open(LIVE_FILE))
        if (live.get("five_hour") or {}).get("utilization") is not None and \
                (best is None or (live.get("fetched_at_ms") or 0) > best["fetched_at_ms"]):
            best = live
    except Exception:
        pass
    if best is None:
        try:
            snap = json.load(open(QUOTA_CACHE))
            if snap.get("pct") is not None:
                best = {"five_hour": {"utilization": snap["pct"], "resets_at": snap.get("resets_at")},
                        "seven_day": {}, "fetched_at_ms": 0}
        except Exception:
            pass
    return best


def maybe_refresh(best):
    """Kick usage-refresh.py in the background when the newest reading is
    older than its interval. It throttles itself (attempts count too), so
    calling this on every 10s status render costs one stat, not a request."""
    interval = 60 * int(os.environ.get("CLAUDE_TMUX_USAGE_REFRESH_MIN") or 30)
    age = time.time() - ((best or {}).get("fetched_at_ms") or 0) / 1000
    if age > interval and os.path.exists(REFRESH):
        try:
            subprocess.Popen([sys.executable, REFRESH], stdin=subprocess.DEVNULL,
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                             start_new_session=True)
        except Exception:
            pass


GAUGE = "▁▂▃▄▅▆▇█"
# 离重置还有多久，画成和用量柱**同方向**的一根柱子：窗口里**已经过去**的那部分从下往上
# 长成深蓝，刚开窗是 ▁，快重置时是 █。
#
# 两根柱子必须同向、同画法（同一个 level()、都不带背景色），高度才能直接比：
# 用量柱高过时间柱 = 烧得比「匀速用到重置」快；矮于它 = 还有富余。
# 2026-09-29 之前这格是反的（灰色的「还要等」从下往上、深蓝从上往下填），
# 一上一下没法比 —— 用户原话：「我没有办法去比较我的平均用量是否已经超过了限额刷新时间」。
WINDOW_SECS = {"5h": 5 * 3600, "7d": 7 * 86400}
TIME_DONE = "#0087d7"       # 深蓝：窗口里已经过去的部分，从下往上长


def level(frac, n):
    """Nearest of n glyph heights, where glyph i draws (i+1)/n."""
    return max(0, min(n - 1, round(frac * n) - 1))


def time_left_glyph(label, dt):
    if dt is None:
        return ""
    left = (dt - datetime.now().astimezone()).total_seconds()
    waiting = max(0.0, min(1.0, left / WINDOW_SECS.get(label, 5 * 3600)))
    elapsed = 1.0 - waiting                    # 窗口已经走过的比例
    # 和用量柱同一个 level()：两根一样高，就真的是「用掉的比例 = 走过的比例」。
    # 不带背景色，也和用量柱一致 —— 给一根加底色会让它看上去总是满格，没法比高度。
    return f"#[fg={TIME_DONE}]{GAUGE[level(elapsed, len(GAUGE))]}#[default]"


def window_segment(label, w, with_reset=False):
    """`5h▂▄`: a dim label, a block for how much is used (grows up, ▁ → █,
    coloured green → red), then a blue block for how much of the window has
    elapsed — same direction and same scale, so comparing the two heights
    tells you whether you're burning faster than the window refills (see
    time_left_glyph). No numbers in the bar — a click opens a card with them
    (usage-refresh.py --notify)."""
    pct = (w or {}).get("utilization")
    if pct is None:
        return f"#[fg=#585858]{label}·#[default]"
    pct = float(pct)
    g = GAUGE[level(pct / 100, len(GAUGE))]
    _, dt = reset_suffix((w or {}).get("resets_at") or "")
    if dt is not None and dt <= datetime.now().astimezone():
        # The window this reading belongs to has already rolled over.
        return f"#[fg=#585858]{label}{g}#[default]"
    return (f"#[fg=#6c6c6c]{label}#[fg={quota_colour(pct)}]{g}"
            f"{time_left_glyph(label, dt)}#[default]")


def quota_segment():
    """5h and 7d side by side (`5h 11%↻22:30 7d 5%`). Wrapped in a user range named `quota` so a mouse click on it can
    be told apart from a click on the window list (see the MouseDown1Status
    binding in the README) and trigger a refresh."""
    best = usage_now()
    maybe_refresh(best)
    if best is None:
        return "#[range=user|quota]#[fg=#585858]5h· 7d·#[default]#[norange]"
    if best.get("fetched_at_ms"):
        try:
            tmp = f"{QUOTA_CACHE}.{os.getpid()}.tmp"
            with open(tmp, "w") as f:
                json.dump({"pct": float(best["five_hour"]["utilization"]),
                           "resets_at": best["five_hour"].get("resets_at")}, f)
            os.replace(tmp, QUOTA_CACHE)
        except Exception:
            pass
    return ("#[range=user|quota]" + window_segment("5h", best.get("five_hour"))
            + " " + window_segment("7d", best.get("seven_day"))
            + refresh_state(best) + "#[norange]")


def refresh_state(best):
    """Only says something when there is something to say: `⟳` while a
    request is in flight, `✗` for a while after one failed. The reading's
    own time is in the message a click flashes, not in the bar."""
    try:
        live = json.load(open(LIVE_FILE))
    except Exception:
        live = {}
    now_ms = time.time() * 1000
    if now_ms - (live.get("refreshing_since_ms") or 0) < 30_000:
        return "#[fg=#ffd700]⟳#[default]"
    if (live.get("error_at_ms") or 0) > (best.get("fetched_at_ms") or 0) \
            and now_ms - live["error_at_ms"] < 10 * 60_000:
        return "#[fg=#ff8700]✗#[default]"
    return ""


# A blocked pane is the one thing that actually stalls you, so it gets a
# loud, persistent segment (badge style: a white-on-red WAIT chip, the
# window's name, and how long it's been waiting) that re-renders every
# status refresh until you go deal with it — that's the "don't vanish on
# its own" a passing display-message couldn't give. Everything else stays
# a quiet theme-coloured dot. tmux honours #[...] style directives inside
# #() output; #[default] restores the status-right style after.
MODE = os.environ.get("MODE", "all")
parts = []
q = quota_segment() if MODE in ("all", "quota") else ""
if q:
    parts.append(q)
if MODE == "quota":
    blocked, done_unread, running, read_count = [], 0, 0, 0
# ⏸ 是固定的第四块，和另外三块一样宽、一样从不消失（用户 2026-09-29：「wait 的弹出
# 状态要如何更好地遮挡其他的状态，而不影响其他信息的显示」）。
# 以前它带着出事那个窗口的**名字**排在最前面，宽度随名字变：一有人等你确认，后面三块
# 计数和 git/文件/轨迹 三个按钮就整体右移 —— 你按肌肉记忆去点就点错，这正是另外三块
# 当初改成「零也常驻」要解决的问题；名字长的时候还会把窗口列表往右挤出去。
# 名字不放这儿：窗口列表本来就按窗口画状态徽标（window-status-format 里的
# #{E:@claude_win}），哪个窗口在等你，那一格自己是红的，而且旁边就写着窗口名。
# 仍然可点：有人等的时候范围名带上等最久的那个窗格（w%NN），点它直接跳过去；
# 归零时不发范围，就是个灰的、点不动的位置占位。
blocked_range = ""
if blocked:
    blocked.sort(reverse=True)          # longest-waiting first
    blocked_range = "w" + blocked[0][2]
# The three counts, always all three, in the same order, whether or not any
# of them is zero — 一个数归零就整块消失的话，另外两个会横着挪位置，你按着
# 记忆去点就点错了（2026-09-28 用户原话：「尽量固定显示，就算是 0 也显示一下，
# 反正就三个状态」）。零的那个用灰色，占着位置但不喊人。
# Icons and colours match the picker's labels: ✔ DONE-unread (green, a
# result to look at) leads, then ▶ RUN (yellow, Claude's still busy —
# nothing for you to do), then ✓ READ in the picker's own READ blue —
# finished and already looked at, so nothing is waiting, but it's where you
# go to hand out the next job. The blocked WAIT chip above outranks all
# three and leads the whole segment; it carries a window name, so it is the
# one thing here that still changes the segment's width.
# ︎ forces the narrow text glyph. Each is a clickable range: a click opens
# the picker listing just those panes.
# quota 模式（状态栏最右边那一半）不出这三个：常驻之后零也会画出来，
# 右边就多了一组全是 0 的 ✔ ▶ ✓。
ZERO = "#6c6c6c"
for rng, icon, count, colour in ((blocked_range, "⏸︎", len(blocked), "#ff5f5f"),
                                 ("done", "✔︎", done_unread, "#5fff00"),
                                 ("running", "▶︎", running, "#ffff00"),
                                 ("read", "✓︎", read_count, "#5f87d7")):
    if MODE == "quota":
        break
    # ⏸ 非零时加粗：它是这四块里唯一「要你动手」的那一块，颜色之外再给一档轻重。
    weight = ",bold" if count and icon == "⏸︎" else ""
    chip = f"#[fg={colour if count else ZERO}{weight}]{icon} {count}"
    # 归零的 ⏸ 没有可跳的窗格，所以不发范围 —— 点它什么也不会发生，而不是点到
    # 一个指向空处的动作。
    parts.append(f"#[range=user|{rng}]{chip}#[norange]" if rng else chip + "#[default]")

if parts:
    # A trailing plain space in quota mode too, although that half sits at
    # the far right edge: iTerm2 paints the few pixels right of the last
    # column (the window rarely divides into whole cells) in the last cell's
    # background. Ending on the 7d cooldown cell, that margin came out as a
    # third blue bar next to it.
    print("  ".join(parts) + "#[default] ")
PYEOF
