#!/usr/bin/env bash
# The picker's overview page: full-screen "I'm back — what's the situation",
# opened with `o` and left with q/Esc. bin/overview.py owns the cards;
# bin/usage-footer.sh — printed into fzf's footer verbatim — owns the 5h
# quota, the 7-day window and today's tokens. This script owns the screen.
#
# An fzf list, like the token page and for the same reason: the cards are
# rows, and a row you can put the cursor on is a row you can jump to. The
# preview is deliberately *not* the pane's screen — the picker's own list
# already is that, and a second copy of it here would say nothing new.
# It is the pane's state: where it is, how long it has been there, how full
# its context is, which team owns it, what it has cost today.
#
# Costs, so the shape below makes sense: the cards are ~0.06s (one status
# file, one tmux call, one roster), a card preview adds a transcript tail
# read, the quota footer costs ~0.5s and is computed once, and the token
# figures come from a token-report cache warmed in the background — a card
# drawn before it lands simply has no 今日 line.
set -euo pipefail

BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OVERVIEW="$BIN_DIR/overview.py"

# Bound directly to `o` in the picker (see the comment there), so it also
# fires while the search input is open — where `o` must type an o, not open
# a page. fzf exports the input state to every child process.
if [ "${FZF_INPUT_STATE:-disabled}" = "enabled" ]; then
  exit 0
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/claude-tmux-overview.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
TOKENS="$WORK/today.json"

# Size from stty on the tty itself, not tput: inside command substitution
# tput's stdout is a pipe, so ncurses falls back to asking stderr — and with
# stderr redirected it reports the terminfo default 24x80, which sizes the
# page for a third of the screen.
size=$(stty size < /dev/tty 2>/dev/null || echo '30 100')
cols=${size##* }
PREVIEW_PCT="${CLAUDE_TMUX_OVERVIEW_PREVIEW_WIDTH:-46}"
list_w=$(( cols - cols * PREVIEW_PCT / 100 - 4 ))
[ "$list_w" -lt 40 ] && list_w=40

# Today's tokens, in the background: the cards don't need them and the
# preview degrades without them, so nothing waits on this.
( python3 "$BIN_DIR/token-report.py" --scan --days 1 --cache "$TOKENS" \
    >/dev/null 2>&1 & ) || true

KEYS='j/k 选 · Enter 跳过去 · p 预览 · r 刷新 · q 返回'
# The resource block *is* the footer, so it stays on screen while you walk
# the cards instead of sitting at the bottom of a page you scrolled off.
# Computed once — it reads transcripts, and none of the keys here change it.
FOOTER="$(bash "$BIN_DIR/usage-footer.sh" 2>/dev/null || true)"
FOOTER="$FOOTER"$'\n'$'\033[2m  '"$KEYS"$'\033[0m'
# Both versions on disk, because every footer swap below goes through
# `transform-footer(cat …)`: the quota block contains `(07-31)`, and inlining
# it into an fzf action would put unbalanced-looking brackets in a string fzf
# parses by matching parentheses.
printf '%s\n' "$FOOTER" > "$WORK/footer"
printf '%s\n' "$FOOTER" $'  \033[33m⚠ 这一行没有可以跳过去的 pane\033[0m' > "$WORK/footer.warn"
export JUMP_WARN_FILE="$WORK/footer.warn"

# Rebuild everything the state can have changed — rows, greeting, and the
# footer, which may still be carrying an Enter warning from a row that had
# nothing to jump to. The quota numbers in it are deliberately *not* recomputed:
# they cost ~0.5s and a refresh here is about the panes.
REDRAW="reload-sync(python3 $(printf '%q' "$OVERVIEW") --rows --width $list_w)"
REDRAW="$REDRAW+transform-header(python3 $(printf '%q' "$OVERVIEW") --head --width $list_w)"
REDRAW="$REDRAW+transform-footer(cat $(printf '%q' "$WORK/footer"))"

# --disabled --no-input: no search box, so letters are inert unless bound.
# Enter goes through jump-handoff.sh rather than fzf's `accept` because not
# every row is reachable — the blank lines between cards and the teammates
# with no pane aren't — and those have to say so rather than exit.
#
# Deliberately no --height: fzf then runs full-screen on the alternate
# buffer, so leaving restores the picker's screen underneath.
fzf --ansi --delimiter=$'\t' --with-nth=1 --disabled --no-input \
  --layout=reverse \
  --header="$(python3 "$OVERVIEW" --head --width "$list_w")" \
  --footer="$FOOTER" \
  --preview "python3 $(printf '%q' "$OVERVIEW") --card {3} --tokens $(printf '%q' "$TOKENS") --width \${FZF_PREVIEW_COLUMNS:-80}" \
  --preview-window="right,${PREVIEW_PCT}%,border-left,nowrap" \
  --preview-label=' 现在什么状态 ' \
  --bind "j:down" --bind "k:up" \
  --bind "p:toggle-preview" \
  --bind "r:$REDRAW" --bind "o:$REDRAW" \
  --bind "enter:transform($BIN_DIR/jump-handoff.sh {2})" \
  --bind "q:abort" \
  < <(python3 "$OVERVIEW" --rows --width "$list_w") \
  >/dev/null || true
