#!/usr/bin/env bash
# Build a throwaway, fully staged environment for screenshots: a private
# tmux server (-L shotdemo) with fake sessions/windows/cwds, a fake $HOME
# holding a matching status file plus the usage fixtures the footer reads,
# and the *real* scripts rendering all of it. The data is invented; every
# pixel of layout is produced by the actual code, so the shot can't drift
# from what the tool really draws.
#
# The fake home lives under /private/tmp, not /tmp: macOS makes /tmp a
# symlink to /private/tmp, and tmux reports the resolved path — so with
# HOME=/tmp/... the `~` abbreviation in list-rows.sh would never match and
# every row would show an absolute path.
set -euo pipefail

SRV="shotdemo"
H="/private/tmp/shotroom"
COLS=174
ROWS=26
# -f /dev/null: the demo server must not read ~/.tmux.conf. Someone else's
# config would change what the screenshot looks like (and mine set a window
# index that collided with the fixture's), which defeats the whole point of
# generating the image instead of taking one.
SOCK=(-L "$SRV" -f /dev/null)

rm -rf "$H"
mkdir -p "$H"/.claude/projects/demo "$H"/repos/{api,infra} "$H"/notes "$H"/side/{prototype,translate}

# A plausible Claude screen for the pane the cursor lands on, so the live
# preview in the shot isn't blank. Generic demo content, no real project.
cat > "$H/frame-api.txt" <<'FRAME'
> 把 api/handlers 里重复的分页逻辑抽成一个 helper

● 我先看看这几个 handler 现在各自是怎么分页的。

  Read(api/handlers/users.go)
  ⎿  读了 210 行

  Read(api/handlers/orders.go)
  ⎿  读了 184 行

● 三处都在手搓 limit/offset，而且 orders.go 少了上限校验 ——
  limit=100000 会直接打到数据库。抽 helper 的时候顺手补上。

  Write(api/internal/paging/paging.go)
  ⎿  写入 48 行

● 接下来把三个 handler 改成调用它。

  Edit(api/handlers/users.go)
  ⎿  改了 1 处

✻ Working… (1m 12s · ↑ 2.1k tokens)
FRAME

cat > "$H/frame-plain.txt" <<'FRAME'
> 跑一下测试

● 好的。

  Bash(go test ./...)
  ⎿  ok    api/internal/paging   0.312s
     ok    api/handlers          1.884s

● 都过了。

❯
FRAME

tmux "${SOCK[@]}" kill-server 2>/dev/null || true
sleep 0.3

# tmux reports the foreground command per pane; prune() keeps a pane only if
# that command isn't a shell, so the placeholder holding each fake pane open
# just has to be some non-shell binary — `tail -f /dev/null` qualifies.
# (Copying /bin/sleep to a binary literally named `claude` would have read
# better in list-panes, but macOS refuses to exec a copy of a system binary.)
new_win() { # session window_name cwd frame
  local s="$1" w="$2" d="$3" f="$4"
  local cmd="clear; cat $H/$f; exec tail -f /dev/null"
  if ! tmux "${SOCK[@]}" has-session -t "$s" 2>/dev/null; then
    tmux "${SOCK[@]}" new-session -d -s "$s" -n "$w" -x "$COLS" -y "$ROWS" -c "$d" "$cmd"
  else
    # "$s:" (trailing colon) means "this session, next free index". Bare
    # "$s" is a *target-window* spec, so once a window elsewhere shares a
    # name with a session — the fixture has both a `notes` session and a
    # `notes` window — tmux resolves it to that window's index and refuses
    # with "index N in use".
    tmux "${SOCK[@]}" new-window -d -t "$s:" -n "$w" -c "$d" "$cmd"
  fi
}

# Burn session id $0 on a throwaway so the demo's sessions are $1/$2/$3 —
# the ids a long-lived tmux server actually shows, and the ones the README's
# sample list quotes.
tmux "${SOCK[@]}" new-session -d -s _burn -x "$COLS" -y "$ROWS" "tail -f /dev/null"

new_win work    api-refactor        "$H/repos/api" frame-api.txt
new_win work    paging-helper       "$H/repos/api" frame-plain.txt
new_win work    scratch             "$H/repos/api" frame-plain.txt
new_win work    notes               "$H" frame-plain.txt
new_win work    lint-fix            "$H/repos/api" frame-plain.txt
new_win work    typecheck           "$H/repos/api" frame-plain.txt
new_win infra   deploy-script       "$H/repos/infra" frame-plain.txt
new_win infra   migrate-db          "$H/repos/api" frame-plain.txt
new_win infra   terraform-plan      "$H/repos/infra" frame-plain.txt
new_win infra   log-triage          "$H/repos/infra" frame-plain.txt
new_win infra   dns-cutover         "$H/repos/infra" frame-plain.txt
new_win web     prototype-redesign  "$H/side/prototype" frame-plain.txt
new_win web     a11y-audit          "$H/side/prototype" frame-plain.txt
new_win web     i18n-pass           "$H/side/prototype" frame-plain.txt
new_win web     bundle-size         "$H/side/prototype" frame-plain.txt
new_win web     storybook           "$H/side/prototype" frame-plain.txt
new_win docs    translate-dev       "$H/side/translate" frame-plain.txt
new_win docs    changelog           "$H/notes" frame-plain.txt
new_win docs    api-reference       "$H/notes" frame-plain.txt
new_win notes   weekly-digest       "$H/notes" frame-plain.txt
new_win notes   journal             "$H/notes" frame-plain.txt
new_win notes   reading-list        "$H/notes" frame-plain.txt

