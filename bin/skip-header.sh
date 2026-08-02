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

# fzf replaces {n} with the index of the item under the cursor — but an
# EMPTY list has no item under the cursor, and fzf then drops the
# placeholder instead of substituting anything. The argument list arrives
# one short and every argument shifts left: `{n} esc` becomes `esc`, so the
# direction lands in $1 where a number belongs and $2 falls back to its
# default, `down`.
#
# That turned Esc into a down-arrow and q into a crash — `orig=$((cur + 1))`
# on a $cur holding the word `quit` trips `set -u`, which exits before the
# script prints an action, so fzf is handed nothing and the key does
# nothing at all. With an empty list on screen there was then no way out of
# the picker short of killing the pane.
#
# The empty index actually arrives in two different shapes, and it is worth
# knowing both because only one of them is dramatic:
#
#   no items at all   the placeholder is dropped, the argument count drops
#                     with it, and everything shifts left. This is the one
#                     that broke the keyboard.
#   items, 0 matches  the placeholder is substituted with an empty string,
#                     the argument count is unchanged, and `${1:-0}` has
#                     always absorbed it quietly.
#
# Quoting `{n}` in the picker's binds turns the first shape into the second,
# so past that fix both arrive here as an empty first argument. The
# normalisation below stays anyway: it costs one comparison, and it is what
# makes this script safe to call with arguments that came from anywhere.
#
# Normalised here, once, rather than at either call site, because an empty
# list is reachable by more than one route: `f` filtering everything away
# (below), and — with no team on the machine at all — a `/` search that
# matches nothing, which empties fzf's *view* while the row list behind it
# is untouched. {n} is always a number, so a $1 that isn't one means the
# placeholder was dropped and the real arguments begin there.
# The pattern accepts a leading minus even though a row index is never
# negative, because fzf does hand out -1 for "no current item" and the
# question here is only ever "was this an index, or the next argument?".
# A minus sign answers that as clearly as a digit does; treating -1 as a
# stray word instead would shift arguments that never moved, and the
# direction would end up holding `-1`.
if ! [[ "$cur" =~ ^-?[0-9]+$ ]]; then
  dir="${1:-down}"
  key="${2:-}"
  cur=0
fi
[ "$cur" -lt 0 ] && cur=0

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
# Shown when `f` had nothing to narrow to, or when the rows it was showing
# went away. No parentheses in this string: fzf parses `change-header(…)`
# by matching them, so one here would truncate the header at that point.
TEAM_EMPTY_HEADER='编队里没有可跳转的 pane · 已显示完整列表 · j/k 浏览 · q 退出'

mode="pane"
if [ -n "${MODE_FILE:-}" ] && [ -s "$MODE_FILE" ]; then
  mode="$(cat "$MODE_FILE")"
fi

# ---------------------------------------------------------------------------
# The rows, and where the cursor may stop in them.
#
# Loaded on demand and once: the header now depends on how many stops there
# are, and the header is emitted from several places, some of which run
# before this file used to look at the rows at all.
#
# The three position sets stay **comma-separated strings, not arrays**, and
# that is load-bearing rather than legacy. Under `set -u` bash 3.2 — which is
# what `/bin/bash` is on macOS — expanding an empty array is a fatal error,
# not an empty result, so `${EMPTY[@]}` would exit the script. A transform
# that exits prints nothing, and a key that prints nothing is a key that does
# nothing: the exact failure this file exists to prevent. An empty *string*
# is just an empty string. Do not "modernise" these into arrays.
ROWS=""
TOTAL=0
HEADER_POS=""
PANE_POS=""
EXTRA_POS=""
_rows_loaded=0

