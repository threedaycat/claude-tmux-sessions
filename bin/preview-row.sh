#!/usr/bin/env bash
# fzf --preview command for claude-tmux-picker.sh. Branches on row kind:
# a session row (S) previews that session's pane summary; a pane row (P)
# previews the pane's live terminal content.
set -euo pipefail

BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
kind="${1:-}"
target="${2:-}"

if [ "$kind" = "S" ]; then
  "$BIN_DIR/session-preview.sh" "$target"
else
  tmux capture-pane -p -e -S -200 -t "$target" 2>&1 || echo "(pane 已关闭或无法读取)"
fi
