#!/usr/bin/env bash
# The picker's overview page: full-screen "I'm back — what's the situation",
# opened with `o` and left with q/Esc/Enter. bin/overview.py owns the panes
# and the teams; bin/usage-footer.sh — printed here verbatim — owns the 5h
# quota, the 7-day window and today's tokens. This script owns the screen.
#
# It renders once and then waits. Unlike the token page there is nothing to
# switch, so no keypress re-runs anything: `r` refreshes on purpose, and
# every other key is ignored rather than costing a redraw. That matters
# because the two halves are not equally cheap — the pane half is ~0.06s
# (one status file, one tmux call, one roster) while the footer half reads
# transcripts and costs ~0.5s.
set -euo pipefail

BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DIM=$'\033[2m'
RESET=$'\033[0m'

# Bound directly to `o` in the picker (see the comment there), so it also
# fires while the search input is open — where `o` must type an o, not open
# a page. fzf exports the input state to every child process.
if [ "${FZF_INPUT_STATE:-disabled}" = "enabled" ]; then
  exit 0
fi

while :; do
  # Size from stty on the tty itself, not tput: inside command substitution
  # tput's stdout is a pipe, so ncurses falls back to asking stderr — and
  # with stderr redirected it reports the terminfo default 24x80, which
  # sizes the page for a third of the screen.
  size=$(stty size < /dev/tty 2>/dev/null || echo '30 100')
  lines=${size%% *}
  cols=${size##* }
  # Rows left for the two pane lists after the three-line heading, the team
  # block, the footer and this page's own last line. Deliberately generous
  # about the team block: it is the part that varies, and overview.py caps
  # the lists rather than letting them push the footer off screen.
  budget=$(( lines - 22 ))
  [ "$budget" -lt 3 ] && budget=3

  clear
  echo
  python3 "$BIN_DIR/overview.py" --width "$cols" --top "$budget" || true
  echo
  bash "$BIN_DIR/usage-footer.sh" 2>/dev/null || true
  echo
  echo "${DIM}  r 刷新 · q 返回${RESET}"

  # -s: don't echo the key; -n1: a single character, no Enter needed.
  # Explicitly from /dev/tty: the picker feeds fzf its rows on stdin, and a
  # child of fzf's execute() inherits that same (already-exhausted) pipe —
  # so a plain `read` returns instantly at EOF and the page flashes past.
  key=""
  IFS= read -rsn1 key < /dev/tty || true
  case "$key" in
    r|o) : ;;                      # redraw
    *)   break ;;                  # q, Enter (empty), Esc, anything else
  esac
done

clear
