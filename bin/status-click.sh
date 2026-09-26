#!/usr/bin/env bash
# status-click.sh — what a click on one of status-badge.sh's segments does.
#
#   status-click.sh <mouse_status_range> <pane> <client>
#
# status-badge.sh wraps each clickable segment in #[range=user|<name>], and
# tmux reports that name as #{mouse_status_range} on MouseDown1Status:
#
#   quota        refresh the 5h/7d usage now, then a card with the numbers
#   w%<pane>     jump to that waiting (blocked) Claude
#   done         picker, just the finished-unread panes, from the right
#   running      picker, just the running panes, from the right
#
# Anything else (plain status-right text) is ignored. The window list is not
# routed here — the binding keeps tmux's own switch-client for that.

BIN_DIR="$(cd "$(dirname "$(readlink "$0" || echo "$0")")" && pwd)"
range="${1:-}"; pane="${2:-}"; client="${3:-}"

case "$range" in
  quota)        exec "$BIN_DIR/usage-refresh.py" --force --notify --client "$client" ;;   # then a card with the numbers
  w%*)          exec "$BIN_DIR/jump-top.sh" "${range#w}" ;;
  done|running) CLAUDE_TMUX_USAGE_FOOTER=0 exec "$BIN_DIR/float-picker.sh" "$pane" "$range" ;;
esac
