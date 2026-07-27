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
#       $2 = direction (up/down/init/left/right/slash/quit/esc)
#       $3 = the literal key that fired this (j/k/h/l/…), if it was a
#            printable one
#
# Two input states (fzf exports FZF_INPUT_STATE): search disabled
# (default) means jkhl navigate, / enables search, q/Esc quit; search
# enabled means printable keys type into the query (put), arrows fall
# back to fzf's stock actions (pos() targets the filtered view, where our
# precomputed positions are meaningless), and Esc drops back to
# navigation instead of closing the picker.
#
# Reads the row list from $ROWS_FILE, written by claude-tmux-picker.sh at
# startup and refreshed (tee) by its ctrl-x reload — positions only change
# when the list is (re)loaded, and recomputing via list-rows.sh on every
# keypress (prune + two pythons + tmux round-trips) made cursor movement
# lag by seconds under load. Falls back to list-rows.sh when run without
# the cache (standalone/debugging).
set -euo pipefail

BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cur="${1:-0}"
dir="${2:-down}"
key="${3:-}"

PANE_HEADER='j/k 选窗口 · 1-9 直跳 · h 选 session · Enter 跳转 · / 搜索 · ctrl-x 归档 · q 退出'
SESSION_HEADER='j/k 选 session · l 切回选窗口 · Enter 跳到该 session · / 搜索 · q 退出'
SEARCH_HEADER='输入过滤 · Enter 跳转 · Esc 返回 j/k 导航'

mode="pane"
if [ -n "${MODE_FILE:-}" ] && [ -s "$MODE_FILE" ]; then
  mode="$(cat "$MODE_FILE")"
fi

mode_header() {
  if [ "$mode" = "session" ]; then
    printf '%s' "$SESSION_HEADER"
  else
    printf '%s' "$PANE_HEADER"
  fi
}

if [ "${FZF_INPUT_STATE:-disabled}" = "enabled" ]; then
  # Search mode: printable keys type, arrows act stock, Esc exits search.
  if [ -n "$key" ]; then
    echo "put($key)"
    exit 0
  fi
  case "$dir" in
    down)  echo "down" ;;
    up)    echo "up" ;;
    left)  echo "backward-char" ;;
    right) echo "forward-char" ;;
    esc)   echo "clear-query+disable-search+hide-input+change-header($(mode_header))" ;;
    *)     echo "ignore" ;;
  esac
  exit 0
fi

# Navigation mode from here on.
case "$dir" in
  slash)
    echo "show-input+enable-search+change-header($SEARCH_HEADER)"
    exit 0
    ;;
  quit|esc)
    echo "abort"
    exit 0
    ;;
esac

if [ -n "${ROWS_FILE:-}" ] && [ -s "$ROWS_FILE" ]; then
  rows="$(cat "$ROWS_FILE")"
else
  rows="$("$BIN_DIR/list-rows.sh")"
fi
TOTAL=$(printf '%s\n' "$rows" | wc -l | tr -d ' ')
HEADER_POS=",$(printf '%s\n' "$rows" | awk -F'\t' '{ if ($2 == "") print NR }' | paste -sd, -),"

# Digit key in navigation mode: jump straight to the Nth pane row (Nth
# non-header line, counting from the top across all sessions — the number
# shown in each row's gutter) and accept it. Direct jump, no Enter needed.
# In search mode this never runs — the top block already types the digit
# into the query. A digit past the last pane row is a no-op.
if [ "$dir" = "digit" ]; then
  line=$(printf '%s\n' "$rows" \
    | awk -F'\t' -v n="$key" '$2 != "" { c++; if (c == n) { print NR; exit } }')
  if [ -n "$line" ]; then
    echo "pos($line)+accept"
  else
    echo "ignore"
  fi
  exit 0
fi

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
