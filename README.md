# claude-tmux-sessions

Run multiple [Claude Code](https://claude.com/claude-code) sessions across
tmux windows, and jump straight to the one that just finished — without
tabbing through windows one by one.

Claude Code hooks record `running` / `done` status per tmux pane; an
`fzf`-powered popup lists every tracked pane (grouped by session) with a
live content preview, and switches you there on Enter.

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
  one `fzf` list where every row is a pane (`DONE`/`RUN`, age, session,
  window, cwd — CJK-width-aware padded so columns line up). Rows are
  grouped by session for readability, but the session itself is never a
  separate selectable stop — only panes are, so every arrow-key move lands
  on an actual Claude Code instance.
- Moving the selection instantly re-runs `tmux capture-pane -S -200` on the
  highlighted pane in the right-hand preview, scrolled to the bottom
  (`follow`) so you always see the most recent output, not the oldest line
  of scrollback. Enter jumps there (`switch-client` + `select-window` +
  `select-pane`); Esc cancels.

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

This symlinks `hooks/tmux_status_update.py` and `bin/claude-tmux-picker.sh`
into `~/.claude/hooks/` and merges the `UserPromptSubmit`/`Stop` hooks into
`~/.claude/settings.json` (existing settings are preserved, not
overwritten).

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

Press `prefix + g` (or whatever key you bound) anywhere in tmux. One list,
grouped by session:

```
news              DONE  57s前   4.1    prototype-redesign      /Users/you/repos/frontend
news              DONE  82s前   3.1    write-readme            /Users/you/repos/backend
fun               RUN   331s前  2.1    tmux-picker             /Users/you
```

Arrow up/down moves between panes only — the right-hand preview instantly
shows that pane's live content, scrolled to the bottom. Enter jumps
immediately; no separate menu, no extra confirmation step.

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
