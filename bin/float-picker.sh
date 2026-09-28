#!/usr/bin/env bash
# float-picker.sh — the picker in a floating pane anchored bottom-left,
# exactly as tall as its content, closed by clicking anywhere else.
#
#   float-picker.sh <caller-pane> [kind] [width]
#     kind:  all (default) | done | running | wait — which panes to list
#            (CLAUDE_TMUX_ONLY). List on the left, preview on the right,
#            whichever kind — they all open from the left end of the bar.
#     width: columns or N% (default: full width)
#
# e.g. bound to a click on the session name in the status bar:
#   bind -n MouseDown1StatusLeft run-shell '~/.claude/hooks/float-picker.sh #{pane_id}'
#
# Why a floating pane (tmux 3.7+ `new-pane` without -h/-v) and not
# display-popup: a popup swallows every click outside its box (popup.c drops
# them), so "click elsewhere to cancel" is impossible there. A floating pane
# is a real pane — clicking another pane moves focus, and a pane-focus-out
# hook on it closes it. Focus-out also fires when the picker itself jumps
# away, so the close waits a moment: the jump is several tmux calls and must
# finish before the pane goes.
#
# Clicking the session name again while it is open closes it (toggle).
# Height = rows + header, capped at CLAUDE_TMUX_POPUP_MAX_H% (default 60) of
# the window; the list is top-down and the box's bottom edge sits on the
# status line, so there's no blank band between the last row and the bar.
# Extra env for the picker (CLAUDE_TMUX_USAGE_FOOTER=0 and the like) is
# passed through with -e.

set -uo pipefail
BIN_DIR="$(cd "$(dirname "$(readlink "$0" || echo "$0")")" && pwd)"

SELF="$BIN_DIR/$(basename "$0")"

# 浮窗的 pane-focus-out 钩子走到这里：这次失焦到底是不是「点了浮窗外面」。
# tmux 开着 focus-events，整个终端窗口失焦（切去 Chrome、切去别的 App）也会给活动窗格
# 发一次 pane-focus-out，跟点浮窗外面长得一模一样，以前会把 picker 一起关掉。
# 等 0.4 秒再看（picker 自己跳走时要好几次 tmux 调用，得让它走完）：浮窗仍是当前窗口的
# 活动窗格，就是终端自己失焦，留着。
if [ "${1:-}" = --maybe-close ]; then
  fp="$2"
  sleep 0.4
  still=$(tmux display -p -t "$fp" '#{&&:#{pane_active},#{window_active}}' 2>/dev/null) || exit 0
  [ "$still" = 1 ] && exit 0
  tmux kill-pane -t "$fp" 2>/dev/null || true
  exit 0
fi

caller="$1"; kind="${2:-all}"; width="${3:-}"
# While a float is open it *is* the active pane, so a click on the status
# bar reports the float itself as the caller. Swap in the pane the float was
# opened from — otherwise the toggle below kills the float and then tries to
# open the new one next to a pane that no longer exists.
if [ -n "$(tmux show -pqv -t "$caller" @picker_float 2>/dev/null)" ]; then
  orig=$(tmux show -pqv -t "$caller" @picker_caller 2>/dev/null)
  [ -n "$orig" ] && caller="$orig"
fi
window=$(tmux display -p -t "$caller" '#{window_id}')

# Toggle: clicking what opened the float again closes it; clicking a
# different kind (✔ while the full list is open) swaps it for that one.
read -r open open_kind < <(tmux list-panes -t "$window" -F '#{pane_id} #{@picker_float}' \
  | awk '$2!=""{print; exit}')
if [ -n "${open:-}" ]; then
  tmux kill-pane -t "$open"
  # FLOAT_REOPEN: the float asked to be rebuilt at a new height (`a` inside
  # it — see skip-header.sh showall), so the same kind means reopen, not close.
  [ "$open_kind" = "$kind" ] && [ -z "${FLOAT_REOPEN:-}" ] && exit 0
fi
if [ "$kind" != all ]; then
  export CLAUDE_TMUX_ONLY="$kind"
fi

# Same CALLER_PANE the picker will get: the caller's group is never
# collapsed, so from some panes the list is a row or two longer.
rows=$(env -u CLAUDE_TMUX_EXTRA_CMD CALLER_PANE="$caller" "$BIN_DIR/list-rows.sh" 2>/dev/null | wc -l | tr -d ' ')
h=$(( rows + 1 ))                       # + the key-hint header
[ "$h" -lt 6 ] && h=6
win_h=$(tmux display -p -t "$caller" '#{window_height}')
# Full width by default, so the preview on the right is as wide as the panes
# it shows. tmux caps a floating pane at window width - 1 (that last column
# is its right border).
[ -n "$width" ] || width=$(( $(tmux display -p -t "$caller" '#{window_width}') - 1 ))
cap=$(( win_h * ${CLAUDE_TMUX_POPUP_MAX_H:-60} / 100 ))
[ "$h" -gt "$cap" ] && h=$cap
y=$(( win_h - h - 1 ))                  # leave the bottom border its row
[ "$y" -lt 1 ] && y=1

envs=()
for v in CLAUDE_TMUX_USAGE_FOOTER CLAUDE_TMUX_PREVIEW_WIDTH CLAUDE_TMUX_SHOW_ALL \
         CLAUDE_TMUX_ONLY CLAUDE_TMUX_PREVIEW_SIDE; do
  [ -n "${!v:-}" ] && envs+=(-e "$v=${!v}")
done

fp=$(tmux new-pane -t "$caller" -P -F '#{pane_id}' -x "$width" -y "$h" -X 0 -Y "$y" \
  ${envs[@]+"${envs[@]}"} -e "CALLER_PANE=$caller" \
  "$BIN_DIR/claude-tmux-picker.sh") || exit 1

tmux set -p -t "$fp" @picker_float "$kind"
tmux set -p -t "$fp" @picker_caller "$caller"
tmux set-hook -p -t "$fp" pane-focus-out \
  "run-shell -b '\"$SELF\" --maybe-close $fp'"