load_rows() {
  [ "$_rows_loaded" = 1 ] && return 0
  if [ -n "${ROWS_FILE:-}" ] && [ -s "$ROWS_FILE" ]; then
    ROWS="$(cat "$ROWS_FILE")"
  else
    ROWS="$("$BIN_DIR/list-rows.sh")"
  fi
  if [ -z "$ROWS" ]; then
    # Short-circuited, and not as an optimisation. `printf '%s\n' ""` emits
    # one empty line, and an empty line satisfies the session-header test —
    # empty pane id, empty row number, empty kind — so feeding it to the
    # scanners below invents a header at row 1 on a list that has no rows at
    # all. That was harmless while nothing counted the sets; it stops being
    # harmless the moment "how many stops are there" decides what the header
    # says, and it would have offered `h 看 session` on an empty picker.
    TOTAL=0
    HEADER_POS=",,"
    PANE_POS=",,"
    EXTRA_POS=",,"
    _rows_loaded=1
    return 0
  fi
  TOTAL=$(printf '%s\n' "$ROWS" | wc -l | tr -d ' ')
  # Four row kinds, and the cursor treats them differently: session headers
  # (empty pane id, empty row number, no kind) stop only in session mode,
  # pane rows (a %pane id) stop only in pane mode, the "⋯ 收起 N 个" summary
  # (empty pane id, row number "-") stops in neither — it's a label, not a
  # destination — and external provider items (field 5 == "extra") stop in
  # pane mode alongside the panes, since Enter acts on them too. Hence
  # separate position sets rather than one negated set.
  HEADER_POS=",$(printf '%s\n' "$ROWS" | awk -F'\t' '{ if ($2 == "" && $4 == "" && $5 == "") print NR }' | paste -sd, -),"
  # Teammate rows (field 5 == "mate") are excluded: they carry a pane id, so
  # the bare `$2 != ""` test used to take them, and the cursor stopped on
  # every teammate on its way past a team — walking you through rows that
  # repeat what their lead's row already says, to reach a lead you'd wanted
  # in one step. They stay visible, and a search hit can still act on one;
  # they are simply not somewhere j/k stops. Under `f` list-rows.sh omits
  # the marker, so in that mode they are ordinary pane rows again — which is
  # the whole point of that mode.
  PANE_POS=",$(printf '%s\n' "$ROWS" | awk -F'\t' '{ if ($2 != "" && $5 != "mate") print NR }' | paste -sd, -),"
  EXTRA_POS=",$(printf '%s\n' "$ROWS" | awk -F'\t' '{ if ($5 == "extra") print NR }' | paste -sd, -),"
  _rows_loaded=1
}

# The row cache changed underneath us; the next question re-reads it.
invalidate_rows() { _rows_loaded=0; }

# ",1,3," -> 2 ; ",," -> 0. An empty set is a normal state, not a mistake.
count_pos() {
  local s="${1#,}"
  s="${s%,}"
  if [ -z "$s" ]; then printf '0'; else printf '%s' "$s" | awk -F, '{ print NF }'; fi
}

# **The judgement everything about emptiness is derived from.** Not "are
# there rows" — "is there anywhere for the cursor to go *in this mode*".
# Those are different questions and the difference is reachable daily: two
# read panes in one tmux session collapse into a header plus a `⋯ 收起` line,
# which is two rows and zero pane stops.
stops_here() {
  load_rows
  if [ "$mode" = "session" ]; then
    count_pos "$HEADER_POS"
  else
    echo $(( $(count_pos "$PANE_POS") + $(count_pos "$EXTRA_POS") ))
  fi
}

# The same count for the mode `h`/`l` would take you to, so the way out can
# be offered only when it actually leads somewhere.
stops_across() {
  load_rows
  if [ "$mode" = "session" ]; then
    echo $(( $(count_pos "$PANE_POS") + $(count_pos "$EXTRA_POS") ))
  else
    count_pos "$HEADER_POS"
  fi
}

# The header for a mode with nowhere to stand, assembled from the keys that
# are **actually live right now** rather than from a fixed sentence.
#
# Three rules, each paid for by something measured:
#
#   - **The way out comes first.** This string gets truncated well before its
#     end in a half-width list, and the exit was the part being cut. What
#     survives truncation has to be the part you cannot do without.
#   - **`esc` is named.** It was the one key that always worked here and the
#     only one never advertised.
#   - **Nothing dead is listed.** `a` appears only when something is actually
#     collapsed, and the other mode only when it has stops. Everything else
#     the normal header advertises — digits, `ctrl-x`, `j`/`k`, `Enter` — is
#     inert in this state, so none of it is named.
#
# No parentheses anywhere in the result: fzf parses `change-header(…)` by
# matching them, and one here would truncate the header at that point.
empty_header() {
  load_rows
  local bits="q/esc 退出"
  if [ -n "$ROWS" ] && printf '%s\n' "$ROWS" | awk -F'\t' '$4 == "-" { f = 1 } END { exit !f }'; then
    bits="$bits · a 展开"
  fi
  if [ "$(stops_across)" -gt 0 ]; then
    if [ "$mode" = "session" ]; then
      bits="$bits · l 回到 pane 列表"
    else
      bits="$bits · h 看 session"
    fi
  fi
  # The wording for a genuinely empty list is the startup guard's, verbatim
  # minus its full stop. Arriving at the same state by a different route
  # should not be described in different words.
  if [ "$TOTAL" -eq 0 ]; then
    bits="$bits · 没有找到仍然存活的 Claude Code tmux pane"
  else
    bits="$bits · 这一屏没有可以选的行"
  fi
  printf '%s' "$bits"
}

