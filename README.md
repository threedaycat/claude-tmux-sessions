# claude-tmux-sessions

Run multiple [Claude Code](https://claude.com/claude-code) sessions across
tmux windows, and jump straight to the one that just finished — without
tabbing through windows one by one.

Claude Code hooks record `running` / `done` status per tmux pane; an
`fzf`-powered popup lets you pick a session, then a window/pane inside it,
and switches you there.

## Why

If you keep several Claude Code sessions going in parallel (different tmux
windows, different projects), you end up polling windows to see which one
is idle and waiting on you. This tracks that state automatically and gives
you a one-key picker to jump to it.

## How it works

- A `UserPromptSubmit` hook marks the current pane `running`.
- A `Stop` hook marks it `done` (Claude finished its turn and is waiting on
  you).
- Both write to `~/.claude/tmux-claude-status.json`, keyed by tmux pane id
  (`$TMUX_PANE`). Sessions running outside tmux are silently ignored.
- `bin/claude-tmux-picker.sh` reads that file, cross-checks against
  `tmux list-panes -a` (so closed panes disappear automatically), and shows
  a two-level `fzf` picker: pick a **session** (with done/running counts),
  then pick a **window/pane** inside it — with a live preview pane on the
  right showing that pane's actual terminal content (`tmux capture-pane`),
  updating as you move the selection. Enter jumps there (`switch-client` +
  `select-window` + `select-pane`); Esc at the pane level goes back to the
  session list.

## Requirements

- tmux
- [fzf](https://github.com/junegunn/fzf)
- python3
- Claude Code with hooks support

## Install

```bash
git clone <this-repo> ~/projects/claude-tmux-sessions
~/projects/claude-tmux-sessions/install.sh
```

This symlinks the two scripts into `~/.claude/hooks/` and merges the
`UserPromptSubmit`/`Stop` hooks into `~/.claude/settings.json` (existing
settings are preserved, not overwritten).

Then add a tmux binding for the popup — this is the one step the installer
leaves to you, since tmux configs vary. In `~/.tmux.conf` (or
`~/.tmux.conf.local` if you use [gpakosz/.tmux](https://github.com/gpakosz/.tmux)):

```tmux
bind g display-popup -w 90% -h 60% -E "~/.claude/hooks/claude-tmux-picker.sh"
```

Reload with `tmux source-file ~/.tmux.conf`, then in any already-running
Claude Code session run `/hooks` once so it picks up the new config
(freshly started sessions pick it up automatically).

## Use

Press `prefix + g` (or whatever key you bound) anywhere in tmux:

1. Pick a tmux session — shown with `✅ N done  🏃 N running` counts.
2. Pick a window/pane inside that session — `DONE`/`RUN` label, how long
   ago, window name, cwd — with a live content preview on the right.
3. Enter jumps you there.

## Notes

- If your tmux config sets `automatic-rename-format '#{pane_title}'` (as
  [gpakosz/.tmux](https://github.com/gpakosz/.tmux) does), Claude Code's own
  terminal-title updates (spinner while working, idle indicator) already
  drive your tmux window names — this tool is independent of that and reads
  its own state file, so the two don't conflict.
- The status file only grows with tracked panes; stale entries (pane
  closed) are filtered at display time, not deleted, so it stays small in
  practice but isn't actively pruned.

## License

MIT