# allow-rename off: Claude Code drives the window title in real use, but
# here the names *are* the fixture, so nothing may overwrite them.
tmux "${SOCK[@]}" kill-session -t _burn
tmux "${SOCK[@]}" set-option -g allow-rename off
tmux "${SOCK[@]}" set-option -g status off
sleep 0.5

tmux "${SOCK[@]}" list-panes -a -F '#{session_name}	#{window_name}	#{pane_id}' > "$H/panes.tsv"

HOME="$H" python3 - "$H" <<'PYEOF'
import json, os, sys, time

h = sys.argv[1]
ids = {}
for line in open(f"{h}/panes.tsv"):
    s, w, p = line.rstrip("\n").split("\t")
    ids[(s, w)] = p

now = time.time()
HOUR = 3600

# ---- status file: what the four hooks would have written ----
# Ages chosen to exercise every state at once, including the aged-out DONE
# (>2h unread — dims and sinks) and a WAIT that is only 12s old.
fixture = [
    ("work",   "api-refactor",       "running", 60,          False),
    ("work",   "paging-helper",      "done",    16,          False),
    ("work",   "scratch",            "done",    160920,      True),
    ("work",   "notes",              "done",    156960,      True),
    ("work",   "lint-fix",           "done",    98640,       False),
    ("work",   "typecheck",          "done",    18000,       True),
    ("infra",  "deploy-script",      "blocked", 12,          False),
    ("infra",  "migrate-db",         "done",    960,         False),
    ("infra",  "terraform-plan",     "done",    10800,       True),
    ("infra",  "log-triage",         "done",    111600,      False),
    ("infra",  "dns-cutover",        "running", 240,         False),
    ("web",    "prototype-redesign", "done",    120,         False),
    ("web",    "a11y-audit",         "done",    28800,       True),
    ("web",    "i18n-pass",          "done",    93600,       True),
    ("web",    "bundle-size",        "running", 39,          False),
    ("web",    "storybook",          "done",    180000,      False),
    ("docs",   "translate-dev",      "done",    147600,      True),
    ("docs",   "changelog",          "done",    540,         False),
    ("docs",   "api-reference",      "done",    68400,       True),
    ("notes",  "weekly-digest",      "done",    960,         False),
    ("notes",  "journal",            "done",    57600,       True),
    ("notes",  "reading-list",       "done",    118800,      False),
]
data = {}
for s, w, status, ago, read in fixture:
    pane = ids.get((s, w))
    if not pane:
        print(f"missing pane for {s}/{w}", file=sys.stderr)
        continue
    data[pane] = {
        "status": status,
        "updated_at": now - ago,
        "read": read,
        "session": s,
        "window_name": w,
        "session_id": "00000000-0000-4000-8000-%012d" % len(data),
    }
with open(f"{h}/.claude/tmux-claude-status.json", "w") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)

# ---- quota: same shape Claude Code caches after a /usage ----
def utc(ts):
    return time.strftime("%Y-%m-%dT%H:%M:%S+00:00", time.gmtime(ts))

cfg = {
    "cachedUsageUtilization": {
        "fetchedAtMs": int((now - 6 * 60) * 1000),
        "utilization": {
            "five_hour": {"utilization": 32, "resets_at": utc(now + 2.4 * HOUR)},
            "seven_day": {"utilization": 41, "resets_at": utc(now + 4 * 24 * HOUR)},
        },
    }
}
with open(f"{h}/.claude.json", "w") as f:
    json.dump(cfg, f, indent=2)

# ---- transcripts: drive the live per-model token counts ----
# (model, tokens, hours ago) — the ones inside 5h also feed 近5h.
entries = [
    ("claude-opus-5",   3_100_000, 2),
    ("claude-opus-5",     500_000, 8),
    ("claude-fable-5",    490_000, 7),
    ("claude-opus-4-8",   110_000, 9),
]
with open(f"{h}/.claude/projects/demo/demo.jsonl", "w") as f:
    for i, (model, tok, ago) in enumerate(entries):
        ts = time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime(now - ago * HOUR))
        f.write(json.dumps({
            "type": "assistant",
            "timestamp": ts,
            "message": {
                "id": f"msg_demo_{i}",
                "model": model,
                "usage": {"input_tokens": tok, "output_tokens": 0,
                          "cache_creation_input_tokens": 0},
            },
        }) + "\n")

# ---- stats cache: the 14-day sparkline ----
history = [1.9, 2.2, 3.0, 3.6, 5.2, 4.4, 2.8, 2.6, 3.9, 4.8, 3.1, 2.4, 4.1]
daily = []
for i, m in enumerate(reversed(history), start=1):
    day = time.strftime("%Y-%m-%d", time.localtime(now - i * 24 * HOUR))
    daily.append({"date": day, "tokensByModel": {"claude-opus-5": int(m * 1e6)}})
daily.reverse()
with open(f"{h}/.claude/stats-cache.json", "w") as f:
    json.dump({"dailyModelTokens": daily}, f)

print(f"staged {len(data)} panes")
PYEOF

echo "server: tmux -L $SRV   home: $H   geometry: ${COLS}x${ROWS}"
