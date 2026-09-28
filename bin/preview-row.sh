#!/usr/bin/env bash
# fzf preview for one picker row.
# args: $1 = pane_id (empty on session header / extra rows)
#       $2 = session name (empty on extra rows)
#       $3 = kind ("extra" on provider rows, empty otherwise)
#       $4 = opaque id (only meaningful when $3 == "extra")
#
# Pane row: show that pane's screen, full depth.
# Header row (session-select mode): session-digest.py renders one compact
# card per tracked Claude pane — name/status/age, model + context size,
# and a recap of Claude's last reply pulled from the transcript — so one
# glance answers "what's everyone in this session up to".
# Extra row: hand off to the provider that listed it (see DESIGN.md,
# "External item provider") — this script doesn't know what the row means.
set -euo pipefail

# 先歇一下再干活。fzf 每换一次选中项就重跑这个脚本，并把上一个杀掉——而这个脚本一趟
# 要 111ms（bash 启动 + tmux 截屏 + 两个 python：strip-chrome 和 session-digest），
# 滚轮一秒几十格就是几十次「起进程 → 干 100ms → 被杀」，机器一忙就堆成肉眼可见的卡顿
# （2026-09-28 用户报「滚轮延迟非常高」）。睡在最前面，滚动途中的那些还没碰任何东西就
# 被杀掉了；停下来超过这点时间，预览才真的去截屏。
# 实测（fzf 里快速滚 20 格）：不睡跑完 21 次，睡 0.15 跑完 6 次。
sleep "${CLAUDE_TMUX_PREVIEW_DELAY:-0.15}"

pane="${1:-}"
session="${2:-}"
kind="${3:-}"
item_id="${4:-}"

SCRIPT_PATH="${BASH_SOURCE[0]}"
[ -L "$SCRIPT_PATH" ] && SCRIPT_PATH="$(readlink "$SCRIPT_PATH")"
BIN_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"

if [ "$kind" = "extra" ]; then
  if [ -n "${CLAUDE_TMUX_EXTRA_CMD:-}" ] && [ -x "${CLAUDE_TMUX_EXTRA_CMD}" ]; then
    "$CLAUDE_TMUX_EXTRA_CMD" preview "$item_id" 2>&1 \
      || echo "(provider 没能给出预览)"
  fi
  exit 0
fi

if [ -n "$pane" ]; then
  # Claude-Code-statusline-style bar (status · model · ctx · elapsed · cwd,
  # plus the team it belongs to) — the raw screen dump alone doesn't tell
  # you the things you actually triage by.
  #
  # **It goes last, under the screen, and that is not a style choice.** The
  # preview window is opened with `follow`, so fzf pins it to the bottom of
  # whatever this script prints; a 200-line scrollback is far taller than
  # the window, so anything printed first is scrolled off before you see
  # it. The bar spent three commits at the top being invisible — measured,
  # with fzf's own scroll indicator reading 239/277.
  #
  # The alternatives were worse. Dropping `follow` shows the top and hides
  # the *live* screen, which is what a pane preview is for. Trimming the
  # capture to exactly fill the window can't be done reliably, because
  # `wrap` means one captured line may occupy several display rows. And
  # `--preview-window` is one global setting, so "no follow for team rows"
  # is not expressible per row.
  #
  # The bottom is also where Claude Code keeps its input box, statusline and
  # mode hint — in a short preview (a float sized to its rows) that furniture
  # was all you saw. strip-chrome.py cuts it so the last lines are Claude's.
  { tmux capture-pane -p -e -S -200 -t "$pane" 2>/dev/null || echo "(pane 已关闭或无法读取)"; } \
    | python3 "$BIN_DIR/strip-chrome.py"
  python3 "$BIN_DIR/session-digest.py" --pane "$pane" 2>/dev/null || true
  exit 0
fi

[ -n "$session" ] || exit 0

digest="$(python3 "$BIN_DIR/session-digest.py" "$session" 2>/dev/null || true)"

if [ -n "$digest" ]; then
  printf '%s\n' "$digest"
else
  # Session exists but has no tracked Claude panes — fall back to its
  # active pane. Resolved by exact string match over list-panes instead
  # of a "=$session:" target, because tmux allows ':' and '.' in session
  # names and those would derail target parsing.
  active=$(tmux list-panes -a \
      -F "#{session_name}	#{window_active}#{pane_active}	#{pane_id}" 2>/dev/null \
    | awk -F'\t' -v s="$session" '$1==s && $2=="11" { print $3; exit }')
  if [ -n "$active" ]; then
    tmux capture-pane -p -e -S -200 -t "$active" 2>&1 || echo "(session 已关闭或无法读取)"
  else
    echo "(session 已关闭或无法读取)"
  fi
fi
