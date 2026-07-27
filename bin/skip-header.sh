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

PANE_HEADER='j/k 选窗口 · 数字直跳(两位数续按) · h 选 session · Enter 跳转 · / 搜索 · ctrl-x 归档 · q 退出'
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

# A pending multi-digit jump (see the digit handler below) is continued
# only by another digit; any other key ends it. Clearing here covers every
# path — search keys, arrows, mode switches, quit.
if [ "$dir" != "digit" ] && [ -n "${PENDING_FILE:-}" ]; then
  : > "$PENDING_FILE" 2>/dev/null || true
fi

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

# Digit key in navigation mode: type a pane-row number (the gutter number
# shown in each row) and jump there. A digit still jumps *instantly* the
# moment it can't be the start of a larger valid number — so with fewer
# than 10 rows every 1-9 is instant exactly as before. Once two-digit rows
# exist, a first digit that could be extended (e.g. 1 while rows 10-19
# exist) parks the cursor on that row and waits: press the next digit to
# complete it (12 -> auto-jumps, since nothing extends it) or Enter to take
# the parked row as-is. $PENDING_FILE holds the digits so far; it's cleared
# by any non-digit key (top of script) and once a jump fires. In search
# mode this never runs — the top block types the digit into the query.
if [ "$dir" = "digit" ]; then
  pend=""
  [ -n "${PENDING_FILE:-}" ] && [ -s "$PENDING_FILE" ] && pend="$(cat "$PENDING_FILE")"
  n=$((10#${pend}${key}))                       # digits so far, as a number
  total_panes=$(printf '%s\n' "$rows" | awk -F'\t' '$2 != "" { c++ } END { print c + 0 }')
  line=$(printf '%s\n' "$rows" \
    | awk -F'\t' -v n="$n" '$2 != "" { c++; if (c == n) { print NR; exit } }')
  if [ "$n" -ge 1 ] && [ -n "$line" ]; then
    if [ $(( n * 10 )) -gt "$total_panes" ]; then
      if [ -n "${PENDING_FILE:-}" ]; then : > "$PENDING_FILE" 2>/dev/null || true; fi
      echo "pos($line)+accept"                  # can't be extended — jump now
    else
      if [ -n "${PENDING_FILE:-}" ]; then printf '%s' "$n" > "$PENDING_FILE"; fi
      echo "pos($line)"                          # could take another digit — park & wait
    fi
  else
    echo "ignore"                                # 0, or out of range — keep any pending prefix
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
