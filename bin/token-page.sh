#!/usr/bin/env bash
# The picker's token page: full-screen "where did the tokens go", opened
# with `t` and left with q/Esc/Enter. bin/token-report.py does the
# counting; this only owns the screen — sizing the report to the terminal
# and switching the window between today and the last 7 days.
#
# It's a read-key loop rather than a second fzf instance because the page
# isn't a list: nothing here is selectable, and nesting fzf inside fzf's
# execute() would mean two sets of key bindings fighting over j/k for no
# gain. `1` / `7` re-render in place; anything else is ignored, so a
# stray keypress can't drop you out of the page by accident.
set -euo pipefail

BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DIM=$'\033[2m'
RESET=$'\033[0m'

days="${1:-1}"

# Bound directly to `t` in the picker (see the comment there), so it also
# fires while the search input is open — where `t` must type a t, not open
# a page. fzf exports the input state to every child process.
if [ "${FZF_INPUT_STATE:-disabled}" = "enabled" ]; then
  exit 0
fi

while :; do
  # Size from stty on the tty itself, not tput: inside command substitution
  # tput's stdout is a pipe, so ncurses falls back to asking stderr — and
  # with stderr redirected (as it was here, to swallow errors) it finds no
  # terminal at all and reports the terminfo default 24x80. The page then
  # sized itself for a screen a third the real height.
  size=$(stty size < /dev/tty 2>/dev/null || echo '30 100')
  lines=${size%% *}
  cols=${size##* }
  # Rows left for the ranking after the overview block, the two table
  # header lines, the two footnotes and this page's own footer.
  top=$(( lines - 17 ))
  [ "$top" -lt 3 ] && top=3

  clear
  echo
  python3 "$BIN_DIR/token-report.py" --days "$days" --top "$top" --width "$cols" || true
  echo
  if [ "$days" -le 1 ]; then
    echo "${DIM}  1 今日 · 7 近 7 天 · q 返回        [今日]${RESET}"
  else
    echo "${DIM}  1 今日 · 7 近 7 天 · q 返回        [近 7 天]${RESET}"
  fi

  # -s: don't echo the key; -n1: a single character, no Enter needed.
  # Explicitly from /dev/tty: the picker feeds fzf its rows on stdin, and a
  # child of fzf's execute() inherits that same (already-exhausted) pipe —
  # so a plain `read` returns instantly at EOF and the page flashes past
  # without ever showing.
  key=""
  IFS= read -rsn1 key < /dev/tty || true
  case "$key" in
    1|t) days=1 ;;
    7)   days=7 ;;
    q|"") break ;;                 # q, or Enter (read as empty)
    $'\033') break ;;              # Esc — one read, so no arrow-key tail
  esac
done

clear
