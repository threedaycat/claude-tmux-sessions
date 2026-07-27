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
approve/deny) fires a notification — a **persistent** red status-line
banner that stays until you go deal with it, a one-shot flash, a sound,
and a macOS notification — because that's the one status that actually
stalls progress; `input` (Claude's just idle, waiting on your next
message) shows up in the list but doesn't interrupt you.

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
    is the only status that also notifies, several ways at once:
    - **persistent in-tmux banner** (the reliable one): the status-bar
      segment (`status-badge.sh`) renders a loud white-on-red banner
      `⚠ N 个等你确认 · prefix W 跳转` whenever any pane is blocked *and
      unread*. Unlike a passing flash it re-renders every status refresh,
      so it **stays put until you deal with it** — it never vanishes on
      its own after a few seconds. You dismiss it by going there: `prefix
      W` (or the picker) jumps to the pane and marks it read, dropping it
      from the banner. A fresh permission prompt overwrites the entry,
      clears `read`, and the banner (and sound) come back.
    - **sound**: `afplay` on a system sound (`Ping.aiff`) the moment it
      goes blocked — rings regardless of macOS notification permission,
      unlike a notification's own `-sound`.
    - **one-shot flash**: a `tmux display-message -d 5000` on every
      attached client as an instant "just happened" cue, naming the
      session/window. Clients already looking at the notifying pane are
      skipped — the permission prompt is on their screen. (The banner is
      what makes it reliable; this is just the immediate nudge.)
    - **on macOS**: via `terminal-notifier` if installed (so clicking it
      jumps straight to the pane) or plain `osascript` otherwise
      (informational only) — covers the case where you're in another app
      and not looking at the terminal at all.
  - anything else (`idle_prompt`, unrecognized) → `input` — Claude's done
    and just waiting on your next message. Worth a glance, not urgent, no
    notification. Idle that you never come back to piles up, so idle older
    than `CLAUDE_TMUX_IDLE_STALE_SECS` (default 2h) *ages out*: it drops
    off the ambient status bar entirely and, in the picker, dims and sinks
    below everything else — still reachable, just no longer nagging.
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
  done *or* idle and you've already jumped to it once) — window, a
  status-aware elapsed-time phrase in human units (已运行/等确认/等输入 X,
  完成 X前 — seconds only under a minute, then minutes, then hours;
  updated_at is the moment the status last changed, so RUN reads as "how
  long it's been running"), cwd, CJK-width-aware padded so columns line
  up. Sessions are ordered by
  tmux's own `session_id` (creation order — the same stable order tmux
  itself uses, and the same `$N` shown in the header), not by urgency, so
  the list doesn't reshuffle every time something finishes. Panes *within*
  a session are ordered by their tmux `window.pane` index too — the picker
  mirrors the order you see in tmux itself, rather than floating the most
  urgent pane to the top. Status is still carried by the label colour, and
  each pane row starts with a dim global number (1, 2, 3… top to bottom
  across all sessions).
