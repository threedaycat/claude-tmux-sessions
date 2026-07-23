#!/usr/bin/env bash
# fzf preview for one picker row.
# args: $1 = pane_id (empty on session header rows), $2 = session name
# Pane row: show that pane. Header row (session-select mode): show the
# session's currently active pane — what you'd land on if you hit Enter.
pane="${1:-}"
session="${2:-}"

if [ -n "$pane" ]; then
  tmux capture-pane -p -e -S -200 -t "$pane" 2>&1 || echo "(pane 已关闭或无法读取)"
elif [ -n "$session" ]; then
  # "=name:" — exact session match, trailing colon = its current window's
  # active pane (a bare "=name" is rejected by capture-pane).
  tmux capture-pane -p -e -S -200 -t "=$session:" 2>&1 || echo "(session 已关闭或无法读取)"
fi
