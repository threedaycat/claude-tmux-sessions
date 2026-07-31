# Design & internals

The full design behind [claude-tmux-sessions](README.md) — how the status is
tracked, how the four states are derived, the notification cascade, the picker's
two cursor modes, the live preview and usage footer, and the tmux-resurrect
integration. Read the [README](README.md) first for the user-facing overview.

## The status file

Everything hangs off one JSON file, `~/.claude/tmux-claude-status.json`, keyed
by tmux pane id (`$TMUX_PANE`). Sessions running outside tmux are silently
ignored. Each entry records a `status`, `updated_at`, a `read` flag (like an
inbox), an `archived` flag, and enough tmux/session context to render and jump.

Claude Code hooks are the only writers:

- A `UserPromptSubmit` hook marks the current pane `running`.
- A `Stop` hook marks it `done` (Claude finished its turn and is waiting on you).
- A `Notification` hook calls `tmux_status_update.py notify`, which reads the
  hook's own `notification_type` field to split the one event Claude Code fires
  into two very different situations:
  - `permission_prompt` → `blocked` — Claude is stuck on an explicit
    approve/deny choice, which actually stalls progress. **This is the only
    status that notifies** (see below).
  - anything else (`idle_prompt`, unrecognized) → `input` — Claude's done and
    just waiting on your next message. Worth a glance, not urgent.
- A `SessionEnd` hook deletes the pane's entry when Claude Code exits. Without
  it, quitting Claude and resuming in a *different* pane of the same window
  would leave the old entry behind (the old pane is still alive, so a liveness
  check alone can't catch it) and the window would show up twice.

All four statuses overwrite the pane's whole entry, so a fresh
`running`/`done`/`blocked`/`input` always starts unread and unarchived again.

### Pruning — the safety net

For exits that never fire `SessionEnd` (crash, `kill -9`, sessions started
before the hook existed), every reader first runs `tmux_status_update.py
prune`, which drops entries whose pane is gone **or** whose pane is now just
running a plain shell. While Claude is alive (even mid-tool-call) tmux reports
the claude process as `pane_current_command`, so a bare `zsh`/`bash` there means
Claude has exited and the entry can go.

One guard makes this safe: a pane id only means anything relative to a single
tmux server, and there is no way to ask "is this the server these ids came
from?". So prune requires the file and the server to **overlap by at least one
pane** before it believes a missing id means a dead pane. Without that check,
running any reader while `$TMUX` points at a different server — a second server,
a nested session, a stale env var — makes every id look dead and wipes the whole
file. (Found the hard way: generating the screenshots in `docs/demo/` spins up a
second tmux server, and it ate 20 live panes' worth of state.) No overlap is
genuinely ambiguous — wrong server, or a tmux restart that renumbered
everything — so prune does nothing, which self-corrects: entries whose pane is
absent are invisible in the UI regardless, and as soon as one live pane
registers there is an overlap again and the next prune clears the corpses.

## The four states

The UI collapses the raw statuses into four states, each with a distinct
leading **icon** so it reads by shape, not just colour:

| State | Icon | Colour | Meaning |
|-------|------|--------|---------|
| WAIT  | `⏸`  | red    | `blocked` — Claude needs an approve/deny. Top priority; the only state that notifies. |
| RUN   | `▶`  | yellow | `running` — Claude is working. Nothing for you to do. |
| DONE  | `✔`  | green  | `done`/`input`, **unread** — finished, a result to look at. |
| READ  | `✓`  | blue   | `done`/`input`, already visited — quiet until it stirs again. |

`done` (the Stop hook) and `input` (idle, waiting on your next message) both
just mean "Claude finished, waiting on you", so they collapse into the single
DONE/READ pair.

> **Glyph note:** the media-control glyphs (`⏸` U+23F8, `▶` U+25B6) and the
> check marks (`✔`/`✓`) default to *emoji* presentation in many terminals,
> which renders them double-width and breaks column alignment. Each is followed
> by U+FE0E (the text-presentation selector) in the source so they stay
> single-width, monochrome, and take our ANSI colour.

### Aging out

An unread `DONE` you never come back to would pile up forever. So a `done`/`input`
entry left untouched longer than `CLAUDE_TMUX_IDLE_STALE_SECS` (default 2h,
overridable via env) **ages out**: it drops off the ambient status bar entirely
and, in the picker, dims and sinks below everything else — still reachable, just
no longer nagging.

## The WAIT notification cascade

A blocked pane is the one thing that actually stalls you, so it gets notified
several ways at once — because any single channel can miss:

- **Persistent in-tmux banner** (the reliable one): `status-badge.sh` renders a
  loud white-on-red `⏸ WAIT` chip — with the window's name and how long it's
  been waiting — into the status line whenever any pane is blocked *and unread*.
  Unlike a passing flash it re-renders on every status refresh, so it **stays
  put until you deal with it**. You dismiss it by going there: `prefix + W` or
  the picker jumps to the pane and marks it read, dropping it from the banner. A
  fresh permission prompt overwrites the entry, clears `read`, and it comes back.
- **Sound**: `afplay` on a system sound the moment it goes blocked — rings
  regardless of macOS notification permissions.
- **One-shot flash**: a `tmux display-message` on every attached client as an
  instant "just happened" cue, naming the session/window. Clients already
  looking at the notifying pane are skipped.
- **macOS notification**: via `terminal-notifier` if installed (so clicking it
  jumps straight to the pane) or plain `osascript` otherwise — for when you're
  in another app entirely.

`input` (idle) shows up in the picker but never interrupts you.

## The read / archive inbox model

- Jumping to a `DONE` pane (via the picker or `prefix + W`, both call
  `mark-read`) flips it to `READ` — an idle Claude you've already looked at (e.g.
  right after a `/clear`) has nothing new to say, so it shouldn't keep flagging
  you. The overwrite-on-status-change behavior means it naturally goes back to
  unread `DONE` the next time that pane actually finishes something new.
- `ctrl-x` archives the highlighted pane (`mark-archived`) and reloads the list
  in place — for a pane you've decided needs no more attention. The cursor
  advances to the row that took its place rather than jumping to the top (see
  the picker section). It comes back automatically the next time that pane's
  status changes.

## The picker

`bin/list-rows.sh` reads the status file, cross-checks against
`tmux list-panes -a` (so closed panes disappear), and builds one `fzf` list: a
header row per session, followed by its panes.

- **Session order** follows tmux's own `session_id` (creation order — the same
  stable order tmux itself uses), *not* urgency, so the list doesn't reshuffle
  every time something finishes.
