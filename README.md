# claude-tmux-sessions

Run multiple [Claude Code](https://claude.com/claude-code) sessions across
tmux windows, and jump straight to the one that just finished — without
tabbing through windows one by one.

Claude Code hooks record `running` / `done` status per tmux pane (plus a
`read` flag once you've actually visited a done pane, like an inbox); an
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
  you). Both overwrite the pane's whole entry, so a fresh `running`/`done`
  always starts unread again.
- Both write to `~/.claude/tmux-claude-status.json`, keyed by tmux pane id
  (`$TMUX_PANE`). Sessions running outside tmux are silently ignored.
- `bin/claude-tmux-picker.sh` reads that file, cross-checks against
  `tmux list-panes -a` (so closed panes disappear automatically), and shows
  one `fzf` list with a header row per session (name + done/running/read
  counts) followed by its panes: `DONE` (bold green, finished and unseen),
  `RUN` (yellow, still working), or `READ` (blue, finished and you've
  already jumped to it once) — age, window, cwd, CJK-width-aware padded so
  columns line up. The session header is visual grouping only:
  `bin/skip-header.sh`, wired up via `--bind up/down/load:transform:...`
  and fzf's `pos()` action, makes arrow keys jump straight over it, so
  every stop is an actual Claude Code pane, never a session line.
- Jumping to a `DONE` pane calls `tmux_status_update.py mark-read` on it
  first, flipping it to `READ` — the same overwrite-on-`running`/`done`
  behavior above means it naturally goes back to unread `DONE` the next
  time that pane actually finishes something new.
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
bind g display-popup -w 95% -h 85% -e "CALLER_PANE=#{pane_id}" -E "~/.claude/hooks/claude-tmux-picker.sh"
```

The `-e "CALLER_PANE=#{pane_id}"` part is what makes the picker default its
cursor to the pane you're currently on instead of the top of the list —
`#{pane_id}` is expanded at key-press time (before the popup's own pane
exists), so it's the pane you were actually on.

Reload with `tmux source-file ~/.tmux.conf`, then in any already-running
Claude Code session run `/hooks` once so it picks up the new config
(freshly started sessions pick it up automatically).

## Use

Press `prefix + g` (or whatever key you bound) anywhere in tmux:

```
▾ news                      ✅1  🏃1  👀0
  DONE  57s前   prototype-redesign      /Users/you/repos/frontend
  RUN   82s前   write-readme            /Users/you/repos/backend
▾ fun                       ✅0  🏃0  👀1
  READ  331s前  tmux-picker             /Users/you
```

The cursor starts on the pane you're currently on (if it's tracked), not
always on whatever's most urgent — you're usually opening this because
you want to check something nearby, not get redirected. Arrow up/down
moves between panes only — the `▾ session` lines are skipped
automatically, so every stop shows a real Claude Code pane and the
right-hand preview instantly follows it, scrolled to the bottom. Enter
jumps immediately; no separate menu, no extra confirmation step.

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
