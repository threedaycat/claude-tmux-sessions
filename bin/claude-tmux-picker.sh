#!/usr/bin/env bash
# Pick a tracked Claude Code tmux pane (running/done/blocked/input) and
# jump to it. One fzf list, two cursor modes (bin/skip-header.sh):
# by default up/down stop only on pane rows (session headers are skipped);
# left switches to session mode where up/down stop only on headers and
# Enter jumps to that session's active pane; right switches back. The
# right-side preview follows the cursor either way; Enter jumps; ctrl-x
# archives a pane you're done caring about. The preview takes
# CLAUDE_TMUX_PREVIEW_WIDTH% (default 50). An even split is the one width
# that needs no justification: the preview ends up about as wide as the Claude
# pane it is showing, so the captured screen appears at the shape it really
# has instead of reflowing. Narrower fits more list, but Claude's own output
# wraps hard below ~60 columns and a preview you can't read is worth less than
# the columns it saves; `p` collapses it entirely for when you do just want to
# scan the list.
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

# Collapsed/expanded state for the quiet panes (READ and aged-out DONE),
# toggled by `a`. Per picker instance and read by list-rows.sh through
# CLAUDE_TMUX_SHOW_ALL_FILE, so the toggle survives fzf's reload without
# leaking into your next picker — the default is what you set globally via
# CLAUDE_TMUX_SHOW_ALL, not whatever you last pressed.
SHOW_ALL_FILE="$(mktemp "${TMPDIR:-/tmp}/claude-tmux-picker-showall.XXXXXX")"
export SHOW_ALL_FILE
export CLAUDE_TMUX_SHOW_ALL_FILE="$SHOW_ALL_FILE"
if [ "${CLAUDE_TMUX_SHOW_ALL:-}" = "1" ]; then printf '1' > "$SHOW_ALL_FILE"; else printf '0' > "$SHOW_ALL_FILE"; fi

# Agent Teams. `f` filters the list down to the teams and their panes, `l`
# unfolds one lead's teammates in place, and both only exist when there is a
# team at all — checked once, here, with a single stat. No team means no
# TEAM_FILE and no EXPAND_FILE, which means skip-header.sh returns `ignore`
# for `f` exactly as it does for any unbound letter, `l` keeps its plain
# meaning (switch back to pane mode), and the header below mentions neither.
# Nobody who hasn't switched Agent Teams on pays anything for this beyond
# the stat.
CLAUDE_HOME_DIR="${CLAUDE_HOME:-$HOME/.claude}"
# `o 总览` leads: it is the "what's the situation" screen, so it is what you
# want when you have just come back and don't know where to look yet — and
# the header is cut off around column 78 on the list side of a split picker,
# so the front is the only place a new entry is reliably on screen.
PANE_HEADER='o 总览 · j/k 选窗口 · 数字直跳 · h session · a 全部 · p 预览 · t token · Enter 跳转 · / 搜索 · ctrl-x 归档 · q 退出'
if [ -d "$CLAUDE_HOME_DIR/teams" ]; then
  TEAM_FILE="$(mktemp "${TMPDIR:-/tmp}/claude-tmux-picker-teamonly.XXXXXX")"
  export TEAM_FILE
  export CLAUDE_TMUX_TEAM_ONLY_FILE="$TEAM_FILE"
  printf '0' > "$TEAM_FILE"
  # Which lead's teammates j/k may currently walk, as a row index. Written
  # by `l`, cleared by `h` and by anything that rebuilds the list.
  EXPAND_FILE="$(mktemp "${TMPDIR:-/tmp}/claude-tmux-picker-expand.XXXXXX")"
  export EXPAND_FILE
  # `l` is deliberately *not* listed here: it only does something on a lead
  # row, and this string is already wider than the list side of a split
  # picker, so a permanent entry would push an existing one off the end.
  # skip-header.sh appends the hint on the rows where the key works.
  PANE_HEADER='o 总览 · j/k 选窗口 · 数字直跳 · h session · a 全部 · f 编队 · p 预览 · t token · Enter 跳转 · / 搜索 · ctrl-x 归档 · q 退出'
fi
# Exported so skip-header.sh uses the same string when it restores the
# header after a mode switch. It used to be written out twice, once here
# and once there, which is how the two could disagree.
export PANE_HEADER

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

# Accumulator for multi-digit row jumps (skip-header.sh): the digits typed
# so far while it waits to see whether another follows. Empty = no jump in
# progress; cleared by any non-digit key and once a jump fires.
PENDING_FILE="$(mktemp "${TMPDIR:-/tmp}/claude-tmux-picker-pending.XXXXXX")"
export PENDING_FILE

