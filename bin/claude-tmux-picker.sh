#!/usr/bin/env bash
# Pick a tracked Claude Code tmux pane (running/done/blocked/input) and
# jump to it. One fzf list, two cursor modes (bin/skip-header.sh):
# by default up/down stop only on pane rows (session headers are skipped);
# left switches to session mode where up/down stop only on headers and
# Enter jumps to that session's active pane; right switches back. The
# right-side preview follows the cursor either way; Enter jumps; ctrl-x
# archives a pane you're done caring about.
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
# Cursor-mode state (pane vs session) shared with skip-header.sh's
# transform invocations, which run as separate processes per keypress and
# so can't keep it in a variable. Scoped to this picker instance.
MODE_FILE="$(mktemp "${TMPDIR:-/tmp}/claude-tmux-picker-mode.XXXXXX")"
export MODE_FILE
printf 'pane' > "$MODE_FILE"
trap 'rm -f "$MODE_FILE"' EXIT

fzf_args=(--ansi --delimiter=$'\t' --with-nth=1
  --header='↑↓ 选 Claude 窗口 · ← 切成选 session · Enter 跳转 · ctrl-x 归档 · Esc 取消'
  --layout=reverse --height=100%
  --preview "$BIN_DIR/preview-row.sh {2} {3}"
  --preview-window='right,60%,border-left,wrap,follow'
  --preview-label=' Claude 实时画面 '
  --bind "down:transform:$BIN_DIR/skip-header.sh {n} down"
  --bind "up:transform:$BIN_DIR/skip-header.sh {n} up"
  --bind "left:transform:$BIN_DIR/skip-header.sh {n} left"
  --bind "right:transform:$BIN_DIR/skip-header.sh {n} right"
  --bind "ctrl-x:execute-silent(python3 '$STATUS_UPDATER' mark-archived {2})+reload($BIN_DIR/list-rows.sh)")

LOAD_BIND="load:transform:$BIN_DIR/skip-header.sh 0 init"
if [ -n "${CALLER_PANE:-}" ]; then
  CALLER_POS=$(printf '%s\n' "$rows" | awk -F'\t' -v p="$CALLER_PANE" '$2==p { print NR; exit }')
  [ -n "$CALLER_POS" ] && LOAD_BIND="load:pos($CALLER_POS)"
fi
fzf_args+=(--bind "$LOAD_BIND")

# `|| true`: fzf exits 130 on Esc/ctrl-c, which would otherwise ride
# set -e out of this script and make tmux print
# "'tmux display-popup …' returned 130" — cancelling isn't an error.
chosen=$(printf '%s\n' "$rows" | fzf "${fzf_args[@]}" || true)

[ -n "$chosen" ] || exit 0

pane_id=$(printf '%s' "$chosen" | awk -F'\t' '{print $2}')

# All jumps target a pane id, never a session/window name: tmux allows
# ':' and '.' in session names, which derail name-based target parsing,
# while switch-client happily resolves a %pane id to its session.
if [ -z "$pane_id" ]; then
  # Session header row (session-select mode): jump to the session's
  # active pane — i.e. where you last were in that session. Resolved by
  # exact string match over list-panes for the same reason as above.
  session=$(printf '%s' "$chosen" | awk -F'\t' '{print $3}')
  [ -n "$session" ] || exit 0
  pane_id=$(tmux list-panes -a \
      -F "#{session_name}	#{window_active}#{pane_active}	#{pane_id}" 2>/dev/null \
    | awk -F'\t' -v s="$session" '$1==s && $2=="11" { print $3; exit }')
  if [ -z "$pane_id" ]; then
    echo "session 已经不存在了 ($session)。"
    sleep 1.5
    exit 0
  fi
  tmux switch-client -t "$pane_id" 2>/dev/null \
    || tmux attach -t "$pane_id"
  exit 0
fi

if ! tmux display-message -p -t "$pane_id" '' >/dev/null 2>&1; then
  echo "pane 已经不存在了 ($pane_id)。"
  sleep 1.5
  exit 0
fi

# Visiting a DONE/IDLE pane means "I've seen this" — mark it read so it
# stops showing up as unread next time (RUN/blocked panes are unaffected:
# the read flag has no visible effect until a future done/input happens).
python3 "$STATUS_UPDATER" mark-read "$pane_id" 2>/dev/null || true

if [ -n "${TMUX:-}" ]; then
  tmux switch-client -t "$pane_id"
  tmux select-window -t "$pane_id"
  tmux select-pane -t "$pane_id"
else
  tmux attach -t "$pane_id" \; select-window -t "$pane_id" \; select-pane -t "$pane_id"
fi
