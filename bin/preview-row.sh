#!/usr/bin/env bash
# fzf preview for one picker row.
# args: $1 = pane_id (empty on session header rows), $2 = session name
#
# Pane row: show that pane's screen, full depth.
# Header row (session-select mode): session-digest.py renders one compact
# card per tracked Claude pane — name/status/age, model + context size,
# and a recap of Claude's last reply pulled from the transcript — so one
# glance answers "what's everyone in this session up to".
set -euo pipefail

pane="${1:-}"
session="${2:-}"

if [ -n "$pane" ]; then
  tmux capture-pane -p -e -S -200 -t "$pane" 2>&1 || echo "(pane 已关闭或无法读取)"
  exit 0
fi

[ -n "$session" ] || exit 0

SCRIPT_PATH="${BASH_SOURCE[0]}"
[ -L "$SCRIPT_PATH" ] && SCRIPT_PATH="$(readlink "$SCRIPT_PATH")"
BIN_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"

digest="$(python3 "$BIN_DIR/session-digest.py" "$session" 2>/dev/null || true)"

if [ -n "$digest" ]; then
  printf '%s\n' "$digest"
else
  # Session exists but has no tracked Claude panes — fall back to its
  # active pane. "=name:" — exact session match, trailing colon = its
  # current window's active pane (a bare "=name" is rejected).
  tmux capture-pane -p -e -S -200 -t "=$session:" 2>&1 || echo "(session 已关闭或无法读取)"
fi
