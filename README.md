# claude-tmux-sessions

Run multiple [Claude Code](https://claude.com/claude-code) sessions across
tmux windows, and jump straight to the one that just finished — without
tabbing through windows one by one.

Claude Code hooks record `running` / `done` status per tmux pane; an
`fzf`-powered popup shows a single session → window → pane tree with a
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
  `tmux list-panes -a` (so closed panes disappear automatically), and
  renders a single `fzf` list as a tree: session line (done/running counts),
  its window lines (same counts, scoped to that window), and its pane lines
  (`DONE`/`RUN`, age, cwd) — all CJK-width-aware padded so columns line up.
  One screen, no intermediate menus: arrow keys move through the whole tree
  and `bin/preview-pane.sh` shows a live `tmux capture-pane` preview of
  whatever row is highlighted (a session/window row previews its current
  pane). Enter on any row jumps there (`switch-client` + `select-window` +
  `select-pane` as applicable); Esc cancels.

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
overwritten). `bin/preview-pane.sh` is called directly from the repo path
by the picker, so it doesn't need its own symlink.

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

Press `prefix + g` (or whatever key you bound) anywhere in tmux. You get one
tree, one screen:

```
▾ news                      ✅2  🏃0
  ▸ 4:prototype-redesign    ✅1  🏃0
    4.1    DONE  57s前   /Users/you/repos/frontend
  ▸ 3:write-readme          ✅1  🏃0
    3.1    DONE  82s前   /Users/you/repos/backend
▾ fun                       ✅0  🏃1
  ▸ 2:tmux-picker           ✅0  🏃1
    2.1    RUN   331s前  /Users/you
```

Arrow up/down through it — the right-hand preview updates live to whatever
row you're on. Enter jumps immediately; no extra confirmation step, no
separate menu to "enter" first.

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