# Where a full-screen page (the token page, for now) leaves a pane it wants
# jumped to. Those pages run inside fzf's execute() and so cannot exit the
# picker themselves; they write a pane id here and abort, the `t` binding's
# trailing transform turns that into an `abort` for the picker's own fzf,
# and the jump happens below in the one place that knows how to do it. The
# alternative — switching the client from inside the popup — leaves the
# picker sitting open on top of the pane you just asked to be taken to.
JUMP_FILE="$(mktemp "${TMPDIR:-/tmp}/claude-tmux-picker-jump.XXXXXX")"
export JUMP_FILE

trap 'rm -f "$MODE_FILE" "$ROWS_FILE" "$PENDING_FILE" "$SHOW_ALL_FILE" "$JUMP_FILE" "${TEAM_FILE:-}" "${EXPAND_FILE:-}" "${INIT_FILE:-}"' EXIT

# Starts with search disabled AND the input line hidden (--disabled
# --no-input): j/k/h/l navigate vim-style, and unbound letters go nowhere
# instead of piling up in a dead query display (--disabled alone still
# shows and fills the input line). / shows the input and enables search
# (letters then type normally, Esc hides it and drops back to
# navigation) — all dispatched through skip-header.sh, which branches on
# FZF_INPUT_STATE (hidden in navigation, enabled while searching).
#
# `{n}` is quoted in every bind below, and the quotes are load-bearing.
# fzf substitutes it with the index of the item under the cursor, but an
# empty list has no item, and the placeholder then expands to nothing at
# all. Unquoted, the shell drops that empty word and every argument after
# it shifts one place left: `skip-header.sh {n} esc` arrives as
# `skip-header.sh esc`, so the script reads `esc` where it expects a row
# number and the key it was told about goes missing. That turned every
# transform-bound key — including Esc and q — into a no-op the moment the
# list came up empty, which is to say it left no way out of the picker.
# Quoted, the empty index survives as an empty first argument and the rest
# stay where they belong.
#
# The `load` bind at the bottom passes a literal 0 rather than `{n}`, so it
# never had the problem and needs no quotes.
fzf_args=(--ansi --delimiter=$'\t' --with-nth=1 --disabled --no-input
  --header="$PANE_HEADER"
  --layout=reverse --height=100%
  --preview "$BIN_DIR/preview-row.sh {2} {3} {5} {6}"
  --preview-window="right,${CLAUDE_TMUX_PREVIEW_WIDTH:-50}%,border-left,wrap,follow"
  --preview-label=' Claude 实时画面 '
  --bind "down:transform:$BIN_DIR/skip-header.sh \"{n}\" down"
  --bind "up:transform:$BIN_DIR/skip-header.sh \"{n}\" up"
  --bind "left:transform:$BIN_DIR/skip-header.sh \"{n}\" left"
  --bind "right:transform:$BIN_DIR/skip-header.sh \"{n}\" right"
  --bind "j:transform:$BIN_DIR/skip-header.sh \"{n}\" down j"
  --bind "k:transform:$BIN_DIR/skip-header.sh \"{n}\" up k"
  --bind "h:transform:$BIN_DIR/skip-header.sh \"{n}\" left h"
  --bind "l:transform:$BIN_DIR/skip-header.sh \"{n}\" right l"
  --bind "/:transform:$BIN_DIR/skip-header.sh \"{n}\" slash /"
  --bind "a:transform:$BIN_DIR/skip-header.sh \"{n}\" showall a"
  # `f` narrows the list to the teams and their panes. Bound
  # unconditionally so that while the search input is open it still types
  # an f; with no team on the machine the transform returns `ignore` and
  # the key is inert, like any other letter nothing is bound to.
  --bind "f:transform:$BIN_DIR/skip-header.sh \"{n}\" teamonly f"
  --bind "p:transform:$BIN_DIR/skip-header.sh \"{n}\" preview p"
  # `t` opens the token page. Unlike every other key here, the work can't
  # be done by the transform: actions printed by transform go through the
  # same parser as the --listen HTTP payload, which refuses execute() as
  # remote code execution — fzf drops it silently, so the key just did
  # nothing. So the execute is bound directly, and the transform is kept
  # only for its other job: while the search input is open, `t` has to
  # type a t. token-page.sh returns immediately in that state (it reads
  # $FZF_INPUT_STATE, which fzf exports to every child).
  # The trailing transform runs after the page has exited (execute() is
  # synchronous): if the page left a pane in $JUMP_FILE, it makes this fzf
  # abort so the jump below can happen.
  --bind "t:transform($BIN_DIR/skip-header.sh \"{n}\" tokens t)+execute($BIN_DIR/token-page.sh 1)+transform($BIN_DIR/skip-header.sh \"{n}\" jumped)"
  # `o` opens the overview — same shape as `t`, and for the same reason,
  # including the trailing transform that turns a queued jump into an abort.
  --bind "o:transform($BIN_DIR/skip-header.sh \"{n}\" overview o)+execute($BIN_DIR/overview-page.sh)+transform($BIN_DIR/skip-header.sh \"{n}\" jumped)"
  --bind "q:transform:$BIN_DIR/skip-header.sh \"{n}\" quit q"
  --bind "esc:transform:$BIN_DIR/skip-header.sh \"{n}\" esc"
  --bind "ctrl-x:transform:$BIN_DIR/skip-header.sh \"{n}\" archive"
  --bind "start:bg-transform-footer:$BIN_DIR/usage-footer.sh")

