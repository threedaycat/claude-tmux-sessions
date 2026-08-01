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
#       $2 = direction (up/down/init/left/right/slash/preview/tokens/
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

# The pane-mode header is computed by claude-tmux-picker.sh and exported,
# because whether it advertises `f` depends on whether any team exists —
# and that is known once, at startup, not on every keypress. The literal
# below is the fallback for running this script standalone (it is designed
# to work without $ROWS_FILE for debugging), where an empty header would
# otherwise be the only sign anything was wrong. It is also the version
# without `f`, which is correct: no picker instance means no team state to
# filter.
PANE_HEADER="${PANE_HEADER:-j/k 选窗口 · 数字直跳 · h session · a 全部 · p 预览 · t token · Enter 跳转 · / 搜索 · ctrl-x 归档 · q 退出}"
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

# Both `a` and ctrl-x replace the whole list under the cursor, and fzf's
# reload() puts the cursor back on row one. That's wrong for both: neither key
# means "take me somewhere else", so the cursor has to be carried across.
# remember_cursor notes what the cursor is on; reload_keeping_place rebuilds
# the list *here* (not inside reload(), so the new rows exist before we need
# to search them) and emits a pos() for wherever that row landed.
#
# Fields come out via awk, not `read -r ... < <(...)`: tab is an IFS
# *whitespace* character, so `IFS=$'\t' read` collapses runs of it and a
# header row (whose pane field is empty) parses one field short — the session
# name lands in old_pane and the cursor jumps.
old_pane="" old_session="" old_num=""
remember_cursor() {
  [ -n "${ROWS_FILE:-}" ] && [ -s "$ROWS_FILE" ] || return 0
  local n=$(( cur + 1 ))
  old_pane=$(awk -F'\t' -v n="$n" 'NR == n { print $2 }' "$ROWS_FILE")
  old_session=$(awk -F'\t' -v n="$n" 'NR == n { print $3 }' "$ROWS_FILE")
  old_num=$(awk -F'\t' -v n="$n" 'NR == n { print $4 }' "$ROWS_FILE")
}

