<h1 align="center">claude-tmux-sessions</h1>

<p align="center">
  <b>Run a dozen <a href="https://claude.com/claude-code">Claude Code</a> sessions across tmux — and always know which one needs you.</b>
</p>

<p align="center">
  A status tracker + one-key <code>fzf</code> picker that tells you, at a glance,
  which pane is <b>waiting on your permission</b>, which just <b>finished</b>,
  and which is still <b>running</b> — then jumps you straight there.
</p>

<p align="center">
  <img alt="MIT license" src="https://img.shields.io/badge/license-MIT-blue.svg">
  <img alt="shell" src="https://img.shields.io/badge/shell-bash%20%2B%20python3-1f425f.svg">
  <img alt="tmux" src="https://img.shields.io/badge/tmux-%E2%9C%93-1BB91F.svg">
  <img alt="Claude Code" src="https://img.shields.io/badge/Claude%20Code-hooks-D97757.svg">
</p>

<!--
  DEMO GIF GOES HERE. Drop a recording at docs/demo.gif and uncomment:
  <p align="center"><img src="docs/demo.gif" alt="opening the picker and jumping to a pane" width="820"></p>
  A ~10s clip of: prefix+g → the list → j/k down a couple panes (preview follows)
  → Enter to jump. That single GIF is what sells this on Reddit/HN.
-->

```
  prefix + g  ┐
              ▼
▾ $1 news              ⏸ 1   ✔ 1   ▶ 1
   1  ⏸ WAIT  tmux-picker            等确认 12秒      ~/projects/claude-tmux-sessions
   2  ✔ DONE  prototype-redesign     完成 57秒前      ~/repos/frontend
   3  ▶ RUN   write-readme           已运行 1分钟      ~/repos/backend
▾ $2 fun               ✓ 1
   4  ✓ READ  claude-scratch         5分钟前          ~/
                                            ┌──────────────────────────────┐
   ↑ press 2 to jump straight to that pane  │  live preview of the pane     │
                                            │  follows your cursor …        │
                                            └──────────────────────────────┘
```

---

## The problem

You keep several Claude Code sessions going in parallel — different tmux
windows, different projects. One is mid-task, one just finished, one is
**blocked on a permission prompt and quietly stalled** while you stare at a
different window. So you keep cycling through windows to check who needs you.

`claude-tmux-sessions` makes that state **ambient**: every Claude pane reports
its status via hooks, a status-bar badge shows the whole picture from any
window, and one keypress opens a picker that jumps you to the right pane.

## What you get

- **Four states, read by shape — not just colour.** Each pane is one of:
  - `⏸ WAIT` — Claude needs an explicit **approve/deny**. This is the one that
    actually stalls progress, so it's the only state that **notifies** you.
  - `▶ RUN` — Claude is working. Nothing for you to do.
  - `✔ DONE` — finished, **unread**. A result to go look at.
  - `✓ READ` — finished and you've already visited it. Quiet.
- **A persistent WAIT alarm that won't vanish on you.** A blocked pane paints a
  loud white-on-red `⏸ WAIT` badge into your tmux status line that
  **re-renders until you deal with it** — plus a one-shot flash, a sound, and a
  macOS notification. No more discovering a 20-minute-old permission prompt.
- **A one-key picker with a live preview.** `prefix + g` opens an `fzf` list of
  every tracked pane, grouped by session. Move with `j`/`k`; the right pane
  shows a **live capture of that Claude's screen**. `Enter` jumps you there.
- **Type-the-number jumps.** Every row is numbered — press `2`, land on pane 2.
  (Two-digit rows work too: `1` then `2` → pane 12.)
- **An inbox model.** Visiting a `DONE` pane marks it `READ`; `ctrl-x` archives
  ones you're done with. Both come back on their own when that pane next does
  something new.
- **An ambient status-bar segment** you can splice into `status-right`: your
  real 5-hour usage quota bar + live counts of what's waiting — visible in
  every session without opening anything.
