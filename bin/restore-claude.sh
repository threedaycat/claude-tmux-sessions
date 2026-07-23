#!/usr/bin/env bash
# After tmux-resurrect rebuilds the layout (panes, cwds, window names),
# it can't bring the Claude Code sessions back — this can. It walks the
# restore map (~/.claude/tmux-claude-restore.json, maintained by the
# hooks: stable "session:window.pane" coordinates -> Claude session_id)
# and types `claude --resume <session_id>` into every matching pane that
# is sitting at a plain shell in the recorded cwd.
#
# Safe to run repeatedly: panes already running something (including a
# resumed Claude) are skipped, as are coordinates whose cwd no longer
# matches. Pass --dry-run to see what it would do without touching
# anything.
#
# Wire it to tmux-resurrect so it runs on every restore:
#   set -g @resurrect-hook-post-restore-all '~/.claude/hooks/restore-claude.sh'
# or bind it to a key / run it by hand after `prefix + Ctrl-r`.
set -euo pipefail

RESTORE_FILE="$HOME/.claude/tmux-claude-restore.json"
DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

[ -s "$RESTORE_FILE" ] || exit 0

resumed=$(python3 - "$RESTORE_FILE" "$DRY_RUN" <<'PYEOF'
import json, shlex, subprocess, sys

restore_file, dry_run = sys.argv[1], sys.argv[2] == "1"
with open(restore_file) as f:
    mapping = json.load(f)

fmt = "#{session_name}:#{window_index}.#{pane_index}\t#{pane_id}\t#{pane_current_command}\t#{pane_current_path}"
try:
    out = subprocess.check_output(["tmux", "list-panes", "-a", "-F", fmt], text=True)
except Exception:
    sys.exit(0)

SHELLS = {"zsh", "bash", "fish", "sh", "dash", "ksh", "tcsh", "nu"}

panes = {}
for line in out.splitlines():
    parts = line.split("\t")
    if len(parts) == 4:
        panes[parts[0]] = parts[1:]

count = 0
for key, e in mapping.items():
    if key not in panes:
        continue
    pane_id, cmd, cwd = panes[key]
    if cmd not in SHELLS:
        continue  # busy (maybe Claude already resumed) — hands off
    if e.get("cwd") and e["cwd"] != cwd:
        continue  # layout changed since the mapping was recorded
    sid = e.get("session_id")
    if not sid:
        continue
    if dry_run:
        print(f"would resume {key} ({pane_id}, {cwd}): claude --resume {sid}", file=sys.stderr)
        count += 1
        continue
    subprocess.run(
        ["tmux", "send-keys", "-t", pane_id,
         f"claude --resume {shlex.quote(sid)}", "Enter"],
        check=False,
    )
    count += 1

print(count)
PYEOF
)

if [ "$DRY_RUN" = "1" ]; then
  exit 0
fi

if [ "${resumed:-0}" -gt 0 ] 2>/dev/null; then
  tmux display-message "已恢复 $resumed 个 Claude Code 会话"
fi
