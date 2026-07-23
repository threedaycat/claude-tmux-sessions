# claude-tmux-sessions

Run multiple [Claude Code](https://claude.com/claude-code) sessions across
tmux windows, and jump straight to the one that needs you — without
tabbing through windows one by one.

Claude Code hooks record `running` / `done` / `blocked` / `input` status
per tmux pane (plus a `read` flag once you've actually visited a done
pane, like an inbox, and an archive flag to dismiss ones you're done
with). An `fzf`-powered popup opens on a list of your tmux **sessions**;
`Tab` drills into one session's panes, `Enter` jumps. Only `blocked`
(Claude needs an explicit permission approve/deny) fires a macOS
notification you can click to jump straight there — that's the one status
that actually stalls progress; `input` (Claude's just idle, waiting on
your next message) shows up in the list but doesn't interrupt you.

## Why

If you keep several Claude Code sessions going in parallel (different tmux
windows, different projects), you end up polling windows to see which one
is idle and waiting on you. This tracks that state automatically and gives
you a one-key picker to jump to it.

## How it works

**Tracking status**

- A `UserPromptSubmit` hook marks the current pane `running`.
- A `Stop` hook marks it `done` (Claude finished its turn and is waiting on
  you).
- A `Notification` hook calls `tmux_status_update.py notify`, which reads
  the hook's own `notification_type` field to decide between two very
  different situations Claude Code lumps into one event:
  - `permission_prompt` → `blocked` — Claude is stuck waiting on an
    explicit approve/deny choice, which actually stalls its progress. This
    is the only status that also fires a macOS notification, via
    `terminal-notifier` if installed (so clicking it jumps straight to the
    pane) or plain `osascript` otherwise (informational only).
  - anything else (`idle_prompt`, unrecognized) → `input` — Claude's done
    and just waiting on your next message. Worth a glance, not urgent, no
    notification.
- All four statuses overwrite the pane's whole entry, so a fresh
  `running`/`done`/`blocked`/`input` always starts unread and unarchived
  again.
- They write to `~/.claude/tmux-claude-status.json`, keyed by tmux pane id
  (`$TMUX_PANE`). Sessions running outside tmux are silently ignored.

**Browsing: sessions first, panes on demand**

- `bin/list-sessions.sh` is the picker's default view: one row per tmux
  session that has at least one tracked, non-archived pane — its tmux
  `$session_id` (the same stable number tmux itself uses, so the list
  never reshuffles order), name, and counts (🔴 blocked, ⏳ idle, ✅ done
  unread, 🏃 running, 👀 read).
- `Tab` on a session reloads the list (fzf's `reload()`) into
  `bin/list-rows.sh <session>` — that session's individual panes: `WAIT`
  (bold red), `IDLE` (magenta), `DONE` (bold green), `RUN` (yellow), or
  `READ` (blue), plus age/window/cwd, CJK-width-aware padded so columns
  line up. `Shift-Tab` reloads back to the session list.
- The right-hand preview (`bin/preview-row.sh`) matches whichever list
  you're looking at: at the session level it shows that session's pane
  summary (`bin/session-preview.sh`, i.e. what `Tab` would show you,
  without committing to it); once you've drilled into a specific pane it
  shows that pane's actual live content (`tmux capture-pane -S -200`,
  scrolled to the bottom via `follow` so you see the most recent output).
- **Enter on a session** jumps there via `switch-client` alone — tmux
  resumes whichever window/pane was last active in it, no need to pick one
  explicitly. **Enter on a pane** (after `Tab`) does the full
  `switch-client` + `select-window` + `select-pane`, and also calls
  `tmux_status_update.py mark-read` on a `DONE` pane, flipping it to
  `READ` (the same overwrite-on-status-change behavior above means it
  naturally goes back to unread `DONE` next time that pane finishes
  something new).
- `ctrl-x` archives the highlighted pane (`mark-archived`) and reloads the
  list in place — for one you've decided needs no more attention and want
  out of your sight. It comes back automatically the next time that
  pane's status changes again.

## Requirements

- tmux
- [fzf](https://github.com/junegunn/fzf)
- python3
- Claude Code with hooks support
- macOS, for the `blocked` notification — everything else is plain
  tmux/bash/python3 and should work anywhere; on other platforms the
  notification call just fails silently and the `WAIT` row in the picker
  still works
- optional: [terminal-notifier](https://github.com/julienXX/terminal-notifier)
  (`brew install terminal-notifier`) so clicking the `blocked` notification
  jumps straight to the pane; without it you still get a notification, just
  not a clickable one

## Install

```bash
git clone <this-repo> ~/projects/claude-tmux-sessions
~/projects/claude-tmux-sessions/install.sh
```

This symlinks `hooks/tmux_status_update.py` and `bin/claude-tmux-picker.sh`
into `~/.claude/hooks/` and merges the `UserPromptSubmit`/`Stop`/
`Notification` hooks into `~/.claude/settings.json` (existing settings are
preserved, not overwritten).

Then add a tmux binding for the popup — this is the one step the installer
leaves to you, since tmux configs vary. In `~/.tmux.conf` (or
`~/.tmux.conf.local` if you use [gpakosz/.tmux](https://github.com/gpakosz/.tmux)):

```tmux
bind g run-shell 'tmux display-popup -w 95% -h 85% -E "CALLER_PANE=#{pane_id} ~/.claude/hooks/claude-tmux-picker.sh"'
```

The picker defaults its cursor to the session you're currently on instead
of the top of the list, via `CALLER_PANE=#{pane_id}`. This has to be
wrapped in `run-shell` — `display-popup`'s own `-e`/`-E` arguments are
**not** format-expanded by tmux (confirmed the hard way: `#{pane_id}` came
through completely literal), but `run-shell`'s shell-command argument
explicitly is (per `man tmux`), so it substitutes the real pane id before
handing the resulting command off to `display-popup`.

Reload with `tmux source-file ~/.tmux.conf`, then in any already-running
Claude Code session run `/hooks` once so it picks up the new config
(freshly started sessions pick it up automatically).

## Use

Press `prefix + g` (or whatever key you bound) anywhere in tmux:

```
▌ $1 news                🔴0  ⏳1  ✅1  🏃1  👀0
  $2 fun                 🔴1  ⏳0  ✅0  🏃0  👀1
  $3 backend             🔴0  ⏳0  ✅0  🏃1  👀0
```

Cursor starts on the session you're currently on. `Tab` on `$2 fun` (say)
reloads into:

```
▌ WAIT  12s前   tmux-picker             /Users/you
  READ  331s前  claude                  /Users/you
```

`Enter` on a session jumps to wherever it last was; `Enter` on a pane
jumps to exactly that one; `Shift-Tab` goes back up to the session list;
`ctrl-x` archives (dismisses) the highlighted pane. The right-hand preview
always matches what's highlighted — a pane summary at the session level,
live terminal content once you've drilled in.

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
