# claude-tmux-sessions

Run multiple [Claude Code](https://claude.com/claude-code) sessions across
tmux windows, and jump straight to the one that just finished — without
tabbing through windows one by one.

Claude Code hooks record `running` / `done` / `blocked` / `input` status
per tmux pane (plus a `read` flag once you've actually visited a done
pane, like an inbox, and an archive flag to dismiss ones you're done
with); an `fzf`-powered popup lists every tracked pane (grouped by
session, in a stable order) with a live content preview, and switches you
there on Enter. Only `blocked` (Claude needs an explicit permission
approve/deny) fires a macOS notification — that's the one status that
actually stalls progress; `input` (Claude's just idle, waiting on your
next message) shows up in the list but doesn't interrupt you.

## Why

If you keep several Claude Code sessions going in parallel (different tmux
windows, different projects), you end up polling windows to see which one
is idle and waiting on you. This tracks that state automatically and gives
you a one-key picker to jump to it.

## How it works

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
    pane) or plain `osascript` otherwise (informational only), since you
    might not have the picker open at all.
  - anything else (`idle_prompt`, unrecognized) → `input` — Claude's done
    and just waiting on your next message. Worth a glance, not urgent, no
    notification.
- All four statuses overwrite the pane's whole entry, so a fresh
  `running`/`done`/`blocked`/`input` always starts unread and unarchived
  again.
