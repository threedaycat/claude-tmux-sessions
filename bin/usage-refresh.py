#!/usr/bin/env python3
"""usage-refresh.py — fetch the real 5h / 7d rate-limit usage, the way /usage does.

    usage-refresh.py            refresh if the last reading is older than the interval
    usage-refresh.py --force    refresh now (the status-bar click)
    usage-refresh.py --notify [--client C]   a card on client C: the last numbers at once,
                                              the new ones when the request returns

Why this exists: the status bar used to read only Claude Code's own cache
(cachedUsageUtilization in ~/.claude.json), which moves when Claude Code
decides to fetch — so the way to get a current number was typing /usage in a
session and waiting. This asks the same endpoint directly (~2s) and writes
the answer to its own file, LIVE_FILE, which status-badge.sh prefers whenever
it is the newer of the two.

What it touches, deliberately little:
  - reads the OAuth access token Claude Code keeps (macOS Keychain item
    "Claude Code-credentials", or ~/.claude/.credentials.json elsewhere).
    The token is used in memory for this one request and never written or
    printed anywhere.
  - never *refreshes* the token. An expired token just means "no new
    reading"; the next time any Claude Code session runs it renews it.
    Doing the refresh here would mean writing credentials back, and a
    status bar has no business doing that.
  - never writes ~/.claude.json — that file belongs to Claude Code.

The endpoint (api/oauth/usage) is what Claude Code itself calls; it is not a
documented public API, so if it changes this fails quietly and the bar falls
back to Claude Code's cache.

Throttled: auto mode runs at most once per CLAUDE_TMUX_USAGE_REFRESH_MIN
minutes (default 30), counting failed attempts too, so a broken token never
turns into a request every 10 seconds of status-interval.
"""
import fcntl
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request

HOME = os.path.expanduser("~")
LIVE_FILE = os.path.join(HOME, ".claude", "tmux-usage-live.json")
LOCK_FILE = LIVE_FILE + ".lock"
URL = "https://api.anthropic.com/api/oauth/usage"
INTERVAL = 60 * int(os.environ.get("CLAUDE_TMUX_USAGE_REFRESH_MIN") or 30)
FORCE_GAP = 20            # seconds between two forced (clicked) refreshes
WINDOWS = ("five_hour", "seven_day")
CLIENT = sys.argv[sys.argv.index("--client") + 1] if "--client" in sys.argv else None


def load(path):
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
        return {}


def save(obj):
    tmp = f"{LIVE_FILE}.{os.getpid()}.tmp"
    with open(tmp, "w") as f:
        json.dump(obj, f)
    os.replace(tmp, LIVE_FILE)


def token():
    raw = ""
    try:
        r = subprocess.run(
            ["security", "find-generic-password", "-s", "Claude Code-credentials", "-w"],
            capture_output=True, text=True, timeout=5)
        if r.returncode == 0:
            raw = r.stdout
    except Exception:
        pass
    if not raw:
        try:
            with open(os.path.join(HOME, ".claude", ".credentials.json")) as f:
                raw = f.read()
        except Exception:
            return None, "找不到 Claude Code 的登录凭据"
    try:
        o = json.loads(raw).get("claudeAiOauth") or {}
    except Exception:
        return None, "凭据格式认不出"
    if (o.get("expiresAt") or 0) / 1000 < time.time():
        return None, "令牌已过期，开一次 Claude Code 会自动续上"
    return o.get("accessToken"), None


def fetch():
    tok, err = token()
    if not tok:
        return None, err
    req = urllib.request.Request(URL, headers={
        "Authorization": "Bearer " + tok,
        "anthropic-beta": "oauth-2025-04-20",
        "User-Agent": "claude-tmux-sessions",
    })
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            d = json.load(resp)
    except urllib.error.HTTPError as e:
        return None, f"查询失败 HTTP {e.code}"
    except Exception as e:
        return None, f"查询失败（{type(e).__name__}）"
    return {w: {"utilization": (d.get(w) or {}).get("utilization"),
                "resets_at": (d.get(w) or {}).get("resets_at")} for w in WINDOWS}, None


def reset_str(iso):
    from datetime import datetime
    try:
        dt = datetime.fromisoformat(iso).astimezone()
    except Exception:
        return "?"
    today = datetime.now().astimezone().date()
    return dt.strftime("%H:%M" if dt.date() == today else "%m-%d %H:%M")


def until_str(iso):
    """'2 小时 13 分' / '6 天 18 小时' until the reset."""
    from datetime import datetime
    try:
        left = (datetime.fromisoformat(iso).astimezone()
                - datetime.now().astimezone()).total_seconds()
    except Exception:
        return "?"
    if left <= 0:
        return "已经"
    d, rem = divmod(int(left), 86400)
    h, rem = divmod(rem, 3600)
    m = rem // 60
    if d:
        return f"{d} 天 {h} 小时"
    if h:
        return f"{h} 小时 {m} 分"
    return f"{m} 分钟"


def at_str(ms):
    """When a reading was taken: '14:02', or '09-26 14:02' if not today."""
    if not ms:
        return None
    t = time.localtime(ms / 1000)
    return time.strftime("%H:%M" if t[:3] == time.localtime()[:3] else "%m-%d %H:%M", t)