- **Panes within a session** are ordered by their tmux `window.pane` index, so
  the picker mirrors the order you see in tmux itself — and it lines up with the
  digit-jump numbers.
- Each pane row leads with a **dim global number**, three columns wide (100+
  panes is the design target, and a 2-wide field would both drop the leading
  digit and shift that row's columns), counted top to bottom across all
  sessions — the number you press to jump. Collapsed rows keep their numbers, so
  the visible ones can skip. Then the state
  icon+label, the window name ("what is this one doing" is what you scan for
  first), a **status-aware elapsed phrase** in human units (`已运行 / 等确认 /
  完成 X前` — seconds under a minute, then minutes, then hours; `updated_at` is
  the moment the status last changed, so RUN reads as "how long it's been
  running"), and the cwd. Everything is CJK-width-aware padded so columns line
  up.
- **Session headers** carry the same icon+colour counts as the rows below them
  (`⏸ N`, `✔ N`, `▶ N`, `✓ N`, dim `✔` = aged-out), most-important-first, zeros
  omitted.

### Collapsing the quiet ones

A dozen panes fit on a screen. Two dozen don't, and a hundred is the stated
target — so the list has to stay proportional to *what needs you*, not to how
many sessions exist. The two ranks that are safe to hide are already defined:
`READ` (rank 3 — you've looked) and aged-out unread `DONE` (rank 4 — you haven't
looked in hours, so it isn't urgent). Those collapse by default; WAIT, RUN and
unread DONE are never hidden, because they're the entire point of the tool.
`a` toggles, `CLAUDE_TMUX_SHOW_ALL=1` changes the default, and the pane you're
standing in is never collapsed (visiting a pane is what marks it READ, so it
usually qualifies — and not finding yourself in the list is disorienting).

"How many are hidden" gets its own dim line under each collapsed session
(`⋯ 收起 3 个(2 已读 · 1 搁置) · a 展开`) rather than being implied by the `✓`
and dim `✔` counts in the header. Those counts *are* the collapsed panes, which
was tempting — but implied is not the same as readable, and the question you
actually have is "is pressing `a` worth it", which deserves an answer in words.
A session whose panes all collapse keeps its header, so a 24-pane fleet reads
as a handful of session lines plus the few rows that want you.

That line also sets the threshold: **a session with only one collapsible pane
doesn't collapse.** The summary occupies exactly the row it would have saved,
so hiding a single pane trades a row you can read for a row you have to press
a key to see. `MIN_COLLAPSE = 2`.

The summary is a third kind of row — empty pane id (like a header) plus `-` in
the row-number field. `skip-header.sh` therefore tracks header positions and
pane positions as two separate sets instead of treating "not a header" as "a
pane": the cursor stops on the summary in neither mode, because it's a label,
not a destination. Nothing else needed changing — the preview and Enter both
branch on an empty pane id and already do the session-level thing for it.

**Numbers are assigned before the visibility test**, which is the one
load-bearing decision here: a number that changed when you pressed `a` would
be worse than no number at all. The cost is that visible numbers go sparse
(1, 4, 7, 12…), and that ripples into the digit jump — see below.

### Two cursor modes, one list

`bin/claude-tmux-picker.sh` runs that list as the `fzf` source with two cursor
modes in the *one* list — no second screen, no overlay. `bin/skip-header.sh`,
wired via `--bind ...:transform:...` and fzf's `pos()` action, dispatches every
key:

- fzf starts with search disabled and the input line hidden (`--disabled
  --no-input`, so stray letters don't pile up in a dead query). `j`/`k` (and
  ↑/↓) move vim-style, `q`/Esc quit.
- **`/` enables search** — the same block branches on `FZF_INPUT_STATE`:
  printable keys `put()` into the query, arrows fall back to fzf's stock
  actions, Esc hides the input and returns to navigation.
- **Pane mode** (default): `j`/`k` jump straight over session headers, so every
  stop is a real Claude pane.
- **Digit jumps**: press a row's number to jump to it. A digit jumps *instantly*
  the moment it can't be the start of a larger valid number — so with fewer than
  10 rows every `1`-`9` is instant. Once two-digit rows exist, a first digit that
  could be extended (e.g. `1` while rows 10-19 exist) parks the cursor there and
  waits: press the next digit to complete it, or Enter to take the parked row.
  A per-instance `PENDING_FILE` holds the digits so far, cleared by any non-digit
  key and once a jump fires.

  Collapsing made this fiddlier, and it's the only part of the feature with real
  room to be wrong. Numbers are now sparse, so "the Nth pane row" would land on
  the wrong pane — the digits you type are matched against a **fourth
  tab-separated field** carrying the row number as plain text (fzf only displays
  field 1, so the extra field is free, and it beats parsing ANSI back out of the
  rendered row). "Can this prefix still be extended" likewise stops being
  `n*10 <= total` and becomes "does any visible number start with these digits
  and run longer". One consequence needs handling explicitly: a prefix whose own
  row is collapsed (`1` while only 10-15 are visible) matches nothing, and
  dropping it there would make 12 unreachable — so an extendable prefix is held
  even when it has no row to park on.

- **`a` toggles collapsed/expanded** — writes a per-instance `SHOW_ALL_FILE`
  that `list-rows.sh` reads via `CLAUDE_TMUX_SHOW_ALL_FILE`, created before the
  first render so the initial list and every reload agree on one source of
  truth.

  Both `a` and `ctrl-x` replace the entire list under the cursor, and fzf's
  `reload()` puts the cursor back on the first row. Neither key means "take me
  somewhere else", so both go through the same two helpers: remember what the
  cursor is on, rebuild the list in the transform (not inside `reload()`, so
  the new rows exist before anything searches them), then `reload-sync(...)` —
  sync, or the `pos()` races the old list — `+pos()` onto wherever that row
  landed. When the remembered row is gone, `a` falls back to the nearest pane
  row *above* its old number (you collapsed what you were reading, so stay
  where the readable rows are) and `ctrl-x` to the nearest *below* (the
  archived row is gone; advancing is what an inbox does).

  The subtle part: fzf fires `load` on every list load, **including reloads**,
  and the initial cursor placement is bound to `load`. So each reload re-ran
  "put the cursor where the picker started" and silently undid the `pos()`.
  `skip-header.sh`'s `init` is now guarded by an `$INIT_FILE` marker, making it
  a genuine first-load hook; later loads return `ignore` and leave the cursor
  to whoever triggered the reload.
- **`p` toggles the preview off entirely** (fzf's `toggle-preview`), handing the
  list the full width — which is the right answer to "the list is too cramped",
  because narrowing the split isn't: it was tried at
  `CLAUDE_TMUX_PREVIEW_WIDTH`% = 42 and the preview stopped being readable
  (Claude's output wraps hard below ~60 columns), so both panels ended up worse.
  The default is 50 — an even split makes the preview about as wide as the pane
  it's capturing, so that screen shows at its real shape rather than reflowed —
  and `p` covers the scan-the-list case outright.
- **`h` / `←` → session mode**: the cursor snaps to session headers (up/down move
  header-to-header), Enter jumps to that session's last active pane, and the
  preview becomes one compact card per pane (see below). `l` / `→` snaps back to
  the nearest pane row. Headers are bold cyan and pane rows plain and
  deeper-indented, so which kind of row the cursor is on is legible at a glance;
  the prompt line at the top follows the mode (`change-header`).

Cursor-mode state (and the row cache, and the digit accumulator) lives in
per-instance temp files created by the picker and read by `skip-header.sh`,
which runs as a *separate process per keypress* and so can't keep state in a
variable. The row cache matters: re-running `list-rows.sh` on every keypress
(prune + two pythons + tmux round-trips) made held-down cursor movement lag by
seconds under load, so the rows are written once at startup and refreshed only
on the `ctrl-x` reload.

## External item provider

The picker only knows about tmux panes. Some people want more in the same
list — a to-do queue, review requests waiting on them, a failing build —
without maintaining a second tool with its own keybindings to remember.
`$CLAUDE_TMUX_EXTRA_CMD` is the seam for that, and it's designed so the
picker never has to know what the extra rows mean.

**Contract.** Point the variable at an executable; it's called three ways:

| Call | Expected | On failure |
|---|---|---|
| `$CMD list` | one row per extra item (format below) | non-zero exit / timeout / empty output → treated as absent |
| `$CMD preview <id>` | that item's full detail, plain text | print an error string; doesn't break the list |
| `$CMD action <id>` | whatever Enter should do for it | non-zero exit just means nothing happened |

Unset, missing, or not executable → the picker's output is byte-for-byte
what it always was. This is a hard requirement, not a soft default: it's
what lets someone turn the feature off by unsetting one variable, and it's
what let a redesign of the *session* list ship without ever touching this
seam. `run_with_deadline()` in `list-rows.sh` also caps how long the call
can block the startup path (`$CLAUDE_TMUX_EXTRA_TIMEOUT`, default 2s) —
a hung provider degrades to "no extra rows" instead of a stuck picker.

**Row format.** Two more tab-separated fields after the four the session
list already uses:

```
display \t (empty) \t (empty) \t (empty) \t extra \t <id>
   $1        $2         $3         $4        $5        $6
```

`$5 == "extra"` is what tells `skip-header.sh` and `preview-row.sh` a row
came from the provider rather than being a session header — the header
test became `$2=="" && $4=="" && $5==""` for exactly this reason. `$6` is
an opaque id: this script never parses it, just hands it back verbatim to
`preview`/`action`. A provider can also emit a **label** row (`$2` and `$4`
both empty, `$5` empty too) to print a section heading above its items;
the cursor treats it exactly like a session header.

**Where extra rows sit, and why they behave the way they do:**

- They're listed *before* the session list, so "things waiting on you"
  sorts above "which pane is running what."
- They don't get a gutter number (`$4` stays empty). Pane numbers are
  a stability guarantee elsewhere in this file (see "The four states" on
  why a number must never silently point at a different pane) — an extra
  row appearing or disappearing between polls would otherwise renumber
  every pane below it. The trade-off is that digit-jump can't reach them;
  `j`/`k` or `/` still can, because pane-mode navigation treats extra rows
  as valid stops (`is_extra` alongside `is_pane`).
- `init` (the picker's starting cursor position) skips them on purpose —
  landing on "whatever's on top" the moment any extra rows exist would
  change the picker's opening behavior for everyone, extra rows or not.
  Initial focus stays on a pane; browsing to an extra row is one `j`/`k`
  away like anything else in the list.
- Enter on one runs `$CMD action <id>` instead of jumping anywhere.

**Keeping this seam clean.** The picker's independence doesn't come from
what it displays — it comes from not knowing what an extra row *is*. It
sees "a line of text and an opaque id," never what kind of to-do or
notification produced it. That's what makes the same seam usable for
someone else's data source, and what keeps this repo shareable on its own.

> **No product-, company-, or person-specific vocabulary belongs in this
> repo's code.** If a change needs one to work, it belongs in the provider
> script instead.

Check it the same way CI would, before committing anything that touches
`bin/` or `hooks/`:

```bash
grep -rniE '<names that would leak your setup>' bin/ hooks/ *.md docs/
# must produce no output
```

## The live preview

Moving the selection instantly re-runs `tmux capture-pane -S -200` on the
highlighted pane in the right-hand preview, scrolled to the bottom (`follow`) so
you see the most recent output. It's topped by a Claude-Code-statusline-style
bar (`session-digest.py --pane`): status · model · a `▓░` context meter (% of
the context window, see below — with a red `⚠ /compact` when the remaining
headroom gets thin) ·
the status-aware elapsed time · cwd, read via a cheap 80KB transcript tail so it
costs ~40ms per cursor stop.

In session mode the preview instead shows one compact card per tracked pane,
built by `bin/session-digest.py` from each pane's Claude Code transcript
(`~/.claude/projects/…/<session_id>.jsonl`, findable because the hooks record
`session_id`): name/status/age, a `❯` task line (the session's first real prompt
— what this pane is working on), model + the same `▓░` context meter, and a
`▎`-quoted recap of Claude's last reply.

## The usage footer

The picker's footer is a multi-line usage panel (`bin/usage-footer.sh`, filled
asynchronously via fzf's `bg-transform-footer` so startup isn't delayed):

- **Top**: the real rate-limit bars — 5h / 7d window utilization % and reset
  times, read from `cachedUsageUtilization` in `~/.claude.json`, where Claude
  Code caches its own `/usage` API responses (no OAuth calls; a footnote says how
  stale the cache is). Bars go yellow at 70%, red at 90%.
- **Below**: today's tokens per model as share bars and the current 5h window's
  token count, computed live from transcripts (assistant messages since local
  midnight, deduped by message id; input + cache-write + output, cache reads
  excluded), plus a 14-day sparkline from `stats-cache.json`.

### The status-bar quota segment and the cache-wipe problem

`status-badge.sh` renders a compact 5-hour-quota readout — `5h ▓▓▓░░░░░░░ 32%
↻20:09`, the bar filling with how much you've *used* (same direction as `/usage`),
deepening green → chartreuse → gold → orange → red as it fills.

Its primary source is Claude Code's own `cachedUsageUtilization`. But that cache
is **account-scoped**, and Claude Code *wipes* the field the moment an instance
on another account touches `~/.claude.json` — so if you alternate accounts (e.g.
`claude-use l1/l2`), the cache keeps vanishing. We mirror the last live reading
to `~/.claude/tmux-quota-cache.json` and fall back to it (muted grey bar + a `~`
"last known" marker) until fresh data returns, so the segment never just blinks
out. A quiet `5h ░░░░░░░░░░ ?` placeholder shows only when there's no data at all.

## Surviving a tmux crash (tmux-resurrect integration)

[tmux-resurrect](https://github.com/tmux-plugins/tmux-resurrect) brings back your
layout — sessions, windows, panes, cwds — but every Claude Code session inside
comes back as an empty shell. This tool fixes that: the hooks also maintain
`~/.claude/tmux-claude-restore.json`, mapping stable pane coordinates
(`session:window.pane` + cwd) to the Claude `session_id` last seen running there.
Stable coordinates matter because a tmux server restart reassigns every `%pane`
id.

```tmux
set -g @resurrect-hook-post-restore-all '~/.claude/hooks/restore-claude.sh'
```

After a restore, `restore-claude.sh` types `claude --resume <session_id>` into
every restored pane sitting at a plain shell in the recorded cwd. The mapping
entry is deleted when you quit Claude normally (the `SessionEnd` hook), so a
deliberate exit stays exited — but a tmux crash never fires `SessionEnd`, leaving
exactly the sessions that died with the server to be resumed. Panes already
running something are never touched, so the script is safe to re-run;
`restore-claude.sh --dry-run` shows what it would do.

## Notes

- If your tmux config sets `automatic-rename-format '#{pane_title}'` (as
  [gpakosz/.tmux](https://github.com/gpakosz/.tmux) does), Claude Code's own
  terminal-title updates already drive your tmux window names — this tool is
  independent of that and reads its own state file, so the two don't conflict.
- `CALLER_PANE=#{pane_id}` in the popup binding is what makes the picker default
  its cursor to the pane you're currently on. It must be wrapped in `run-shell`
  — `display-popup`'s own `-e`/`-E` arguments are **not** format-expanded by
  tmux (`#{pane_id}` comes through literal), but `run-shell`'s shell-command
  argument is, so it substitutes the real pane id first.
