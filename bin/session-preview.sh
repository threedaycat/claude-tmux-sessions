#!/usr/bin/env bash
# Right-hand preview while browsing at the session level: a plain summary
# of that session's tracked panes (status/age/window/cwd), not raw
# terminal content — you haven't picked a specific pane yet.
set -euo pipefail

BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
session="${1:-}"
[ -n "$session" ] || exit 0

out="$("$BIN_DIR/list-rows.sh" "$session" | cut -f1)"
if [ -z "$out" ]; then
  echo "(这个 session 下没有追踪到的 pane)"
else
  printf '%s\n' "$out"
fi
