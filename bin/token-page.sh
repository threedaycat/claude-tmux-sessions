#!/usr/bin/env bash
# The picker's token page: full-screen "where did the tokens go", opened
# with `t` and left with q/Esc/Enter. bin/token-report.py does the counting
# and the drawing; this script owns the screen and the keys.
#
# It is a second fzf, nested inside the picker's execute(). It used to be a
# read-key redraw loop, on the reasoning that the page isn't a list —
# nothing was selectable, so two sets of key bindings would have fought
# over j/k for no gain. Both halves of that turned out wrong. The ranking
# *is* a list, and what you want from a row ("which session is this, and
# what is it doing with all those tokens") is exactly what a preview window
# is for. Worse, the loop redrew on **every** keypress, including the ones
# it went on to ignore — a ~1s transcript scan to arrive back at the same
# screen, which is what made the page feel like it was chewing.
#
# Now the scan lives in token-report.py's cache: once per window, and every
# render after that is a small JSON read. j/k move, the preview follows,
# `1`/`7` switch windows (the other window is warmed in the background
# while you read this one, so the switch is usually instant), `r` rescans
# on purpose, and no other key costs anything.
#
# Which window is on screen is not tracked here. Each row carries the cache
# it came from as its third field, so `{3}` tells the preview what to read
# and tells `r` what to rescan — the one thing that costs is an empty list
# (a window with no turns in it at all), where there is no row to carry it
# and `r` therefore does nothing.
set -euo pipefail

BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPORT="$BIN_DIR/token-report.py"
PY=(python3 "$REPORT")

# Bound directly to `t` in the picker (see the comment there), so it also
# fires while the search input is open — where `t` must type a t, not open
# a page. fzf exports the input state to every child process.
if [ "${FZF_INPUT_STATE:-disabled}" = "enabled" ]; then
  exit 0
fi

days="${1:-1}"

CACHE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/claude-tmux-tokens.XXXXXX")"
trap 'rm -rf "$CACHE_DIR"' EXIT

# Size from stty on the tty itself, not tput: inside command substitution
# tput's stdout is a pipe, so ncurses falls back to asking stderr — and
# with stderr redirected it reports the terminfo default 24x80, which sizes
# the page for a third of the screen.
size=$(stty size < /dev/tty 2>/dev/null || echo '30 100')
cols=${size##* }
# The list side of the split — what the header lines and the rows have to
# fit into, minus fzf's own gutter and the preview border.
PREVIEW_PCT="${CLAUDE_TMUX_TOKEN_PREVIEW_WIDTH:-52}"
list_w=$(( cols - cols * PREVIEW_PCT / 100 - 4 ))
[ "$list_w" -lt 40 ] && list_w=40

# The window you asked for, scanned now: the page can't draw without it.
"${PY[@]}" --scan --days "$days" --cache "$CACHE_DIR/$days.json" || true
# The other one, warmed in the background — switching windows is the only
# thing left here that costs a scan, and it is the key most likely to be
# pressed within seconds of the page opening. If you beat the warmer to it
# the bind's own --scan does the work instead: duplicated, never corrupt
# (token-report.py replaces the cache atomically).
other=7; [ "$days" -gt 1 ] && other=1
( "${PY[@]}" --scan --days "$other" --cache "$CACHE_DIR/$other.json" \
    >/dev/null 2>&1 & ) || true

rows() {   # $1 = cache file
  printf 'python3 %q --rows --cache %q --width %s' "$REPORT" "$1" "$list_w"
}
head_of() { # $1 = cache file
  printf 'python3 %q --overview --cache %q --width %s' "$REPORT" "$1" "$list_w"
}
switch() {  # $1 = days — the three actions a window switch takes
  local c="$CACHE_DIR/$1.json"
  printf 'execute-silent(python3 %q --scan --days %s --cache %q)' "$REPORT" "$1" "$c"
  printf '+reload-sync(%s)+transform-header(%s)+first' "$(rows "$c")" "$(head_of "$c")"
}

KEYS='1 今日 · 7 近 7 天 · j/k 选会话 · Enter 跳过去 · p 预览 · r 重新统计 · q 返回'
FOOTER=$'\033[2m  '"$KEYS"$'\033[0m'
# What Enter says when the session it is on has already closed. Built here
# so the keys come back with it — a footer that only carried the warning
# would take the hints away for the rest of the page's life.
export TOKEN_FOOTER_WARN=$'  \033[33m⚠ 这个会话已经不在 tmux 里了,跳不过去\033[0m  \033[2m'"$KEYS"$'\033[0m'

# --disabled --no-input: no search box, so letters are inert unless bound —
# the same navigation model as the picker, and it means a stray keypress
# can't drop you out of the page by accident. Enter goes through
# token-jump.sh rather than fzf's `accept`, because a row here is a jump
# target and not all of them are reachable — see that script.
#
# Deliberately no --height: fzf then runs full-screen on the alternate
# buffer, so leaving the page restores the picker's screen underneath
# instead of making it redraw.
fzf --ansi --delimiter=$'\t' --with-nth=1 --disabled --no-input \
  --layout=reverse \
  --header="$("${PY[@]}" --overview --cache "$CACHE_DIR/$days.json" --width "$list_w")" \
  --footer="$FOOTER" \
  --preview "python3 $(printf '%q' "$REPORT") --detail {2} --cache {3} --width \${FZF_PREVIEW_COLUMNS:-80} --lines \${FZF_PREVIEW_LINES:-40}" \
  --preview-window="right,${PREVIEW_PCT}%,border-left,nowrap" \
  --preview-label=' 这个会话花在哪 ' \
  --bind "j:down" --bind "k:up" \
  --bind "1:$(switch 1)" \
  --bind "t:$(switch 1)" \
  --bind "7:$(switch 7)" \
  --bind "r:execute-silent(python3 $(printf '%q' "$REPORT") --scan --force --cache {3})+reload-sync(python3 $(printf '%q' "$REPORT") --rows --cache {3} --width $list_w)+transform-header(python3 $(printf '%q' "$REPORT") --overview --cache {3} --width $list_w)" \
  --bind "p:toggle-preview" \
  --bind "enter:transform($BIN_DIR/token-jump.sh {4})" \
  --bind "q:abort" \
  < <("${PY[@]}" --rows --cache "$CACHE_DIR/$days.json" --width "$list_w") \
  >/dev/null || true
