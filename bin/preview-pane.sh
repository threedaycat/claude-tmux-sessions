#!/usr/bin/env bash
# Resolve a tree row (session/window/pane) to a concrete pane and dump its
# live content. Called by claude-tmux-picker.sh as the fzf --preview command.
set -euo pipefail

kind="${1:-}"
session="${2:-}"
window_index="${3:-}"
pane_id="${4:-}"

target=""
case "$kind" in
  P) target="$pane_id" ;;
  W) target=$(tmux list-panes -t "${session}:${window_index}" -F '#{pane_id}' 2>/dev/null | head -1) ;;
  S) target=$(tmux display-message -p -t "$session" '#{pane_id}' 2>/dev/null) ;;
esac

if [ -z "$target" ]; then
  echo "(无法定位 pane)"
  exit 0
fi

tmux capture-pane -p -e -S -200 -t "$target" 2>&1 || echo "(pane 已关闭或无法读取)"