# Digits type a pane-row number (the gutter number) and jump there — see
# skip-header.sh. 1-9 still jump instantly whenever they can't begin a
# larger valid number (so <10 rows is unchanged); with two-digit rows a
# first digit parks the cursor and waits for the next digit or Enter. 0 is
# bound too but only ever lands as a second digit (rows 10, 20, …). Routed
# through skip-header.sh so that while search is open the same keys type
# into the query instead.
for d in 0 1 2 3 4 5 6 7 8 9; do
  fzf_args+=(--bind "$d:transform:$BIN_DIR/skip-header.sh \"{n}\" digit $d")
done

# Initial cursor. Everything goes through skip-header.sh's `init` rather than
# a bare load:pos(), because `load` fires again after every reload() — a bare
# pos() there would yank the cursor back to the starting row every time you
# pressed `a` or archived something. skip-header.sh makes it fire once, using
# $INIT_FILE as the marker.
INIT_FILE="$(mktemp "${TMPDIR:-/tmp}/claude-tmux-picker-init.XXXXXX")"
export INIT_FILE
if [ -n "${CALLER_PANE:-}" ]; then
  # Not onto a teammate row: those are not cursor stops, so starting there
  # would park the cursor somewhere j/k cannot return to. Opening the
  # picker from inside a teammate pane therefore falls back to the normal
  # opening position rather than to "where I am".
  CALLER_POS=$(printf '%s\n' "$rows" \
    | awk -F'\t' -v p="$CALLER_PANE" '$2==p && $5!="mate" { print NR; exit }')
  export CALLER_POS
fi
fzf_args+=(--bind "load:transform:$BIN_DIR/skip-header.sh 0 init")

# `|| true`: fzf exits 130 on Esc/ctrl-c, which would otherwise ride
# set -e out of this script and make tmux print
# "'tmux display-popup …' returned 130" — cancelling isn't an error.
chosen=$(printf '%s\n' "$rows" | fzf "${fzf_args[@]}" || true)

# A pane handed over by a full-screen page (see $JUMP_FILE above) wins: the
# picker's own fzf was aborted, so `chosen` is empty and there is no row to
# read. Everything after this — the existence check, mark-read, the switch —
# is the same for both routes, which is the point of routing it here.
jump_pane=""
if [ -n "${JUMP_FILE:-}" ] && [ -s "$JUMP_FILE" ]; then
  jump_pane="$(cat "$JUMP_FILE")"
fi

if [ -n "$jump_pane" ]; then
  pane_id="$jump_pane"
else
  [ -n "$chosen" ] || exit 0

  # Extra provider row: Enter hands off to the provider's own action, same
  # as preview did — this script still doesn't interpret the row, it just
  # routes by the "extra" marker in field 5. Runs in the foreground with the
  # popup's own TTY so a provider that prompts (e.g. "wake it up? [y/N]")
  # works normally.
  kind=$(printf '%s' "$chosen" | awk -F'\t' '{print $5}')

  if [ "$kind" = "extra" ]; then
    item_id=$(printf '%s' "$chosen" | awk -F'\t' '{print $6}')
    if [ -n "${CLAUDE_TMUX_EXTRA_CMD:-}" ] && [ -x "${CLAUDE_TMUX_EXTRA_CMD}" ]; then
      "$CLAUDE_TMUX_EXTRA_CMD" action "$item_id" || true
    fi
    exit 0
  fi

  # A "mate" row deliberately has no branch of its own: it falls through to
  # the pane jump below, which is exactly right for it. The cursor never
  # stops on one, but `/` search can still surface and select it, and when
  # it does, jumping to that pane is what pressing Enter on it should mean.
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
fi

# `has-session`, not `display-message -p -t <pane> ''` — which is what this
# used to be, and which never once fired: for a pane id that no longer exists
# display-message still exits 0 (measured: `%99999` returns success and an
# empty format), so the check passed and the jump fell through to a raw tmux
# error instead of this line.
if ! tmux has-session -t "$pane_id" 2>/dev/null; then
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