mode_header() {
  # Derived, never remembered. Every cursor move re-sends this, so anything
  # latched instead of computed would be wiped by the next `j` — which fires
  # even when there is nothing to move to. That is the difference between a
  # state and an event, and why `f`'s "filter dropped" notice, which *is* an
  # event, is not routed through here.
  if [ "$(stops_here)" -eq 0 ]; then
    empty_header
  elif [ "$mode" = "session" ]; then
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
    # `search()` between clearing the query and disabling search is load-
    # bearing, not decoration. `clear-query` empties the query but the
    # re-filter it schedules is dropped by the `disable-search` arriving in
    # the same batch, so Esc used to leave the list still showing whatever
    # the query had narrowed it to — and when the query matched nothing, it
    # left it showing nothing at all. An empty list is the state fzf stops
    # substituting {n} in, which is what made that particular Esc
    # unescapable. `search()` re-runs the search against the now-empty
    # query and forces the full list back before search is switched off.
    esc)   echo "clear-query+search()+disable-search+hide-input+change-header($(mode_header))" ;;
    enter) echo "accept" ;;
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

# Rebuild the row cache, and refuse to leave it empty.
#
# A list with no rows is a bad place to be: nothing to put the cursor on
# and nothing for Enter. It used to be far worse than that — it also took
# the keyboard with it — but that is now handled separately and at a lower
# level, by the argument normalisation at the top of this file and the
# quoting of `{n}` in the picker's binds. Escaping an empty list is their
# job. Not entering one needlessly is this function's.
#
# **No key can be exempted from the check, and in particular `a` cannot.**
# `f` is the obvious cause, being the only thing that filters a populated
# list down to nothing. But every rebuild re-reads the world, and the world
# shrinks on its own: the last Claude in the list can exit while the picker
# is sitting open, prune drops its row, and the next `a` rebuilds into
# nothing with no filter involved at all. ctrl-x reaches the same place by
# archiving the last row standing.
#
# So the emptiness need not arrive on the keypress that caused it, and need
# not involve `f` — which is why this lives on the rebuild, the one path
# every list-changing key goes through, instead of in any single key's
# branch. Deciding it per rebuild is also what keeps it honest while state
# moves underneath the picker between keypresses: a startup-time answer
# goes stale the moment a teammate joins or is shut down.
#
# What it can actually fix is the filtered case: drop the filter, rebuild
# without it. When the rows are gone for real — everything archived, every
# Claude exited — there is nothing to recover and the list stays empty, on
# purpose. That state is legitimate, and it is escapable.
#
# **An all-provider list under `f` counts as nothing to show, the same as no
# rows at all.** A team directory whose only member is the lead contributes
# no rows — the lead's pane can only be deduced from where its teammates
# are, so a team without any leaves it unfindable — and the external
# provider's rows are emitted regardless of the filter. Press `f` in that
# state and the list is neither empty nor useless: it is a screenful of
# somebody's to-do items, under a key labelled 编队. That is the same lie as
# a dead key, told the other way round, and it is caught here rather than as
# a fourth special case because the recovery is identical: drop the filter,
# rebuild, say so.
FILTER_DROPPED=0
rebuild_rows() {
  "$BIN_DIR/list-rows.sh" > "$ROWS_FILE"
  # Before any early return: whatever was loaded describes the old list.
  invalidate_rows
  local filtering=0
  if [ -n "${TEAM_FILE:-}" ] && [ "$(cat "$TEAM_FILE" 2>/dev/null)" = "1" ]; then
    filtering=1
  fi
  if [ -s "$ROWS_FILE" ]; then
    if [ "$filtering" = 0 ]; then
      return 0
    fi
    # Under the filter, a pane row is by construction a team pane: sessions
    # without one are dropped whole. Provider rows carry no pane id, so
    # "is there a pane row" is exactly "did the filter find anything".
    if awk -F'\t' '$2 != "" { f = 1 } END { exit !f }' "$ROWS_FILE"; then
      return 0
    fi
  fi
  if [ "$filtering" = 1 ]; then
    printf '0' > "$TEAM_FILE"
    "$BIN_DIR/list-rows.sh" > "$ROWS_FILE"
    FILTER_DROPPED=1
  fi
}