- **Survives a tmux crash.** Optional [tmux-resurrect](https://github.com/tmux-plugins/tmux-resurrect)
  integration re-runs `claude --resume <session_id>` in each restored pane, so
  your sessions come back — not just empty shells.

Everything is plain tmux + bash + python3. The only macOS-specific bits are the
system notification and sound; the persistent banner and picker work anywhere.

## Install

```bash
git clone https://github.com/threedaycat/claude-tmux-sessions.git ~/projects/claude-tmux-sessions
~/projects/claude-tmux-sessions/install.sh
```

This symlinks the scripts into `~/.claude/hooks/` and merges the
`UserPromptSubmit` / `Stop` / `Notification` / `SessionEnd` hooks into
`~/.claude/settings.json` (your existing settings are preserved, not
overwritten).

Then add a tmux binding for the popup — the one step the installer leaves to
you, since tmux configs vary. In `~/.tmux.conf` (or `~/.tmux.conf.local` if you
use [gpakosz/.tmux](https://github.com/gpakosz/.tmux)):

```tmux
# prefix + g → the picker, cursor starting on the pane you're currently in
bind g run-shell 'tmux display-popup -w 95% -h 85% -E "CALLER_PANE=#{pane_id} ~/.claude/hooks/claude-tmux-picker.sh"'
```

Reload with `tmux source-file ~/.tmux.conf`, then run `/hooks` once in any
already-running Claude Code session so it picks up the new config (freshly
started sessions pick it up automatically).

Two optional extras:

```tmux
# prefix + W → jump straight to whichever pane needs you most, no picker UI
bind W run-shell '~/.claude/hooks/jump-top.sh'
```

```tmux
# ambient status-bar segment — splice into your status-right:
#   5h quota bar  +  ⏸ WAIT badge (while anything's blocked)  +  ✔/▶ counts
#(~/.claude/hooks/status-badge.sh)
```

The status-bar segment looks like this — quota on the left, a WAIT badge only
when something's blocked, then dot-counts of unread-done and running:

```
5h ▓▓▓░░░░░░░ 32% ↻20:09    ⏸ WAIT tmux-picker  12秒    ✔ 2  ▶ 1
```

## Requirements

- tmux, [fzf](https://github.com/junegunn/fzf), python3
- Claude Code with hooks support
- **macOS** only for the `⏸ WAIT` *system* notification + `afplay` sound. The
  in-tmux banner, flash, and the whole picker are portable — on Linux the
  macOS-only calls fail silently and everything else still works.
- optional: [terminal-notifier](https://github.com/julienXX/terminal-notifier)
  so clicking the WAIT notification jumps straight to the pane.

## Using the picker

Press `prefix + g` anywhere in tmux:

- `j` / `k` (or ↑ / ↓) move between panes — session headers are skipped, so
  every stop is a real Claude pane and the live preview follows it.
- Press a **row number** to jump straight there (`/` first if you'd rather
  search by name).
- `h` / `←` flips into **session mode**: the cursor moves header-to-header and
  the preview becomes one compact card per pane in that session — task line,
  model, context-window meter, and a quote of Claude's last reply — pulled from
  each pane's transcript. `l` / `→` flips back.
- `Enter` jumps · `ctrl-x` archives the highlighted pane · `/` search ·
  `q` / `Esc` closes.

## How it works (short version)

Claude Code hooks write one JSON file, `~/.claude/tmux-claude-status.json`,
keyed by tmux pane id:

- `UserPromptSubmit` → `running`
- `Stop` → `done`
- `Notification` → `blocked` (a `permission_prompt`) or `input` (idle) — the
  hook reads the notification type to tell the two apart
- `SessionEnd` → deletes the entry

Every reader first *prunes* the file against `tmux list-panes -a`, so closed
panes and panes that fell back to a plain shell disappear automatically. The
picker (`bin/list-rows.sh` → `fzf`) and the status badge (`bin/status-badge.sh`)
both read that one file. `input` (idle) collapses into the `DONE`/`READ` pair
in the UI, and idle you never return to ages out after
`CLAUDE_TMUX_IDLE_STALE_SECS` (default 2h).

**For the full design** — the notification cascade, the read/archive inbox
model, cursor modes, the live preview and usage footer, CJK-width alignment,
and the tmux-resurrect integration — see **[DESIGN.md](DESIGN.md)**.

## License

MIT
