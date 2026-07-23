#!/usr/bin/env bash
# Pick a tracked Claude Code tmux pane (running/done/blocked/input) and
# jump to it. One fzf list: pane rows are the only selectable stops.
# Session header rows are shown for visual grouping only — up/down/entry
# skip over them via bin/skip-header.sh. Arrow keys move the live preview
# (right side) instantly; Enter jumps; ctrl-x archives a pane you're done
# caring about.
set -euo pipefail

# Resolve through the ~/.claude/hooks symlink to this script's real location,
# so the sibling scripts (list-rows.sh, skip-header.sh, ../hooks/...) can
# always be found regardless of how this script was invoked.
SCRIPT_PATH="${BASH_SOURCE[0]}"
[ -L "$SCRIPT_PATH" ] && SCRIPT_PATH="$(readlink "$SCRIPT_PATH")"
BIN_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
STATUS_UPDATER="$BIN_DIR/../hooks/tmux_status_update.py"

STATUS_FILE="$HOME/.claude/tmux-claude-status.json"

if [ ! -s "$STATUS_FILE" ]; then
  echo "还没有记录到任何 Claude Code session。"
  sleep 1.5
  exit 0
fi

rows="$("$BIN_DIR/list-rows.sh")"

if [ -z "$rows" ]; then
  echo "没有找到仍然存活的 Claude Code tmux pane。"
  sleep 1.5
  exit 0
fi

# Default initial cursor: first pane row, skipping the leading header.
# If this popup was opened via the tmux binding that passes CALLER_PANE
# (the pane you were actually on when you pressed the key), and that pane
# is itself tracked, start there instead — you want to land on "where I
# am", not always on whatever's most urgent. fzf already starts at
# position 1 on its own, so only add a load bind when we have somewhere
# more useful to send it — "load" with no action is invalid.
fzf_args=(--ansi --delimiter=$'\t' --with-nth=1
  --header='↑↓ 选择 Claude 窗口 (右侧预览实时更新) · Enter 跳转 · ctrl-x 归档 · Esc 取消'
  --layout=reverse --height=100%
  --preview 'tmux capture-pane -p -e -S -200 -t {2} 2>&1 || echo "(pane 已关闭或无法读取)"'
  --preview-window='right,60%,border-left,wrap,follow'
  --preview-label=' Claude 实时画面 '
  --bind "down:transform:$BIN_DIR/skip-header.sh {n} down"
  --bind "up:transform:$BIN_DIR/skip-header.sh {n} up"
  --bind "ctrl-x:execute-silent(python3 '$STATUS_UPDATER' mark-archived {2})+reload($BIN_DIR/list-rows.sh)")

LOAD_BIND="load:transform:$BIN_DIR/skip-header.sh 0 init"
if [ -n "${CALLER_PANE:-}" ]; then
  CALLER_POS=$(printf '%s\n' "$rows" | awk -F'\t' -v p="$CALLER_PANE" '$2==p { print NR; exit }')
  [ -n "$CALLER_POS" ] && LOAD_BIND="load:pos($CALLER_POS)"
fi
fzf_args+=(--bind "$LOAD_BIND")

chosen=$(printf '%s\n' "$rows" | fzf "${fzf_args[@]}")

[ -n "$chosen" ] || exit 0

pane_id=$(printf '%s' "$chosen" | awk -F'\t' '{print $2}')

if [ -z "$pane_id" ]; then
  # Landed on a header row somehow (e.g. it was the only line matching a
  # search query) — there's nothing to jump to.
  exit 0
fi

session=$(tmux display-message -p -t "$pane_id" '#{session_name}' 2>/dev/null || true)

if [ -z "$session" ]; then
  echo "pane 已经不存在了 ($pane_id)。"
  sleep 1.5
  exit 0
fi

# Visiting a DONE pane means "I've seen this" — mark it read so it stops
# showing up as unread next time (RUN/blocked/input panes are unaffected:
# the status field isn't "done" so the read flag has no visible effect
# until a future "done" actually happens).
python3 "$STATUS_UPDATER" mark-read "$pane_id" 2>/dev/null || true

if [ -n "${TMUX:-}" ]; then
  tmux switch-client -t "$session"
  tmux select-window -t "$pane_id"
  tmux select-pane -t "$pane_id"
else
  tmux attach -t "$session" \; select-window -t "$pane_id" \; select-pane -t "$pane_id"
fi
