#!/usr/bin/env python3
"""usage-refresh.py — fetch the real 5h / 7d rate-limit usage, the way /usage does.

    usage-refresh.py            refresh if the last reading is older than the interval
    usage-refresh.py --force    refresh now (the status-bar click)
    usage-refresh.py --notify [--client C]   also flash the result on client C

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
WINDOWS = ("five_hour", "seven_day")


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


def main():
    force = "--force" in sys.argv
    notify = "--notify" in sys.argv
    now_ms = int(time.time() * 1000)

    with open(LOCK_FILE, "w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            return                       # another refresh is already on it
        live = load(LIVE_FILE)
        last = max(live.get("fetched_at_ms") or 0, live.get("attempted_at_ms") or 0)
        if not force and now_ms - last < INTERVAL * 1000:
            return
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
        if usage:
            # The bar only shows one glyph per window; this line is where
            # the numbers live.
            def part(label, w):
                u = usage.get(w) or {}
                return f"{label} {round(u.get('utilization') or 0)}%（{reset_str(u.get('resets_at'))} 重置）"
            msg = f"✓ {time.strftime('%H:%M')} 已刷新 · " + " · ".join(
                part(l, w) for l, w in (("5 小时", "five_hour"), ("7 天", "seven_day")))
        else:
            msg = "✗ 额度没刷新：" + (err or "未知原因")
        # Run from `run-shell -b` there is no "current client", so a bare
        # display-message goes nowhere — the click passes its client along.
        cmd = ["tmux", "display-message", "-d", "3000"]
        if "--client" in sys.argv:
            cmd += ["-c", sys.argv[sys.argv.index("--client") + 1]]
        subprocess.run(cmd + [msg], capture_output=True)


if __name__ == "__main__":
    main()
