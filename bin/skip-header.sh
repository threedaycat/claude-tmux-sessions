#!/usr/bin/env bash
# Called by fzf's up/down/load bind transforms to skip over session-header
# rows so arrow keys only ever land on pane rows.
# args: $1 = current 0-based item index ({n}), $2 = direction (up/down/init)
#
# Recomputes the row list itself (via list-rows.sh) on every call instead
# of trusting a snapshot passed in once at fzf startup, since archiving a
# pane reshuffles positions mid-session via fzf's reload() action.
set -euo pipefail

BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cur="${1:-0}"
dir="${2:-down}"

rows="$("$BIN_DIR/list-rows.sh")"
TOTAL=$(printf '%s\n' "$rows" | wc -l | tr -d ' ')
HEADER_POS=",$(printf '%s\n' "$rows" | awk -F'\t' '{ if ($2 == "") print NR }' | paste -sd, -),"

is_header() {
  [[ "$HEADER_POS" == *",$1,"* ]]
}

orig=$(( cur + 1 ))  # 1-based current position; fallback if no valid target found

case "$dir" in
  down)
    idx=$(( cur + 2 ))
    step=1
    ;;
  up)
    idx=$(( cur ))
    step=-1
    ;;
  init)
    idx=1
    step=1
    orig=1
    ;;
esac

while [ "$idx" -ge 1 ] && [ "$idx" -le "$TOTAL" ] && is_header "$idx"; do
  idx=$(( idx + step ))
done

if [ "$idx" -lt 1 ] || [ "$idx" -gt "$TOTAL" ] || is_header "$idx"; then
  idx="$orig"
fi

echo "pos($idx)"
