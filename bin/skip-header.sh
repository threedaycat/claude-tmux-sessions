#!/usr/bin/env bash
# Called by fzf's up/down/left/right/load bind transforms. One list, two
# cursor modes, no screen switching:
#   pane mode (default)  up/down stop only on pane rows, headers skipped
#   session mode         up/down stop only on session header rows
# left switches to session mode (cursor snaps to the current session's
# header), right switches back to pane mode (cursor snaps to the nearest
# pane row). The current mode lives in $MODE_FILE, created/exported by
# claude-tmux-picker.sh for this picker instance.
# args: $1 = current 0-based item index ({n}),
#       $2 = direction (up/down/init/left/right)
#
# Recomputes the row list itself (via list-rows.sh) on every call instead
# of trusting a snapshot passed in once at fzf startup, since archiving a
# pane reshuffles positions mid-session via fzf's reload() action.
set -euo pipefail

BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cur="${1:-0}"
dir="${2:-down}"

PANE_HEADER='↑↓ 选 Claude 窗口 · ← 切成选 session · Enter 跳转 · ctrl-x 归档 · Esc 取消'
SESSION_HEADER='↑↓ 选 session · → 切回选窗口 · Enter 跳到该 session · Esc 取消'

mode="pane"
if [ -n "${MODE_FILE:-}" ] && [ -s "$MODE_FILE" ]; then
  mode="$(cat "$MODE_FILE")"
fi

rows="$("$BIN_DIR/list-rows.sh")"
TOTAL=$(printf '%s\n' "$rows" | wc -l | tr -d ' ')
HEADER_POS=",$(printf '%s\n' "$rows" | awk -F'\t' '{ if ($2 == "") print NR }' | paste -sd, -),"

is_header() {
  [[ "$HEADER_POS" == *",$1,"* ]]
}

# Is position $1 a valid stop in the current mode?
is_stop() {
  if [ "$mode" = "session" ]; then
    is_header "$1"
  else
    ! is_header "$1"
  fi
}

orig=$(( cur + 1 ))  # 1-based current position; fallback if no valid target found

case "$dir" in
  down)
    idx=$(( cur + 2 ))
    step=1
    ;;
  up)
    idx=$(( cur ))
    step=-1
    ;;
  init)
    mode="pane"
    idx=1
    step=1
    orig=1
    ;;
  left)
    # switch to session mode: snap up to the current session's header
    mode="session"
    idx="$orig"
    step=-1
    ;;
  right)
    # switch back to pane mode: snap down to the nearest pane row
    mode="pane"
    idx="$orig"
    step=1
    ;;
esac

[ -n "${MODE_FILE:-}" ] && printf '%s' "$mode" > "$MODE_FILE"

while [ "$idx" -ge 1 ] && [ "$idx" -le "$TOTAL" ] && ! is_stop "$idx"; do
  idx=$(( idx + step ))
done

# Ran off the end without a stop — for the mode switches retry in the
# other direction (e.g. `right` on the last line, whose panes are all
# above it); for plain up/down just stay put.
if [ "$idx" -lt 1 ] || [ "$idx" -gt "$TOTAL" ]; then
  case "$dir" in
    left|right)
      idx="$orig"
      step=$(( -step ))
      while [ "$idx" -ge 1 ] && [ "$idx" -le "$TOTAL" ] && ! is_stop "$idx"; do
        idx=$(( idx + step ))
      done
      ;;
  esac
fi

if [ "$idx" -lt 1 ] || [ "$idx" -gt "$TOTAL" ] || ! is_stop "$idx"; then
  idx="$orig"
fi

case "$dir" in
  left)
    echo "change-header($SESSION_HEADER)+pos($idx)"
    ;;
  right)
    echo "change-header($PANE_HEADER)+pos($idx)"
    ;;
  *)
    echo "pos($idx)"
    ;;
esac