# $1 = which way to fall back when the remembered row is no longer in the
# list: `before` (nearest pane row at or above its old number) or `after`.
reload_keeping_place() {
  if [ -z "${ROWS_FILE:-}" ]; then
    echo "reload($BIN_DIR/list-rows.sh)"       # standalone/debug: no cache to keep
    return 0
  fi
  rebuild_rows
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
  # The header goes out on every rebuild, not only when something notable
  # happened, because a rebuild is precisely when the answer can change:
  # collapse the last two readable panes with `a` and the list still has
  # rows but no longer has a stop. Nothing else would re-derive it until the
  # next cursor move, and in that state the cursor cannot move.
  #
  # A state outranks an event when both apply. `f` dropping its filter is
  # worth saying, but if what came back still has nowhere to stand then the
  # way out matters more than the explanation — and the explanation would be
  # wiped by the next keypress anyway, while the state would not.
  local hdr
  if [ "$(stops_here)" -eq 0 ]; then
    hdr="$(empty_header)"
  elif [ "$FILTER_DROPPED" = 1 ]; then
    hdr="$TEAM_EMPTY_HEADER"
  else
    hdr="$(mode_header)"
  fi
  echo "change-header($hdr)+reload-sync(cat '$ROWS_FILE')+pos(${pos:-1})"
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
    #
    # A team existing is *not* the same as `f` having something to show,
    # and the picker's startup check can only answer the first. A team
    # directory outlives its teammates, and the lead's own roster entry
    # carries the literal string "leader" where a pane id would go, so it
    # joins to no pane — a team whose teammates have all exited therefore
    # still exists while contributing not one row. Turning the filter on
    # there used to leave fzf with an empty list and no way out of it.
    #
    # The flip below is left unconditional and the emptiness is caught in
    # rebuild_rows instead, which puts the flag back and rebuilds. That
    # keeps the decision on the rebuilt rows — the only thing that actually
    # answers "would this be empty" — rather than on a second guess at what
    # list-rows.sh is about to do, which is how the two could disagree.
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
  enter)
    # Enter on an empty list used to close the picker and jump nowhere:
    # fzf accepts with no selection, the caller gets an empty string and
    # exits quietly. Doing nothing at all is not much, but it is honest —
    # closing the window is what `q` and `esc` are for, and a key that
    # silently does something you did not ask for is worse than a key that
    # does nothing. With rows present this is fzf's own `accept`, unchanged.
    load_rows
    if [ "$TOTAL" -eq 0 ]; then
      echo "ignore"
    else
      echo "accept"
    fi
    exit 0
    ;;
esac

load_rows

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
  line=$(printf '%s\n' "$ROWS" | awk -F'\t' -v n="$n" '$4 == n { print NR; exit }')
  # Likewise "can these digits still be extended" is no longer n*10 <=
  # total: with gaps, what matters is whether any visible number starts
  # with what's typed so far and is longer.
  extendable=$(printf '%s\n' "$ROWS" \
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
    is_pane "$1" || is_extra "$1"
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
  *)
    # A direction this script doesn't know. Every caller in the picker
    # passes one of the five above, so reaching here means something
    # upstream went wrong — and the useful response to that is to leave the
    # cursor alone, not to fall through with `idx` unset and die on
    # `set -u`. Dying here is the same failure this file exists to prevent:
    # a transform that exits non-zero prints nothing, and a key that prints
    # nothing does nothing, which is indistinguishable from a frozen picker.
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

# One branch, for every direction. The mode switches used to name their own
# header, which was fine while a mode had exactly one — but a mode's header
# now depends on whether that mode has anywhere to stand, and `mode` already
# holds the new value by this point, so `mode_header` answers for the mode
# being switched *to*. Naming the string here instead meant `h` on an empty
# list swapped one set of dead keys for a different set of dead keys.
#
# The header goes out with every cursor move, not just the switches. It is
# usually the same string already showing, so it costs a redraw of one line
# — and it is how both the `f` notice and a stale empty-state header clear
# themselves without a second piece of per-instance state to remember them by.
echo "change-header($(mode_header))+pos($idx)"