def show_card(usage, err, live, note=None, refreshing=False):
    """The answer to the click, as a small tmux menu at the bottom right:
    both windows' usage and how long until each resets, spelled out. A menu
    rather than a status-line message because a message is one grey line
    that is gone in 3s; a menu stays until you click elsewhere or press a key.
    On failure the title says so and the last good reading is shown.

    refreshing: the card that opens the moment you click, before the ~2s
    request — the last reading, its time, and a "refreshing" mark. main()
    swaps it for the answer when the request returns.

    Returns the running `tmux display-menu`: it doesn't exit until the menu
    is closed, which is how main() knows whether the card is still up."""
    data = usage or {w: live.get(w) for w in WINDOWS}
    at = at_str(live.get("fetched_at_ms"))
    if refreshing:
        title = f" Claude 额度 · {at} 的数据 · ⟳ 刷新中… " if at else " Claude 额度 · ⟳ 刷新中… "
    elif usage:
        title = f" Claude 额度 · {time.strftime('%H:%M')} 刷新 "
    elif note:
        title = f" Claude 额度 · {at or '之前'} 的数据（{note}）"
    else:
        title = " 没刷新成功：" + (err or "未知原因") + " "
    items = []
    for label, w in (("5 小时", "five_hour"), ("7 天", "seven_day")):
        u = data.get(w) or {}
        if u.get("utilization") is None:
            items += [f"{label}   没有数据", "", ""]
            continue
        items += [f"{label}   已用 {round(u['utilization'])}%", "", ""]
        items += [f"      {until_str(u.get('resets_at'))}后重置（{reset_str(u.get('resets_at'))}）", "", ""]
        items += [""]                                   # separator
    if items and items[-1] == "":
        items.pop()
    # Run from `run-shell -b` there is no "current client" — the click
    # passes its own along, or the menu has nowhere to appear.
    # -M: a menu opened from a shell has no mouse event behind it, and tmux
    # then flags it MENU_NOMOUSE (cmd-display-menu.c) — clicks on and around
    # it stop behaving like a menu. Cancelling it with the mouse kept
    # re-triggering the refresh. -M turns normal mouse handling back on:
    # a click outside closes it, like any menu.
    cmd = ["tmux", "display-menu", "-M", "-x", "R", "-y", "S", "-T", title]
    if CLIENT:
        cmd[2:2] = ["-c", CLIENT]
    return subprocess.Popen(cmd + ["--"] + items, stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL)


def replace_card(first, *args, **kw):
    """Swap the refreshing card for the answer — only if it is still open.
    Closed already (a click elsewhere, a key) means you've moved on; popping
    it back up would be a card nobody asked for. tmux won't open a menu over
    another one, so close ours first (display-popup -C closes any overlay;
    ours is the one up, since its display-menu is still waiting)."""
    if first is None or first.poll() is not None:
        return
    close = ["tmux", "display-popup", "-C"] + (["-c", CLIENT] if CLIENT else [])
    subprocess.run(close, capture_output=True)
    first.wait()
    show_card(*args, **kw).wait()


def main():
    force = "--force" in sys.argv
    notify = "--notify" in sys.argv
    now_ms = int(time.time() * 1000)
    card = None

    with open(LOCK_FILE, "w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            # Another refresh is already on it. A click still gets its card
            # at once, and the answer when that refresh is done.
            if notify:
                card = show_card(None, None, load(LIVE_FILE), refreshing=True)
                fcntl.flock(lock, fcntl.LOCK_EX)
                live = load(LIVE_FILE)
                fresh = (live.get("fetched_at_ms") or 0) > now_ms - 30_000
                usage = {w: live.get(w) for w in WINDOWS} if fresh else None
                replace_card(card, usage, live.get("error"), live)
            return
        live = load(LIVE_FILE)
        last = max(live.get("fetched_at_ms") or 0, live.get("attempted_at_ms") or 0)
        if not force and now_ms - last < INTERVAL * 1000:
            return
        # Even a click can't hit the endpoint more than once per FORCE_GAP:
        # whatever re-fires it (a stuck click, a menu bug — both happened),
        # it must not turn into a burst that gets the account rate-limited.
        # Within the gap a click still gets its card, with the last reading.
        if force and now_ms - (live.get("attempted_at_ms") or 0) < FORCE_GAP * 1000:
            lock.close()            # not held while the card is up
            if notify:
                show_card(None, None, live, note="刚刚刷新过").wait()
            return
        # The card first, with what we have: the request takes ~2s and the
        # click should answer now, not then.
        if notify:
            card = show_card(None, None, live, refreshing=True)
        live["attempted_at_ms"] = now_ms
        # Visible while the ~2s request runs: status-badge shows "⟳ 刷新中"
        # for as long as this is set (and ignores it after 30s, in case we die).
        live["refreshing_since_ms"] = now_ms
        save(live)
        subprocess.run(["tmux", "refresh-client", "-S"], capture_output=True)

        usage, err = fetch()
        live.pop("refreshing_since_ms", None)
        if usage:
            live.update(usage)
            live["fetched_at_ms"] = int(time.time() * 1000)
            live.pop("error", None)
        else:
            live["error"] = err
            live["error_at_ms"] = int(time.time() * 1000)
        save(live)

    subprocess.run(["tmux", "refresh-client", "-S"], capture_output=True)
    if notify:
        replace_card(card, usage, err, live)


if __name__ == "__main__":
    main()
