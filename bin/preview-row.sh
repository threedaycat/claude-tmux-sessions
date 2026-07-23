#!/usr/bin/env bash
# fzf preview for one picker row.
# args: $1 = pane_id (empty on session header rows), $2 = session name
#
# Pane row: show that pane's screen, full depth.
# Header row (session-select mode): a digest of every tracked Claude pane
# in that session — its (already colored/padded) picker row as a title,
# then the tail of its screen — so one glance answers "what's everyone in
# this session up to". The per-pane tail length adapts to the preview
# window height (fzf exports FZF_PREVIEW_LINES).
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

# This session's tracked pane rows, in the same order/colors as the list.
rows="$("$BIN_DIR/list-rows.sh" | awk -F'\t' -v s="$session" '$3==s && $2!="" {print $2 "\t" $1}')"

if [ -z "$rows" ]; then
  # Session exists but has no tracked Claude panes — fall back to its
  # active pane. "=name:" — exact session match, trailing colon = its
  # current window's active pane (a bare "=name" is rejected).
  tmux capture-pane -p -e -S -200 -t "=$session:" 2>&1 || echo "(session 已关闭或无法读取)"
  exit 0
fi

count=$(printf '%s\n' "$rows" | wc -l | tr -d ' ')
avail="${FZF_PREVIEW_LINES:-40}"
# 2 overhead lines per pane (title + separator)
per=$(( avail / count - 2 ))
[ "$per" -lt 4 ] && per=4
[ "$per" -gt 20 ] && per=20

first=1
while IFS=$'\t' read -r p display; do
  [ "$first" -eq 1 ] || printf '\033[2m%s\033[0m\n' '──────────────────────────────────────'
  first=0
  printf '%s\n' "$display"
  tmux capture-pane -p -e -t "$p" 2>/dev/null \
    | sed -e 's/[[:space:]]*$//' \
    | awk 'NF { blank=0 } !NF { blank++ } blank<2' \
    | tail -n "$per" \
    | sed -e 's/^/  /'
done <<< "$rows"
