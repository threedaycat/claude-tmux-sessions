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

# Row cache shared with skip-header.sh: its transform runs on EVERY
# arrow keypress, and re-running list-rows.sh there (prune + two
# pythons + several tmux round-trips, ~100ms unloaded) made held-down
# cursor movement queue up and lag by seconds under load. Row positions
# only change when the list itself is (re)loaded, so write the rows once
# here and refresh via tee on the ctrl-x reload; keypresses just read.
ROWS_FILE="$(mktemp "${TMPDIR:-/tmp}/claude-tmux-picker-rows.XXXXXX")"
export ROWS_FILE
printf '%s\n' "$rows" > "$ROWS_FILE"
trap 'rm -f "$MODE_FILE" "$ROWS_FILE"' EXIT

# Starts with search disabled AND the input line hidden (--disabled
# --no-input): j/k/h/l navigate vim-style, and unbound letters go nowhere
# instead of piling up in a dead query display (--disabled alone still
# shows and fills the input line). / shows the input and enables search
# (letters then type normally, Esc hides it and drops back to
# navigation) — all dispatched through skip-header.sh, which branches on
# FZF_INPUT_STATE (hidden in navigation, enabled while searching).
fzf_args=(--ansi --delimiter=$'\t' --with-nth=1 --disabled --no-input
  --header='j/k 选窗口 · 1-9 直跳 · h 选 session · Enter 跳转 · / 搜索 · ctrl-x 归档 · q 退出'
  --layout=reverse --height=100%
  --preview "$BIN_DIR/preview-row.sh {2} {3}"
  --preview-window='right,60%,border-left,wrap,follow'
  --preview-label=' Claude 实时画面 '
  --bind "down:transform:$BIN_DIR/skip-header.sh {n} down"
  --bind "up:transform:$BIN_DIR/skip-header.sh {n} up"
  --bind "left:transform:$BIN_DIR/skip-header.sh {n} left"
  --bind "right:transform:$BIN_DIR/skip-header.sh {n} right"
  --bind "j:transform:$BIN_DIR/skip-header.sh {n} down j"
  --bind "k:transform:$BIN_DIR/skip-header.sh {n} up k"
  --bind "h:transform:$BIN_DIR/skip-header.sh {n} left h"
  --bind "l:transform:$BIN_DIR/skip-header.sh {n} right l"
  --bind "/:transform:$BIN_DIR/skip-header.sh {n} slash /"
  --bind "q:transform:$BIN_DIR/skip-header.sh {n} quit q"
  --bind "esc:transform:$BIN_DIR/skip-header.sh {n} esc"
  --bind "ctrl-x:execute-silent(python3 '$STATUS_UPDATER' mark-archived {2})+reload($BIN_DIR/list-rows.sh | tee '$ROWS_FILE')"
  --bind "start:bg-transform-footer:$BIN_DIR/usage-footer.sh")

# Digits 1-9 jump straight to that numbered pane row (the gutter number in
# each row) and accept — the "type a number to jump" shortcut. Routed
# through skip-header.sh so that while search is open the same keys type
# into the query instead. Rows past 9 aren't digit-reachable; use / or j/k.
for d in 1 2 3 4 5 6 7 8 9; do
  fzf_args+=(--bind "$d:transform:$BIN_DIR/skip-header.sh {n} digit $d")
done

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
