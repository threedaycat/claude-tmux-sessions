<h1 align="center">claude-tmux-sessions</h1>

<p align="center">
  <b>Run a dozen <a href="https://claude.com/claude-code">Claude Code</a> sessions across tmux — and always know which one needs you.</b>
</p>

<p align="center">
  Hook-driven status tracking for every Claude pane, a persistent alarm for the
  one state that actually stalls you, and a one-key <code>fzf</code> picker with
  a live preview that jumps you straight there.
</p>

<p align="center">
  <a href="LICENSE"><img alt="MIT license" src="https://img.shields.io/badge/license-MIT-blue.svg"></a>
  <img alt="tmux + bash + python3" src="https://img.shields.io/badge/tmux%20%2B%20bash%20%2B%20python3-no%20daemon-1f425f.svg">
  <img alt="Claude Code hooks" src="https://img.shields.io/badge/Claude%20Code-hooks-D97757.svg">
</p>

<!--
  DEMO GIF: drop a recording at docs/demo.gif and uncomment this line —
  it's the single highest-value thing this README is missing.
  <p align="center"><img src="docs/demo.gif" alt="prefix+g opens the picker; j/k moves; Enter jumps" width="820"></p>
  ~10s: prefix+g → list appears → j/k down two panes (preview follows) → Enter.
-->

`prefix + g` — real output, four sessions, seventeen panes:

```
▾ $1 work             ▶ 1  ✓ 2
   1  ▶ RUN   api-refactor           已运行 1分钟      ~/repos/api
   2  ✓ READ  scratch                44.7小时前        ~/repos/api
   3  ✓ READ  notes                  43.6小时前        ~
▾ $2 journal          ⏸ 1  ✔ 2  ✓ 1
   4  ⏸ WAIT  deploy-script          等确认 12秒       ~/repos/infra
   5  ✔ DONE  migrate-db             完成 16秒前       ~/repos/api
   6  ✔ DONE  weekly-digest          完成 16分钟前     ~/notes
   7  ✓ READ  remote-debug           2.2小时前         ~/repos/api
▾ $3 side             ✔ 1  ✓ 1
   8  ✔ DONE  prototype-redesign     完成 27.4小时前   ~/side/prototype
   9  ✓ READ  translate-dev          3小时前           ~/side/translate
```

Every row is numbered — press `5`, land on pane 5. The cursor starts on the pane
you're already in, and the right-hand pane shows a **live capture of that
Claude's screen** as you move.

---

## The problem

You keep several Claude Code sessions going in parallel — different tmux windows,
different projects. One's mid-task, one just finished, and one has been
**blocked on a permission prompt for twenty minutes**, quietly stalled, while
you stared at a different window. So you cycle through windows to check who
needs you, which is exactly the bookkeeping a computer should be doing.

This makes that state **ambient**: panes report their own status via Claude Code
hooks, your status line shows the whole picture from any window, and one key
opens a picker that jumps you to the right pane.

There's no daemon and no polling — the hooks fire only when something actually
changes, and the picker reads one small JSON file.

## Four states, read by shape

|  | State | Meaning |
|---|-------|---------|
| `⏸` | **WAIT** | Claude needs an explicit **approve/deny**. It is *stalled*. The only state that notifies you. |
| `▶` | **RUN** | Claude is working. Nothing for you to do. |
| `✔` | **DONE** | Finished, **unread** — a result to go look at. |
| `✓` | **READ** | Finished, and you've already visited it. Quiet. |

Colour carries the same information (red / yellow / green / blue), but the icon
means you can read the list without relying on it.

## What you get

- **A WAIT alarm that won't vanish on you.** A blocked pane paints a white-on-red
  `⏸ WAIT` badge — window name, how long it's been waiting — into your tmux
  status line, and it **re-renders until you deal with it**. Plus a one-shot
  flash, a sound, and a macOS notification. Three channels, because any one of
  them can miss you.
- **One key to the right pane.** `prefix + g` opens an `fzf` list of every
  tracked pane, grouped by session, with a live preview that follows the cursor.
  `Enter` jumps. Or skip the UI entirely: `prefix + W` goes straight to whichever
  pane needs you most.
- **Type-the-number jumps.** Press a row's number to go there. Two-digit rows
  work too (`1` then `2` → pane 12), and single digits still fire instantly when
  they can't begin a bigger number.
- **An inbox, not a dashboard.** Visiting a `DONE` pane marks it `READ`; `ctrl-x`
  archives ones you don't care about. Both come back on their own the next time
  that pane does something new — so the list stays short without you curating it.
- **Session mode.** `h` flips the cursor to session headers, and the preview
  becomes one card per pane in that session: its task line, model, context-window
  meter, and a quote of Claude's last reply — read from each pane's transcript,
  not scraped off the screen. One glance answers "what is everyone up to".
- **Your real usage quota, ambiently.** The status segment and the picker footer
  both show your actual 5h/7d rate-limit windows (from Claude Code's own cached
  `/usage` data), plus live per-model token counts from transcripts.
