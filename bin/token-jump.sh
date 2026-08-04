#!/usr/bin/env bash
# Enter on a token-page row: hand the picker a pane to jump to, or say why
# it can't.
#
# args: $1 = pane id (row field 4; empty when the session has no pane)
#
# Printed as a transform, so this can only answer in fzf actions — which is
# exactly enough. A live pane goes into $JUMP_FILE and the page aborts; the
# picker checks that file when its own fzf exits and jumps there, so the
# jump is done by the one script that already knows how to do it (existence
# check, mark-read, switch-client/select-window/select-pane).
#
# **A dead row must not leave the page.** Half of what a token ranking shows
# is sessions that have already closed — that is what the 7-day window is
# for — and quietly exiting on Enter there would read as a failed jump. So
# that case changes the footer instead and stays put.
set -uo pipefail

pane="${1:-}"

# `has-session`, not `display-message -p -t <pane> ''`: that one exits 0 for a
# pane id that no longer exists (measured — `%99999` returns success and an
# empty format), so it can't tell a dead pane from a live one. The empty-target
# case has to be excluded first, since `has-session -t ""` also exits 0.
if [ -n "$pane" ] && tmux has-session -t "$pane" 2>/dev/null; then
  if [ -n "${JUMP_FILE:-}" ]; then
    printf '%s' "$pane" > "$JUMP_FILE" 2>/dev/null || true
    echo "abort"
  else
    # Launched outside the picker (running token-page.sh by hand). Nobody is
    # going to read a handoff file, so do the switch here and leave.
    tmux switch-client -t "$pane" 2>/dev/null || true
    tmux select-window -t "$pane" 2>/dev/null || true
    tmux select-pane -t "$pane" 2>/dev/null || true
    echo "abort"
  fi
  exit 0
fi

echo "change-footer(${TOKEN_FOOTER_WARN:-  这个会话已经不在 tmux 里了,跳不过去})"