- `bin/claude-tmux-picker.sh` runs that as the `fzf` source, with two
  cursor modes in the one list — no second screen, no overlay.
  `bin/skip-header.sh`, wired up via `--bind ...:transform:...` and
  fzf's `pos()` action, dispatches every key: fzf starts with search
  disabled and the input line hidden (`--disabled --no-input` — hidden,
  not just disabled, so stray letters don't pile up in a dead query
  display), `j`/`k` (and ↑↓) move vim-style, `q`/Esc quit, and `/` shows
  the input and enables search — in search mode (branching on
  `FZF_INPUT_STATE`) printable keys `put()` into the query, arrows fall
  back to fzf's stock actions, and Esc hides the input and returns to
  navigation. It also decides what a movement stop is: in the default
  pane mode `j`/`k` jump straight over the session headers, so every
  stop is an actual Claude Code pane; digits `1`-`9` jump straight to the
  correspondingly-numbered pane row (the dim gutter number) and accept it
  in one keypress — "type the number, land there" — while in search mode
  those same keys type into the query instead; `h` (or `←`) switches to session mode
  (cursor snaps to the current session's header, up/down now move
  header-to-header, Enter jumps to that session's last active pane, and
  the preview becomes one compact card per tracked pane —
  `bin/session-digest.py` reads each pane's Claude Code transcript
  (`~/.claude/projects/…/<session_id>.jsonl`, findable because the hooks
  record `session_id`) and shows name/status/age, a `❯` task line (the
  session's first real prompt — what this pane is working on), model +
  the same `▓░` context meter as the pane bar, and a `▎`-quoted recap of
  Claude's last reply,
  each card separated by a blank line and a full-width rule); `→` snaps
  back to the
  nearest pane row. Session headers are bold cyan and pane rows plain,
  deeper-indented with a dimmed cwd, so which kind of row the cursor is
  on is legible at a glance, and the prompt line at the top follows the
  mode (`change-header`).
- Jumping to a `DONE` or `IDLE` pane calls `tmux_status_update.py
  mark-read` on it first, flipping it to `READ` (an idle Claude you've
  already looked at — e.g. right after a `/clear` — has nothing new to
  say, so it shouldn't keep flagging you) — the same overwrite-on-status-change
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
  of scrollback — topped by a Claude-Code-statusline-style bar
  (`session-digest.py --pane`): status · model · a `▓░` context meter
  (% of the 200k window — 1M for `[1m]` models — with a red `⚠ /compact`
  once ≥80%) · the status-aware elapsed time · cwd, read via a cheap
  80KB transcript tail so it costs ~40ms per cursor stop. Enter jumps there
  (`switch-client` + `select-window` + `select-pane`); Esc cancels.
- The picker's footer is a multi-line usage panel (`bin/usage-footer.sh`,
  filled in asynchronously via fzf's `bg-transform-footer` so startup
  isn't delayed). Top: the REAL rate-limit bars — 5h / 7d window
  utilization % and reset times, read from `cachedUsageUtilization` in
  `~/.claude.json`, where Claude Code caches its own `/usage` API
  responses (no OAuth calls; a footnote says how stale the cache is).
  Bars go yellow at 70%, red at 90%. Below: today's tokens per model as
  share bars and the current 5h window's token count, computed live from
  transcripts (assistant messages since local midnight, deduped by
  message id; input + cache-write + output, cache reads excluded), plus
  a 14-day sparkline from `stats-cache.json` (history only — that cache
  lags on the current day).

## Requirements

- tmux
- [fzf](https://github.com/junegunn/fzf)
- python3
- Claude Code with hooks support
- macOS, for the `blocked` *system* notification and the `afplay` sound
  only — the in-tmux banner/flash and everything else is plain
  tmux/bash/python3 and should work anywhere; on other platforms the macOS
  notification and sound calls just fail silently and the persistent
  banner + `WAIT` row in the picker still work
- optional: [terminal-notifier](https://github.com/julienXX/terminal-notifier)
  (`brew install terminal-notifier`) so clicking the `blocked` notification
  jumps straight to the pane; without it you still get a notification, just
  not a clickable one

## Install

```bash
git clone https://github.com/siyuanseever/claude-tmux-sessions.git ~/projects/claude-tmux-sessions
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
# ambient status-bar segment, always visible in every session's status
# line without opening anything — splice this into your status-right:
#   - a 5-hour-quota bar `5h ▓▓▓░░░░░░░ 32% ↻20:09` (fills with how much
#     you've *used*, same direction as Claude /usage, the picker footer
#     and the context meters + when it resets to full), from Claude
#     Code's own cached /usage data; the bar deepens as it fills —
#     green (plenty) → chartreuse → gold → orange → red (nearly spent) —
#     so how close to the cap reads off the colour alone. That cache is
#     account-scoped and Claude Code wipes it whenever an instance on
#     another account touches ~/.claude.json (so with claude-use l1/l2 it
#     keeps vanishing); we mirror the last live reading to
#     ~/.claude/tmux-quota-cache.json and fall back to it (muted grey bar +
#     a ~ 'last known' marker) until fresh data returns, so the bar never
#     just blinks out. A quiet `5h ░░░░░░░░░░ ?` placeholder shows only
#     when there's no data at all (yet)
#   - while any pane is blocked-and-unread, a persistent badge — white-on-
#     red WAIT chip + the window's name + how long it's been waiting
#     (names the longest-waiting one, "+N" for the rest) — that stays put
#     until you jump there
#   - the full picker state as colour-coded ● counts, left-to-right in
#     priority order (most important first, so you only read the left):
#     idle (magenta), done-unread (green), running (yellow), already-seen
#     (blue); zero omitted
#(~/.claude/hooks/status-badge.sh)
```

## Use

Press `prefix + g` (or whatever key you bound) anywhere in tmux:

```
▾ $1 news               ● 1  ● 1  ● 1
    DONE  prototype-redesign      完成 57秒前     /Users/you/repos/frontend
    IDLE  backend-notes           等输入 2分钟    /Users/you/repos/backend
    RUN   write-readme            已运行 1分钟    /Users/you/repos/backend
▾ $2 fun                ● 1  ● 1
    WAIT  tmux-picker             等确认 12秒     /Users/you
    READ  claude                  5分钟前         /Users/you
```

The ● N counts on a session header use the same colours as the row labels
below them (red WAIT, magenta IDLE, green DONE, yellow RUN, blue READ) —
one glyph, colour carries the meaning — and zero counts are omitted.

The window name leads each pane row — "what is this one doing" is the
first thing you scan for — with the status right after it.

The cursor starts on the pane you're currently on (if it's tracked), not
always on whatever's most urgent — you're usually opening this because
you want to check something nearby, not get redirected. `j`/`k` (or
arrow up/down) move between panes only — the `▾ session` lines are
skipped automatically, so every stop shows a real Claude Code pane and
the right-hand preview instantly follows it, scrolled to the bottom.
Search is off by default so those letters never land in a query; `/`
turns it on (type to filter, Esc returns to `j`/`k` navigation). Enter
jumps immediately; `ctrl-x` archives (dismisses) the highlighted pane in
place; `q` or Esc closes; no separate menu, no extra confirmation step.

`h` (or `←`) flips the same list into session-select mode: the cursor snaps onto
the `▾ session` header lines instead (up/down move session-to-session),
and the preview becomes one compact card per tracked Claude pane in that
session:

```
IDLE  ✳ news-run  等输入 33分钟
❯ 帮我把今天的新闻抓下来整理成日报
opus-4-8 ▓▓░░░░░░░░ 25% (49k)  /Users/lsy/Zymix
▎ 已记下，以后严格执行：
▎ - 不主动合并到生产分支……

────────────────────────────────────
RUN   ⠂ prototype-redesign  已运行 5分钟
❯ 重构原型页的前端结构
fable-5[1m] ▓▓▓▓░░░░░░ 36% (361k)  …/frontend-prototype-redesign
▎ Now the logic implementation — check how …
```

— status, a `❯` task line (the session's first prompt), model, current
context size, and a `▎`-quoted recap of Claude's last reply, pulled from
each pane's transcript rather than scraped off the screen, sized to fit
the preview height. One glance answers "what's everyone in this session
up to". Enter drops you into the session (its last active pane). `l`
(or `→`) flips back to pane-select. Bold-cyan headers vs
plain, deeper-indented pane rows is what tells you at a glance which
mode you're in.

## Surviving a tmux crash (tmux-resurrect integration)

[tmux-resurrect](https://github.com/tmux-plugins/tmux-resurrect) brings
back your layout — sessions, windows, panes, cwds — but every Claude Code
session inside them comes back as an empty shell. This tool can fix that:
the hooks also maintain `~/.claude/tmux-claude-restore.json`, mapping
stable pane coordinates (`session:window.pane` + cwd) to the Claude
`session_id` last seen running there. Stable coordinates matter because a
tmux server restart reassigns every `%pane` id.

```tmux
set -g @resurrect-hook-post-restore-all '~/.claude/hooks/restore-claude.sh'
```

After a restore, `restore-claude.sh` types `claude --resume <session_id>`
into every restored pane that is sitting at a plain shell in the recorded
cwd. The mapping entry is deleted when you quit Claude normally (the
`SessionEnd` hook), so a deliberate exit stays exited — but a tmux crash
never fires `SessionEnd`, leaving exactly the sessions that died with the
server to be resumed. Panes already running something are never touched,
so the script is safe to re-run; `restore-claude.sh --dry-run` shows what
it would do.

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