- A `SessionEnd` hook deletes the pane's entry when Claude Code exits.
  Without it, quitting Claude and resuming in a *different* pane of the
  same window would leave the old entry behind (the old pane is still
  alive, so a liveness check alone can't catch it) and the window would
  show up twice in the picker. As a safety net for exits that never fire
  the hook (crash, `kill -9`, sessions started before the hook existed),
  every reader first runs `tmux_status_update.py prune`, which also drops
  entries whose pane is now just running a plain shell — while Claude is
  alive (even mid-tool-call) tmux reports the claude process as
  `pane_current_command`, so a bare `zsh`/`bash` there means it's gone.
- They write to `~/.claude/tmux-claude-status.json`, keyed by tmux pane id
  (`$TMUX_PANE`). Sessions running outside tmux are silently ignored.
- `bin/list-rows.sh` reads that file, cross-checks against
  `tmux list-panes -a` (so closed panes disappear automatically), and
  builds one `fzf` list with a header row per session (session's tmux
  `$id`, name, and blocked/idle/done/running/read counts) followed by its
  panes: `WAIT` (bold red, top priority — Claude needs a decision), `IDLE`
  (magenta — Claude's waiting on you but not blocked), `DONE` (bold green,
  finished and unseen), `RUN` (yellow, still working), or `READ` (blue,
  finished and you've already jumped to it once) — age, window, cwd,
  CJK-width-aware padded so columns line up. Sessions are ordered by
  tmux's own `session_id` (creation order — the same stable order tmux
  itself uses, and the same `$N` shown in the header), not by urgency, so
  the list doesn't reshuffle every time something finishes.
- `bin/claude-tmux-picker.sh` runs that as the `fzf` source, with two
  cursor modes in the one list — no second screen, no overlay.
  `bin/skip-header.sh`, wired up via `--bind up/down/left/right/load:
  transform:...` and fzf's `pos()` action, decides what a stop is: in the
  default pane mode arrow keys jump straight over the session headers, so
  every stop is an actual Claude Code pane; `←` switches to session mode
  (cursor snaps to the current session's header, up/down now move
  header-to-header, Enter jumps to that session's last active pane, and
  the preview becomes one compact card per tracked pane —
  `bin/session-digest.py` reads each pane's Claude Code transcript
  (`~/.claude/projects/…/<session_id>.jsonl`, findable because the hooks
  record `session_id`) and shows name/status/age, model + current context
  size, and a recap of Claude's last reply); `→` snaps back to the
  nearest pane row. Session headers are bold cyan and pane rows plain,
  deeper-indented with a dimmed cwd, so which kind of row the cursor is
  on is legible at a glance, and the prompt line at the top follows the
  mode (`change-header`).
- Jumping to a `DONE` pane calls `tmux_status_update.py mark-read` on it
  first, flipping it to `READ` — the same overwrite-on-status-change
  behavior above means it naturally goes back to unread `DONE` the next
  time that pane actually finishes something new.
- `ctrl-x` archives the highlighted pane (`mark-archived`) and reloads the
  list in place via fzf's `reload()` — for a pane you've decided needs no
  more attention and want out of your sight. It comes back automatically
  the next time that pane's status changes again (running/done/blocked/
  input).
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
`Notification`/`SessionEnd` hooks into `~/.claude/settings.json` (existing
settings are preserved, not overwritten).

Then add a tmux binding for the popup — this is the one step the installer
leaves to you, since tmux configs vary. In `~/.tmux.conf` (or
`~/.tmux.conf.local` if you use [gpakosz/.tmux](https://github.com/gpakosz/.tmux)):

```tmux
bind g run-shell 'tmux display-popup -w 95% -h 85% -E "CALLER_PANE=#{pane_id} ~/.claude/hooks/claude-tmux-picker.sh"'
```

`CALLER_PANE=#{pane_id}` is what makes the picker default its cursor to
the pane you're currently on instead of the top of the list. This has to
be wrapped in `run-shell` — `display-popup`'s own `-e`/`-E` arguments are
**not** format-expanded by tmux (confirmed the hard way: `#{pane_id}` came
through completely literal), but `run-shell`'s shell-command argument
explicitly is (per `man tmux`), so it substitutes the real pane id before
handing the resulting command off to `display-popup`.

Reload with `tmux source-file ~/.tmux.conf`, then in any already-running
Claude Code session run `/hooks` once so it picks up the new config
(freshly started sessions pick it up automatically).

Two more optional bindings, for when you don't want to open the picker at
all — a macOS notification needs you to notice and click it, which isn't
always where your attention is:

```tmux
# jump straight to whichever tracked pane needs you most, no UI
bind W run-shell '~/.claude/hooks/jump-top.sh'
```

```tmux
# ambient status-bar segment (🔴 blocked  ✅ done-unread  ⏳ idle),
# visible in every session's status line without opening anything —
# splice this into your status-right
#(~/.claude/hooks/status-badge.sh)
```

## Use

Press `prefix + g` (or whatever key you bound) anywhere in tmux:

```
▾ $1 news               🔴0  ⏳1  ✅1  🏃1  👀0
    prototype-redesign        DONE  57s前   /Users/you/repos/frontend
    backend-notes             IDLE  90s前   /Users/you/repos/backend
    write-readme              RUN   82s前   /Users/you/repos/backend
▾ $2 fun                🔴1  ⏳0  ✅0  🏃0  👀1
    tmux-picker               WAIT  12s前   /Users/you
    claude                    READ  331s前  /Users/you
```

The window name leads each pane row — "what is this one doing" is the
first thing you scan for — with the status right after it.

The cursor starts on the pane you're currently on (if it's tracked), not
always on whatever's most urgent — you're usually opening this because
you want to check something nearby, not get redirected. Arrow up/down
moves between panes only — the `▾ session` lines are skipped
automatically, so every stop shows a real Claude Code pane and the
right-hand preview instantly follows it, scrolled to the bottom. Enter
jumps immediately; `ctrl-x` archives (dismisses) the highlighted pane in
place; no separate menu, no extra confirmation step for either.

`←` flips the same list into session-select mode: the cursor snaps onto
the `▾ session` header lines instead (up/down move session-to-session),
and the preview becomes one compact card per tracked Claude pane in that
session:

```
IDLE  ✳ news-run  2011s前
opus-4-8 · ctx 49k · /Users/lsy/Zymix
  已记下，以后严格执行：
  - 不主动合并到生产分支……

╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
RUN   ⠂ prototype-redesign  347s前
fable-5 · ctx 361k · …/frontend-prototype-redesign
  Now the logic implementation — check how …
```

— status, model, current context size, and a recap of Claude's last
reply, pulled from each pane's transcript rather than scraped off the
screen, sized to fit the preview height. One glance answers "what's
everyone in this session up to". Enter drops you into the session (its
last active pane). `→` flips back to pane-select. Bold-cyan headers vs
plain, deeper-indented pane rows is what tells you at a glance which
mode you're in.

## Notes

- If your tmux config sets `automatic-rename-format '#{pane_title}'` (as
  [gpakosz/.tmux](https://github.com/gpakosz/.tmux) does), Claude Code's own
  terminal-title updates (spinner while working, idle indicator) already
  drive your tmux window names — this tool is independent of that and reads
  its own state file, so the two don't conflict.
- The status file is actively pruned: the `SessionEnd` hook removes a
  pane's entry when Claude exits, and every read (picker, badge, jump)
  first drops entries for dead panes or panes that have fallen back to a
  plain shell.

## License

MIT
