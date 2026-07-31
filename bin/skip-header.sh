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
#       $2 = direction (up/down/init/left/right/slash/preview/
#            showall/digit/quit/esc)
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

PANE_HEADER='j/k 选窗口 · 数字直跳 · h session · a 全部 · p 预览 · Enter 跳转 · / 搜索 · ctrl-x 归档 · q 退出'
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
  showall)
    # Flip collapsed/expanded and reload. The state has to live in a file
    # for the same reason the cursor mode does: every keypress is a separate
    # process. list-rows.sh reads it via CLAUDE_TMUX_SHOW_ALL_FILE, so the
    # reload re-renders with the quiet panes shown (or hidden) — and because
    # numbers are assigned before the visibility test, nothing renumbers.
    #
    # fzf's reload() puts the cursor back on the first row, which is wrong
    # here: `a` changes how much of the list you can see, not where you are.
    # So remember what the cursor is on *before* reloading, build the new
    # list here rather than inside reload(), and follow up with pos() on
    # wherever that same row landed. reload-sync (not reload) is what makes
    # the pos() land on the new list instead of racing the old one.
    # Fields come out via awk, not `read -r ... < <(...)`: tab is an IFS
    # *whitespace* character, so `IFS=$'\t' read` collapses runs of it and a
    # header row (whose pane field is empty) parses one field short — the
    # session name lands in old_pane and the cursor jumps.
    old_pane="" old_session="" old_num=""
    if [ -n "${ROWS_FILE:-}" ] && [ -s "$ROWS_FILE" ]; then
      cur_line=$(( cur + 1 ))
      old_pane=$(awk -F'\t' -v n="$cur_line" 'NR == n { print $2 }' "$ROWS_FILE")
      old_session=$(awk -F'\t' -v n="$cur_line" 'NR == n { print $3 }' "$ROWS_FILE")
      old_num=$(awk -F'\t' -v n="$cur_line" 'NR == n { print $4 }' "$ROWS_FILE")
    fi

    if [ -n "${SHOW_ALL_FILE:-}" ]; then
      if [ "$(cat "$SHOW_ALL_FILE" 2>/dev/null)" = "1" ]; then
        printf '0' > "$SHOW_ALL_FILE"
      else
        printf '1' > "$SHOW_ALL_FILE"
      fi
    fi

    if [ -z "${ROWS_FILE:-}" ]; then
      echo "reload($BIN_DIR/list-rows.sh)"
      exit 0
    fi
    "$BIN_DIR/list-rows.sh" > "$ROWS_FILE"
    # Exact row if it's still visible; otherwise — you collapsed the very row
    # you were on — the nearest pane row at or above its old number, which
    # keeps you in the same neighbourhood instead of at the top.
    new_pos=$(awk -F'\t' -v p="$old_pane" -v s="$old_session" -v num="$old_num" '
      $2 != "" && $2 == p { print NR; found = 1; exit }
      $2 == "" && $4 == "" && p == "" && $3 == s { print NR; found = 1; exit }
      { if ($2 != "") { if (first == 0) first = NR
                        if (num != "" && $4 != "" && $4 + 0 <= num + 0) near = NR } }
      END { if (!found) print (near ? near : (first ? first : 1)) }
    ' "$ROWS_FILE")
    echo "reload-sync(cat '$ROWS_FILE')+pos(${new_pos:-1})"
    exit 0
    ;;
  preview)
    # Collapse the preview entirely so the list gets the full width — with
    # a dozen-plus panes, scanning names/cwds beats seeing one pane's
    # screen. Press again to bring it back.
    echo "toggle-preview"
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
# Three row kinds now, and the cursor treats them differently: session
# headers (empty pane id, empty row number) stop only in session mode, pane
# rows (a %pane id) stop only in pane mode, and the "⋯ 收起 N 个" summary
# (empty pane id, row number "-") stops in neither — it's a label, not a
# destination. Hence two position sets rather than one negated set.
HEADER_POS=",$(printf '%s\n' "$rows" | awk -F'\t' '{ if ($2 == "" && $4 == "") print NR }' | paste -sd, -),"
PANE_POS=",$(printf '%s\n' "$rows" | awk -F'\t' '{ if ($2 != "") print NR }' | paste -sd, -),"

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
  # Match against the row number list-rows.sh puts in field 4, rather than
  # counting pane rows: collapsing the quiet panes keeps every number
  # attached to its pane, which makes the *visible* numbers sparse (1, 4,
  # 7, 12…). "Nth pane row" would land on the wrong pane the moment
  # anything is hidden.
  line=$(printf '%s\n' "$rows" | awk -F'\t' -v n="$n" '$4 == n { print NR; exit }')
  # Likewise "can these digits still be extended" is no longer n*10 <=
  # total: with gaps, what matters is whether any visible number starts
  # with what's typed so far and is longer.
  extendable=$(printf '%s\n' "$rows" \
    | awk -F'\t' -v p="$n" '$4 != "" && length($4) > length(p) && index($4, p) == 1 { c++ } END { print c + 0 }')
  if [ "$n" -ge 1 ] && [ "$extendable" -gt 0 ]; then
    # More digits could still follow, so hold the prefix. If it also names a
    # visible row, park the cursor there as a preview of what Enter takes;
    # if it doesn't (its own row is collapsed, e.g. 1 while only 10-15 show)
    # just wait — dropping the prefix here would make 12 unreachable.
    if [ -n "${PENDING_FILE:-}" ]; then printf '%s' "$n" > "$PENDING_FILE"; fi
    if [ -n "$line" ]; then echo "pos($line)"; else echo "ignore"; fi
  elif [ "$n" -ge 1 ] && [ -n "$line" ]; then
    if [ -n "${PENDING_FILE:-}" ]; then : > "$PENDING_FILE" 2>/dev/null || true; fi
    echo "pos($line)+accept"                    # can't be extended — jump now
  else
    echo "ignore"                                # 0, or out of range — keep any pending prefix
  fi
  exit 0
fi

is_header() {
  [[ "$HEADER_POS" == *",$1,"* ]]
}

is_pane() {
  [[ "$PANE_POS" == *",$1,"* ]]
}

# Is position $1 a valid stop in the current mode?
is_stop() {
  if [ "$mode" = "session" ]; then
    is_header "$1"
  else
    is_pane "$1"
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
