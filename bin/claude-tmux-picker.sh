#!/usr/bin/env bash
# Pick a tmux session (default) or drill into one session's Claude Code
# panes, and jump there. One fzf screen, two row sources swapped via
# reload():
#   - list-sessions.sh: one row per session (the default view)
#   - list-rows.sh <session>: that session's panes, after Tab
# Every row carries a "kind" (S/P) so the shared preview command and the
# final Enter handling both know what they're looking at.
set -euo pipefail

# Resolve through the ~/.claude/hooks symlink to this script's real location,
# so the sibling scripts (list-sessions.sh, list-rows.sh, preview-row.sh,
# ../hooks/...) can always be found regardless of how this was invoked.
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

rows="$("$BIN_DIR/list-sessions.sh")"

if [ -z "$rows" ]; then
  echo "没有找到仍然存活的 Claude Code tmux pane。"
  sleep 1.5
  exit 0
fi

# Default initial cursor: the session you were actually on when you
# pressed the key (via CALLER_PANE, set by the tmux binding — see
# README), not always the top of the list. fzf already starts at position
# 1 on its own, so only add a load bind when we actually have somewhere
# more useful to send it — "load" with no action is invalid.
fzf_args=(--ansi --delimiter=$'\t' --with-nth=1
  --header='↑↓ 选择 session · Tab 查看其下的 pane · Shift-Tab 返回 · Enter 跳转 · ctrl-x 归档(pane) · Esc 取消'
  --layout=reverse --height=100%
  --preview "$BIN_DIR/preview-row.sh {3} {2}"
  --preview-window='right,60%,border-left,wrap,follow'
  --preview-label=' 预览 '
  --bind "tab:reload($BIN_DIR/list-rows.sh {2})"
  --bind "btab:reload($BIN_DIR/list-sessions.sh)"
  --bind "ctrl-x:execute-silent(python3 '$STATUS_UPDATER' mark-archived {2})+reload($BIN_DIR/list-rows.sh {2})")

if [ -n "${CALLER_PANE:-}" ]; then
  CALLER_SESSION=$(tmux display-message -p -t "$CALLER_PANE" '#{session_name}' 2>/dev/null || true)
  if [ -n "$CALLER_SESSION" ]; then
    CALLER_POS=$(printf '%s\n' "$rows" | awk -F'\t' -v s="$CALLER_SESSION" '$2==s { print NR; exit }')
    [ -n "$CALLER_POS" ] && fzf_args+=(--bind "load:pos($CALLER_POS)")
  fi
fi

chosen=$(printf '%s\n' "$rows" | fzf "${fzf_args[@]}")

[ -n "$chosen" ] || exit 0

target=$(printf '%s' "$chosen" | awk -F'\t' '{print $2}')
kind=$(printf '%s' "$chosen" | awk -F'\t' '{print $3}')

if [ -z "$target" ]; then
  exit 0
fi

if [ "$kind" = "S" ]; then
  # Session-level jump: switch to it and let tmux resume whichever
  # window/pane was last active there — you didn't pick a specific pane.
  session="$target"
  if [ -n "${TMUX:-}" ]; then
    tmux switch-client -t "$session"
  else
    tmux attach -t "$session"
  fi
  exit 0
fi

# Pane-level jump.
pane_id="$target"
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