# $1 = which way to fall back when the remembered row is no longer in the
# list: `before` (nearest pane row at or above its old number) or `after`.
reload_keeping_place() {
  if [ -z "${ROWS_FILE:-}" ]; then
    echo "reload($BIN_DIR/list-rows.sh)"       # standalone/debug: no cache to keep
    return 0
  fi
  "$BIN_DIR/list-rows.sh" > "$ROWS_FILE"
  local pos
  pos=$(awk -F'\t' -v p="$old_pane" -v s="$old_session" -v num="$old_num" \
            -v prefer="$1" '
    $2 != "" && $2 == p { print NR; found = 1; exit }
    $2 == "" && $4 == "" && p == "" && $3 == s { print NR; found = 1; exit }
    {
      # Teammate rows are skipped as landing spots for the same reason the
      # cursor does not stop on them: pos() onto one would park the cursor
      # somewhere j/k cannot get back to.
      if ($2 != "" && $5 != "mate") {
        if (first == 0) first = NR
        if (num != "" && $4 != "") {
          if ($4 + 0 <= num + 0) before = NR
          if ($4 + 0 >= num + 0 && after == 0) after = NR
        }
      }
    }
    END {
      # Guarded, because awk runs END even after `exit` — without this the
      # matched row and the fallback both print and pos() gets two numbers,
      # which fzf ignores, which sends the cursor to the top. Which is the
      # bug this whole function exists to fix.
      if (!found) {
        pick = (prefer == "after") ? (after ? after : before) \
                                   : (before ? before : after)
        print (pick ? pick : (first ? first : 1))
      }
    }
  ' "$ROWS_FILE")
  echo "reload-sync(cat '$ROWS_FILE')+pos(${pos:-1})"
}

# fzf fires `load` every time the list finishes loading — including after
# every reload() — and the initial cursor placement is bound to it. So each
# `a` or ctrl-x reload re-ran "put the cursor where the picker started" and
# undid the pos() that was carrying the cursor across. This makes it what it
# was always meant to be: a *first* load hook. $INIT_FILE is the marker
# (created empty by the picker, filled here on the first load).
if [ "$dir" = "init" ]; then
  if [ -n "${INIT_FILE:-}" ] && [ -s "$INIT_FILE" ]; then
    echo "ignore"            # a reload — whoever triggered it owns the cursor
    exit 0
  fi
  [ -n "${INIT_FILE:-}" ] && printf 'done' > "$INIT_FILE"
  # Opened via the tmux binding that passes CALLER_PANE, and that pane is
  # tracked: start on "where I am" rather than on whatever is first.
  if [ -n "${CALLER_POS:-}" ]; then
    [ -n "${MODE_FILE:-}" ] && printf 'pane' > "$MODE_FILE"
    echo "pos($CALLER_POS)"
    exit 0
  fi
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
    remember_cursor
    if [ -n "${SHOW_ALL_FILE:-}" ]; then
      if [ "$(cat "$SHOW_ALL_FILE" 2>/dev/null)" = "1" ]; then
        printf '0' > "$SHOW_ALL_FILE"
      else
        printf '1' > "$SHOW_ALL_FILE"
      fi
    fi
    # Collapsing the row you're on should leave you just above it, where the
    # rows you were reading still are.
    reload_keeping_place before
    exit 0
    ;;
  teamonly)
    # `f`. Identical machinery to `a` — remember the cursor, flip a
    # per-instance state file, rebuild the list here, then pos() onto
    # wherever the same row ended up — because it is the same kind of
    # action: it changes how much of the list you can see, not where you
    # are. list-rows.sh reads the file via CLAUDE_TMUX_TEAM_ONLY_FILE.
    #
    # With no team on the machine the key is simply not live: the picker
    # exports no TEAM_FILE, so this returns `ignore` and behaves exactly
    # like every other unbound letter. That is also why the header only
    # mentions `f` when there is something to filter.
    if [ -z "${TEAM_FILE:-}" ]; then
      echo "ignore"
      exit 0
    fi
    remember_cursor
    if [ "$(cat "$TEAM_FILE" 2>/dev/null)" = "1" ]; then
      printf '0' > "$TEAM_FILE"
    else
      printf '1' > "$TEAM_FILE"
    fi
    # Filtering away the row you're on should leave you just above it,
    # where the rows you were reading still are — same choice as `a`.
    reload_keeping_place before
    exit 0
    ;;
  archive)
    # ctrl-x. Same reload-resets-the-cursor problem as `a`, one difference:
    # the row is *gone* afterwards, so the natural landing spot is the row
    # that took its place — the next one, the way deleting a message in an
    # inbox advances rather than jumping to the top.
    remember_cursor
    if [ -n "$old_pane" ]; then
      python3 "$BIN_DIR/../hooks/tmux_status_update.py" mark-archived "$old_pane" \
        2>/dev/null || true
    fi
    reload_keeping_place after
    exit 0
    ;;
  tokens)
    # `t`. The page itself is opened by an execute() bound directly on the
    # key in claude-tmux-picker.sh — an execute printed from here would be
    # discarded, since transform output is parsed as a --listen payload
    # and that parser treats execute as remote code execution. All this
    # branch still owns is the search-mode case, handled above (`put(t)`);
    # in navigation mode there is nothing left to change about the list.
    # The page needs no cursor carrying: it doesn't reload anything, so
    # fzf redraws the list exactly as it was.
    echo "ignore"
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
# Five row kinds now, and the cursor treats them differently: session
# headers (empty pane id, empty row number, no kind) stop only in session
# mode, pane rows (a %pane id) stop only in pane mode, the "⋯ 收起 N 个"
# summary (empty pane id, row number "-") stops in neither — it's a label,
# not a destination — external provider items (field 5 == "extra") stop in
# pane mode alongside the panes, since Enter acts on them too, and team
# block headers (field 5 == "team") do the same. Hence separate position
# sets rather than one negated set.
#
# A team header must be listed explicitly or it is a row nothing can reach:
# its row-number field is empty, so HEADER_POS would take it if it weren't
# for the field-5 test, and its pane id is empty, so PANE_POS never will.
HEADER_POS=",$(printf '%s\n' "$rows" | awk -F'\t' '{ if ($2 == "" && $4 == "" && $5 == "") print NR }' | paste -sd, -),"
# Teammate rows (field 5 == "mate") are excluded: they carry a pane id, so
# the bare `$2 != ""` test used to take them, and the cursor stopped on
# every teammate on its way past a team — walking you through rows that
# repeat what their lead's row already says, to reach a lead you'd wanted
# in one step. They stay visible, and a search hit can still act on one;
# they are simply not somewhere j/k stops. Under `f` list-rows.sh omits
# the marker, so in that mode they are ordinary pane rows again — which is
# the whole point of that mode.
PANE_POS=",$(printf '%s\n' "$rows" | awk -F'\t' '{ if ($2 != "" && $5 != "mate") print NR }' | paste -sd, -),"
EXTRA_POS=",$(printf '%s\n' "$rows" | awk -F'\t' '{ if ($5 == "extra") print NR }' | paste -sd, -),"
TEAM_POS=",$(printf '%s\n' "$rows" | awk -F'\t' '{ if ($5 == "team") print NR }' | paste -sd, -),"

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

is_extra() {
  [[ "$EXTRA_POS" == *",$1,"* ]]
}

is_team() {
  [[ "$TEAM_POS" == *",$1,"* ]]
}

# Is position $1 a valid stop in the current mode?
# `init` is narrower on purpose: with extra provider rows sorted first,
# landing on "wherever the cursor starts" would land on an extra row
# instead of a pane the moment any exist. Initial focus should be "where
# you are" (a pane), not "whatever's on top" — that's what `right`/`down`
# are for once you're actually browsing.
is_stop() {
  if [ "$mode" = "session" ]; then
    is_header "$1"
  elif [ "$dir" = "init" ]; then
    is_pane "$1"
  else
    is_pane "$1" || is_extra "$1" || is_team "$1"
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