- **Survives a tmux crash.** Optional [tmux-resurrect](https://github.com/tmux-plugins/tmux-resurrect)
  integration re-runs `claude --resume <session_id>` in each restored pane, so
  your sessions come back — not just empty shells.

## Heads up before you install

- **The UI is in Chinese.** All user-facing strings (`等确认` = waiting for your
  confirmation, `已运行` = running for, `完成` = done) are currently hardcoded
  Chinese, because that's what the author reads. The layout, icons and colours
  are language-neutral and the code is plain, so an English/i18n pass is very
  doable — [issues and PRs welcome](../../issues). Filing this here rather than
  letting you discover it after install.
- **Developed and used daily on macOS.** The macOS-specific parts are isolated to
  two things: the system notification (`terminal-notifier`/`osascript`) and the
  alert sound (`afplay`). Everything else is plain tmux + bash + python3 and
  *should* work on Linux — those two calls fail silently — but that path is
  **untested**, so treat Linux as unverified rather than supported. Reports
  welcome.
- **It writes to your Claude Code config.** `install.sh` symlinks five scripts
  into `~/.claude/hooks/` and merges four hook entries into
  `~/.claude/settings.json`, preserving whatever's already there. If you'd
  rather do that by hand, read `install.sh` first — it's ~100 lines and does
  nothing clever. Uninstall instructions are below.

## Install

```bash
git clone https://github.com/threedaycat/claude-tmux-sessions.git ~/projects/claude-tmux-sessions
~/projects/claude-tmux-sessions/install.sh
```

**Requirements:** tmux, [fzf](https://github.com/junegunn/fzf), python3, and a
Claude Code with hooks support. Optionally
[terminal-notifier](https://github.com/julienXX/terminal-notifier) so clicking
the WAIT notification jumps to the pane.

Then add the tmux binding — the one step the installer leaves to you, since tmux
configs vary. In `~/.tmux.conf` (or `~/.tmux.conf.local` if you use
[gpakosz/.tmux](https://github.com/gpakosz/.tmux)):

```tmux
# prefix + g → the picker, cursor starting on the pane you're currently in
bind g run-shell 'tmux display-popup -w 95% -h 85% -E "CALLER_PANE=#{pane_id} ~/.claude/hooks/claude-tmux-picker.sh"'

# prefix + W → jump straight to whichever pane needs you most, no picker
bind W run-shell '~/.claude/hooks/jump-top.sh'
```

Reload with `tmux source-file ~/.tmux.conf`. Then run `/hooks` once in any
**already-running** Claude Code session so it picks up the new config — freshly
started sessions get it automatically.

For the ambient status segment, splice this into your `status-right`:

```tmux
#(~/.claude/hooks/status-badge.sh)
```

which renders the quota bar, a WAIT badge only while something's blocked, then
counts of unread-done and running:

```
5h ▓▓▓░░░░░░░ 32% ↻20:09    ⏸ WAIT deploy-script  12秒    ✔ 2  ▶ 1
```

### Check it's working

In any Claude Code pane inside tmux, send a prompt, then:

```bash
python3 -c 'import json;print(json.dumps(json.load(open("'"$HOME"'/.claude/tmux-claude-status.json")),indent=2,ensure_ascii=False))'
```

You should see an entry for that pane with `"status": "running"` (or `"done"`
once it finishes). Nothing there? The hooks aren't firing — run `/hooks` in that
session, and check that `~/.claude/settings.json` lists
`tmux_status_update.py`.

### Uninstall

```bash
rm ~/.claude/hooks/{tmux_status_update.py,claude-tmux-picker.sh,jump-top.sh,status-badge.sh,restore-claude.sh}
rm -f ~/.claude/tmux-claude-status.json ~/.claude/tmux-claude-restore.json ~/.claude/tmux-quota-cache.json
```

Then remove the four `tmux_status_update.py` hook entries from
`~/.claude/settings.json` and the bindings from your tmux config.

## Using the picker

- `j` / `k` (or ↑ / ↓) move between panes — session headers are skipped, so every
  stop is a real Claude pane and the preview follows it.
- **A row number** jumps straight there. `/` switches to search-by-name instead
  (`Esc` returns to navigation).
- `h` / `←` enters session mode; `l` / `→` leaves it.
- `p` collapses the preview so the list gets the full width — worth it once
  you're tracking a dozen-plus panes and want to scan names and paths. Press it
  again to bring the preview back, or set `CLAUDE_TMUX_PREVIEW_WIDTH` (default
  `42`, a percentage) to change the default split.
- `Enter` jumps · `ctrl-x` archives the highlighted pane · `q` / `Esc` closes.

## Why not just…

- **…name my tmux windows?** Claude Code already drives your window titles with a
  spinner, so you can see *that* something's running — but not whether it's
  blocked on you, and not without looking at every window. The WAIT alarm is the
  part window names can't do.
- **…use Claude Code's own session list?** It's per-instance and shows sessions,
  not *where they live in tmux*. This is the other direction: pane-first, so
  "jump to it" is one keypress.
- **…just watch for the notification?** macOS notifications are transient and
  easy to miss when you're in another app or another Space. That's precisely why
  the alarm here is a persistent status-line badge that only clears when you go
  deal with it.

## How it works

Claude Code hooks write one file, `~/.claude/tmux-claude-status.json`, keyed by
tmux pane id:

| Hook | Writes |
|------|--------|
| `UserPromptSubmit` | `running` |
| `Stop` | `done` |
| `Notification` | `blocked` (a `permission_prompt`) or `input` (idle) — the hook reads the notification type to tell them apart |
| `SessionEnd` | deletes the entry |

Every reader first *prunes* that file against `tmux list-panes -a`, so closed
panes — and panes that have fallen back to a plain shell because Claude exited —
disappear on their own. The picker (`bin/list-rows.sh` → `fzf`) and the status
badge (`bin/status-badge.sh`) both read it. In the UI, `input` (idle) collapses
into the `DONE`/`READ` pair, and a finished pane you never return to ages out
after `CLAUDE_TMUX_IDLE_STALE_SECS` (default 2h): it leaves the status bar and
sinks, dimmed, to the bottom of the picker.

**Full design** — the notification cascade, the read/archive model, the two
cursor modes and digit accumulator, the live preview and usage footer, glyph
widths and CJK alignment, and the tmux-resurrect integration — is in
**[DESIGN.md](DESIGN.md)**.

## License

MIT
