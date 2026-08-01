#!/usr/bin/env bash
# fzf preview for one picker row.
# args: $1 = pane_id (empty on session header / extra / team rows)
#       $2 = session name (the team name on team rows, empty on extra rows)
#       $3 = kind ("extra" on provider rows, "team" on Agent Teams block
#            headers, empty otherwise)
#       $4 = opaque id ($3 == "extra") or the team name ($3 == "team")
#
# Pane row: show that pane's screen, full depth.
# Header row (session-select mode): session-digest.py renders one compact
# card per tracked Claude pane — name/status/age, model + context size,
# and a recap of Claude's last reply pulled from the transcript — so one
# glance answers "what's everyone in this session up to".
# Extra row: hand off to the provider that listed it (see DESIGN.md,
# "External item provider") — this script doesn't know what the row means.
set -euo pipefail

pane="${1:-}"
session="${2:-}"
kind="${3:-}"
item_id="${4:-}"

SCRIPT_PATH="${BASH_SOURCE[0]}"
[ -L "$SCRIPT_PATH" ] && SCRIPT_PATH="$(readlink "$SCRIPT_PATH")"
BIN_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"

if [ "$kind" = "team" ]; then
  # Team block header: the roster, the shared task list, and the members
  # this list has no row for. Nothing live to capture here, so the whole
  # preview is the board.
  python3 "$BIN_DIR/session-digest.py" --team "$item_id" 2>/dev/null \
    || echo "(读不到这个编队)"
  exit 0
fi

if [ "$kind" = "extra" ]; then
  if [ -n "${CLAUDE_TMUX_EXTRA_CMD:-}" ] && [ -x "${CLAUDE_TMUX_EXTRA_CMD}" ]; then
    "$CLAUDE_TMUX_EXTRA_CMD" preview "$item_id" 2>&1 \
      || echo "(provider 没能给出预览)"
  fi
  exit 0
fi

if [ -n "$pane" ]; then
  # Claude-Code-statusline-style bar on top (status · model · ctx ·
  # elapsed · cwd) — the raw screen dump alone doesn't tell you the
  # things you actually triage by.
  python3 "$BIN_DIR/session-digest.py" --pane "$pane" 2>/dev/null || true
  tmux capture-pane -p -e -S -200 -t "$pane" 2>&1 || echo "(pane 已关闭或无法读取)"
  exit 0
fi

[ -n "$session" ] || exit 0

digest="$(python3 "$BIN_DIR/session-digest.py" "$session" 2>/dev/null || true)"

if [ -n "$digest" ]; then
  printf '%s\n' "$digest"
else
  # Session exists but has no tracked Claude panes — fall back to its
  # active pane. Resolved by exact string match over list-panes instead
  # of a "=$session:" target, because tmux allows ':' and '.' in session
  # names and those would derail target parsing.
  active=$(tmux list-panes -a \
      -F "#{session_name}	#{window_active}#{pane_active}	#{pane_id}" 2>/dev/null \
    | awk -F'\t' -v s="$session" '$1==s && $2=="11" { print $3; exit }')
  if [ -n "$active" ]; then
    tmux capture-pane -p -e -S -200 -t "$active" 2>&1 || echo "(session 已关闭或无法读取)"
  else
    echo "(session 已关闭或无法读取)"
  fi
fi
