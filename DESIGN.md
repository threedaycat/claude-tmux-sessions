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
A session whose panes all collapse keeps its header, so a 24-pane spread reads
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

### The empty list, and `{n}`

**Every key above is a `transform` that receives the cursor's index as
`{n}` — and when the list is empty there is no item under the cursor, so
fzf does not substitute `{n}`. It drops it.** The argument list arrives one
short and everything shifts left: the *direction* lands in the slot the
script reads a number from.

The result was that an empty list bricked the picker. `Esc` parsed as a
down-arrow. `q` reached `orig=$(( cur + 1 ))` with `cur` holding the word
`quit`, tripped `set -u`, and exited non-zero having printed no action —
and a `transform` that prints nothing is a key that does nothing. Every
key routed through `skip-header.sh` was dead at once; only `ctrl-c` was
left.

**This is not an Agent Teams bug and it is older than that feature.** There
are three routes to an empty list and only one of them involves `f`:

| | route | needs a team? |
|---|---|---|
| a | `ctrl-x` the last tracked pane | no — reproduces on `38c2c0a` |
| b | `/` search matching nothing | no |
| c | the last Claude exits while the picker sits open, then `a` rebuilds | no |
| d | `f`, when no member of any team currently holds a live pane | yes |

(b) is the mild one: Backspace is not bound to a transform, so deleting
back to a match recovers on its own. (c) is the one that disproves the
tempting shortcut "only `f` can empty the list, so only `f` needs the
check" — every rebuild re-reads the world, and the world shrinks whether
or not a key asked it to.

Three fixes, at three layers, because they answer three different
questions:

- **The picker quotes `{n}` in every bind** — `"{n}"` instead of `{n}`.
  This is the fix at the source: quoted, an empty index survives as an
  empty first argument and nothing shifts. Verified directly against fzf:
  on an empty list `probe {n} x` arrives as `argc=1 [x]` while
  `probe "{n}" x` arrives as `argc=2 [] [x]`. The `load` bind passes a
  literal `0` rather than `{n}`, so it never had the problem and is left
  alone — which is also why `init` was the one transform that kept working.
- **`skip-header.sh` normalises the arguments anyway.** Defence in depth,
  and deliberately kept after the quoting: it accepts all three shapes —
  a real number, a present-but-empty first argument, and a missing one —
  and lands on the same place. An empty list is a *normal* state, not
  malformed input, so it must never reach the arithmetic. `set -u` stays:
  it is the net that caught this, not the cause of it.

  > The subtle way to get this wrong is to zero `cur` without moving the
  > arguments back. `Esc` then parses as `cur=0, dir=down` and emits
  > `pos(…)`: the crash is gone, the log is clean, and the key still does
  > not exit. The test is not "does it stop erroring" but **"does `Esc` on
  > an empty list emit `abort`"**.
- **`rebuild_rows()` avoids entering an empty list when it doesn't have to.**
  Recovering the keyboard is not the same as having somewhere to put the
  cursor. Only route (d) is recoverable — drop the filter, rebuild without
  it. Routes (a) and (c) are legitimately empty and stay that way.

Leaving a no-match search is a third face of the same thing, and why the
`Esc` action reads `clear-query+search()+disable-search+…`. `clear-query`
empties the query, but the re-filter it schedules is discarded by the
`disable-search` arriving in the same batch, so `Esc` used to leave the
list still narrowed to whatever the query had matched — and showing
nothing at all when it had matched nothing. The explicit `search()` re-runs
the search against the now-empty query and forces the full list back before
search is switched off.

> **The rule this leaves behind:** a key that can change how many rows are
> shown has to answer "and what if that is zero". The list going empty is
> reachable, it is not an error, and it must stay escapable.

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

## The Agent Teams view

Claude Code can run a *team*: a lead plus teammates, each in its own tmux
pane, sharing a task list. Those panes are tracked like any other, so
without this they arrive as an anonymous cluster of rows — the same window
name on every one of them, no way to tell who is who.

The team *rows* are gated on one `stat`. With no `~/.claude/teams/`
directory, `bin/agent_teams.py` is never imported, no extra process runs,
no extra file is read, and not one row is added or annotated — verified by
diffing the row output against the previous version with the directory
absent.

The *naming* change below is not gated, and it is worth being precise
about who it affects. Level 3 replaces `window_name` with `pane_title` for
every row, team or not. For a pane that owns its tmux window the two
strings are identical, so those rows don't move. For panes that share a
window they differ — that is the entire point — so anyone running several
Claude panes in one window sees those rows change, whether or not they
have ever used a team. They change from one shared, concatenated title
repeated on every row to each pane's own.

So the compatibility claim is two claims, and only the first is
byte-for-byte:

- the Agent Teams view costs nothing and shows nothing until there is a team
- pane naming got more accurate for everyone, and visibly so for anyone
  stacking Claude panes in a single window

**Naming a pane.** Five sources, best first, each falling through for its
own reason:

| | source | falls through when |
|---|---|---|
| 1 | a hand-picked session name (`~/.claude/sessions/`) | nobody renamed this session |
| 2 | the team roster's `name` | the pane isn't on a team |
| 3 | `pane_title` | empty, or really the shell's default |
| 4 | `window_name` | empty |
| 5 | the session id, then the pane id | never |

**Level 1 is read, not recorded.** It was a reserved empty slot for three
commits because the obvious place to fill it from does not exist: the
status file this repo writes has no such field, and no hook payload carries
one either — checked against the binary, not assumed. Claude Code keeps the
name in files of its own, `~/.claude/sessions/{pid}.json`, and
`bin/claude_sessions.py` is the one parser for them (same rule as
`agent_teams.py`: two parsers for a format we don't own drift the first
time it moves).

Three things about those files decide how they are read, and all three are
properties of the format rather than choices:

- **Only names a person chose are accepted.** Claude Code names every
  session, mostly by derivation from the cwd, and marks those
  `nameSource: "derived"`. A derived name is *worse* than what levels 3-4
  already produce — it is the directory, which the row's trailing field
  already says — so promoting one would make the column less accurate for
  everybody who has never renamed anything. The test is "the field is
  absent", which is what `/rename` leaves behind, and it is deliberately
  the strict reading: a future `nameSource: "user"` would be rejected and
  nothing visible would change, while the loose reading would let a future
  `nameSource: "auto"` through and quietly downgrade the column for people
  who have nothing to do with any of this. There is a second reason to be
  strict, and it is the same one `safe_title()` exists for: a name derived
  from a cwd under `$HOME` can be derived from `$HOME` *itself*, and then
  the "name" is the operator's login name. Rejecting derived names keeps
  that out of a list people screenshot without needing a second guard.
- **The files are keyed by pid, the picker is keyed by session.** A crashed
  Claude leaves its file behind and a resumed session writes a second one,
  so the lookup indexes by `sessionId` — the only key both sides hold — and
  the larger `updatedAt` wins a collision. `status` is not used for it:
  `idle`/`busy` says what a session was doing, never whether the process is
  still alive.
- **Reading is why this is on the render path and not in the hook.** The
  hook would write the name once into the status entry and both renderers
  would get it for free, which is tempting and wrong: the value would then
  be as old as that pane's last status change. Renaming a session and
  immediately opening the picker is precisely the moment the feature is
  used, and an idle pane has no next status change to refresh it. Reading
  costs one `listdir` plus one small parse per file, memoised per process
  — measured at ~25µs a file, so ~12ms against a synthetic 500-file
  directory, against a startup path that already costs ~100ms.

Degradation is the same one stat as teams: no `~/.claude/sessions/`, no
import, no read, and the chain answers at level 2 or 3 exactly as before —
verified by diffing the row output against the previous version with
`CLAUDE_HOME` pointed at an empty directory.

> One visible consequence for anyone who *has* renamed a session: Claude
> Code writes a spinner glyph into `pane_title` alongside the name, so
> level 3 was returning `✳ agi-docs`, and while Claude is working the glyph
> is an animating braille frame that changes the row between renders. Level
> 1 returns the name alone. Sessions nobody renamed still show the glyph;
> that is level 3 behaving as it always has.

Level 3 is why this is worth doing at all: several Claude panes sharing
one tmux window all write to the same `window_name`, so it arrives as
their titles concatenated in an order none of them agree on, while
`pane_title` stays per-pane and clean — and it still is why, because level
1 answers only for sessions somebody bothered to name. Level 2 doubles as the membership
test — a roster hit *is* membership, so nothing tests for it separately —
and the lead needs no special case, because it falls through to level 3
and its `pane_title` is the session summary, which is what its row should
say. Level 5 prefers the session id because a tmux server restart
renumbers every pane while the session id survives it; its only job is to
guarantee no path returns an empty name.

> `pane_title` falls back to the machine's user and host name when nothing
> has set it. `safe_title()` in both renderers drops those rather than
> print them into a list people screenshot. `prune()` should already keep
> such panes out of the list, but that invariant lives in another file and
> guards something else — don't delete the check because it looks
> redundant.

**Rows.** A team adds no rows at all. It is summarised on the header of the
session it is running in — `▾ $7 7  ✔ 1  ▶ 1  编队 队员 3 · 待领 2` — and
its members are annotated in place on the pane rows they already had. The
annotation spends **no columns**: a member's name is simply printed in the
colour the official roster assigned that member, and nothing is added to
the row.

This was a four-cell word (`队员`) in front of the name for three commits,
and the word was the wrong trade. The name column is the only one in this
list that ever runs out of room, and the tag spent a fifth of it on every
member row to repeat, once per row, what the session header above already
said once. Colour costs nothing, and it says something the word could not:
*which* teammate, not merely that there is one. The eight names Claude Code
assigns from — `red blue green yellow purple orange pink cyan` — are the
whole vocabulary, translated to SGR in `agent_teams.COLOUR_SGR`, one map so
that a member cannot be one colour in the list and another in the preview.

**Colour is never the only thing carrying it**, which is the condition for
dropping the word at all. Three signals survive with no colour at all, and
the first two are absolute rather than a comparison against a neighbour:

| | signal | holds when |
|---|---|---|
| 1 | no number in the gutter — every other pane row has one | always |
| 2 | `j`/`k` walks straight past the row | always (not under `f`) |
| 3 | the pane preview names the team and the member in words | always |
| 4 | the indent | there is a non-member row nearby to read it against |
| 5 | the colour | the roster's value is one this map knows |

An unrecognised colour (the palette gains a ninth name, a config is
hand-edited) loses signal 5 and keeps the rest, so nothing may key off the
map being non-empty.

> **Signal 3 is a debt this change took on, and it is paid by a different
> change.** The pane preview did name the team in words all along, and the
> words were scrolled off the bottom of the window where nobody could read
> them — see ["Why the bar is under the screen"](#why-the-bar-is-under-the-screen-and-not-over-it).
> Dropping the word `队员` was only defensible once that was fixed, so the
> two are one decision wearing two commits. **Reverting the preview fix
> alone silently takes a signal away from this table**; if it ever has to
> go, the tag comes back with it.

> **This repo emits ANSI unconditionally, everywhere.** `NO_COLOR` is not
> honoured by any of it — not the headers, not the status labels, not the
> meters — so it is not honoured here either. That is a whole-repo item
> nobody has done, not a gap in this feature: making one member's name the
> single monochrome thing in a coloured list would be worse than the
> inconsistency it fixed. It is also exactly why signals 1 and 2 above are
> required to be absolute — on a terminal that drops colour, they are what
> is left.

The session header keeps the word `队员` in `编队 队员 3`. That is a count,
not a per-row tag: it is paid once per session rather than once per member,
and it is the plain-text statement that this session has teammates in it at
all — which is what makes signals 1 and 4 legible instead of mysterious.

This started as a two-line block of its own above the list, and folding it
into the session header removed a whole row kind (`$5 == "team"`) along
with the cursor, `Enter` and preview cases it needed. A team is spawned by
splitting the window its lead is already in, so the team and that session
are one object; drawing them as two rows drew the same thing twice, and
the block wasn't even a destination — it occupied a row that went nowhere,
directly above a session header that went exactly where you wanted. The
session keeps its own name in the header, because that is the coordinate
people navigate by; a team is something a session *has*.

A member with no pane never gets a row. It has nowhere to jump to, and
every row here is a jump target. Those members are named in the preview,
which after the fold is the only surface left that can — so that half of
the preview is not optional decoration, it carries the one thing the row
list structurally cannot show.

Teammate rows are shown but not selected. They carry no gutter number
(field 4 is empty, which is what the digit shortcut resolves against) and
field 5 marks them `mate`, which takes them out of the set the cursor
stops on — the same treatment as the `⋯ 收起 N 个` line, reached by a
different route because a teammate keeps its pane id in field 2 and so
can't be excluded by the absence of one.

They also step four cells further right than everything else, paid for out
of the name column so the age and the free-form tail stay on the x they
have everywhere else in the list. Four and not two because the role tag's
five cells were freed: paying four of them back into the indent moves the
status label — the one part of the row sitting at a fixed x on every other
line — twice as far as before, and still leaves a member's name column
wider than the tag left it.

The reason is that a teammate row and its lead were competing for the same
`j`/`k` step, and the lead is the one worth stopping on: the teammates
live inside its tmux window, one native pane-switch away, so stopping on
each of them in turn walked you past the destination through rows that
mostly repeat what the lead's row already said.

The cost is real and deliberate — no number, no cursor, therefore no
`Enter`. What remains is `/` search (which can still surface and act on
one — Enter there jumps to the pane, and that path is left working on
purpose), tmux's own pane switching once you're in the window, and `f`.

Under `f` the marker is not emitted at all, so teammates are ordinary pane
rows again. That mode exists to look at them, so there they are the
destinations. Encoding this in the producer keeps one rule — field 5 says
what a row is — rather than two that have to be kept in agreement.

**`f`** filters down to the sessions that have a team, on the same
machinery as `a` — including numbering *before* filtering, so nothing
renumbers. With no team present the key is inert and the header doesn't
mention it.

It survived the fold because it acquired a second job on the way: it is
the only way to put the cursor on a teammate. Without it the marker above
would make them permanently unreachable except through `/` search, so the
key that looked redundant once teams stopped having their own block is in
fact the escape hatch for the row kind that stopped being selectable.

**`f` may never produce an empty list**, and "is there a team" is the wrong
question to decide that on. A team directory outlives the teammates in it,
the lead's roster entry joins to no pane, and a teammate does not reach the
status file — which is what the row list is built from — until it has been
through a full turn. So "a team exists" and "`f` has a row to show" come
apart routinely, and the common case is worse than the rare one: right
after a team is spawned, every one of its rows is still missing.

Turning the filter on there left fzf with nothing in it, and an empty list
is not a view but a dead end — no row to hold the cursor, none for Enter,
and, because fzf stops substituting `{n}` into a bind's arguments when
there is no current item, no working `Esc` either (see below). The picker
could only be left by killing the pane.

The emptiness is therefore caught on the rebuilt rows rather than
predicted: `rebuild_rows()` in `skip-header.sh` is the single point every
list-changing key passes through, and if a rebuild comes back empty with
the filter on it drops the filter, rebuilds, and says so in the header. It
is checked on every rebuild and not just under `f` because the emptiness
need not arrive on the keypress that causes it — turn `f` on while a team
has a live pane, let that teammate exit, and it is the next `a` or `ctrl-x`
that rebuilds the list into nothing.

See ["The empty list, and `{n}`"](#the-empty-list-and-n) for why an empty
list is a state worth this much trouble to avoid.

**`$CLAUDE_TMUX_TEAM_LABELS`** names a JSON file mapping member name to a
word for that member's role. The official data distinguishes exactly one
role, the lead; every finer distinction is an editorial claim about one
particular team. So the picker transports the value and never interprets
it — the same seam as `$CLAUDE_TMUX_EXTRA_CMD`, and for the same reason.

Since the row list stopped printing a role tag, those words appear in the
**previews** only — the roster and the session cards, which have the room
the name column never had. The seam is unchanged and so is the file format;
what moved is where a word wide enough to be worth reading can be shown.

**What isn't claimed.** A task shows against a member only when the task
list records who owns it. No owner means the row falls back to its cwd and
the task appears only in the preview's roster. Guessing would poison the
one column whose whole value is that you can act on it.

## The live preview

Moving the selection instantly re-runs `tmux capture-pane -S -200` on the
highlighted pane in the right-hand preview, scrolled to the bottom (`follow`) so
you see the most recent output. Under it sits a Claude-Code-statusline-style
bar (`session-digest.py --pane`): status · model · a `▓░` context meter (% of
the context window, see below — with a red `⚠ /compact` when the remaining
headroom gets thin) ·
the status-aware elapsed time · cwd, read via a cheap 80KB transcript tail so it
costs ~40ms per cursor stop.

### Why the bar is under the screen and not over it

For three commits it was printed first, and for three commits **nobody could
see it**. `follow` pins the preview to the bottom of whatever the script
prints, and a 200-line scrollback is several times the height of the window,
so everything printed before the capture was scrolled off — measured, with
fzf's own indicator reading `239/277`.

The three alternatives are all worse:

| fix | why not |
|---|---|
| drop `follow` | shows the top of a 200-line scrollback and hides the live screen, which is the entire point of a pane preview |
| trim the capture to the window height | `wrap` means one captured line can occupy several display rows, so "print exactly `$FZF_PREVIEW_LINES` lines" is not computable from the line count |
| `follow` off for team rows only | `--preview-window` is one global setting; there is no per-row form of it |

Printing last needs none of that and cannot be defeated by content length:
when the output overflows, `follow` puts the end of it on screen, and when it
doesn't, there is nothing to scroll. It also puts the bar where Claude Code
puts its own statusline, so the preview reads the way the pane does.

One detail that is not cosmetic: the bar opens with an explicit `\033[0m`.
The screen above it arrives through `capture-pane -e` and can end
mid-attribute, and an unterminated colour there would otherwise bleed into
every line below it.

### What the bar says about a team

A pane on a team names its team, its member and its agent type, plus the task
it has claimed and its unread count when it has either.

A pane that is *not* a member but whose session hosts a team gets one line:
the same counts the session header carries (`编队 <team> · 队员 3 · 在做 1 ·
待领 2`). That is the lead's pane, or a pane sitting beside it — **which one
is the lead cannot be known**, because a lead's roster entry holds the literal
string `leader` where a pane id belongs, so the honest test is the session
rather than the pane, and the same summary on a sibling pane is at worst
harmless.

The roster is deliberately *not* repeated here. The session header's preview
already carries it in full, and rebuilding it against a live screen would be
the duplication that folding the team block away removed. Which team is in
which session is derived from the panes, exactly as `list-rows.sh` derives it,
so the preview can never claim a team the header above it doesn't show.

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

## The token page (`t`)

The footer answers "how much quota is left". The token page answers the next
question — **where did it go** — across every tracked pane rather than one:
`bin/token-report.py` builds it, `bin/token-page.sh` owns the screen, `t` opens
it, `q` leaves.

**Two blocks, in the order the question gets asked.** An overview of the window
(turns, and the four token classes as share bars), then a per-session ranking.
Only the second one is actionable: with two dozen Claudes running, "today cost a
lot" isn't news — "*this* one costs a lot" is.

**Why the ranking is sorted by tokens read in, and why `均/轮` is its own
highlighted column.** Cost is roughly turns × the context each turn carried, and
~98% of the tokens are cache *reads* — re-sending context that already exists. So
turn count misjudges badly: on the day this was built a session with 203 turns
outranked one with 493, because every one of those turns hauled ~500k of context
against the other's ~226k. Mean context per turn is the driver, and it's the one
number that explains *why* a session is expensive rather than just that it is.

**One API response is several transcript lines, and every one of them repeats the
same `usage` block.** A reply containing thinking + text + two tool calls is
written as four lines, all carrying the same `message.id` and the same token
counts. Counting per line inflates the totals — measured on one day's transcripts,
same instant, same filter: 4,906 lines vs 2,660 actual responses (1.84×), and
1.29B vs 713M cache-read tokens (1.80×). So responses are counted once, keyed by
`message.id` (the same dedup `usage-footer.sh` already does). This is the one
number to be suspicious of when comparing against a hand-rolled `jq` pass; a
plain per-line sum is nearly double.

**Cost control on a 300 MB transcript directory.** Files are streamed line by
line, never read whole; a file whose mtime predates the window is skipped
entirely (it cannot contain a line inside the window); and lines are filtered on
the `"usage"` substring before paying for `json.loads`, since most lines are user
turns and tool results. Today's report over 43 files: ~0.5s.

**A session's project is its *last* `cwd`, not its first.** Long sessions move
between directories, and taking the first one made the same session show a
different project in the today and 7-day views — the more recent directory is
also the better answer to "what is this one working on".

**Why `t` can't be dispatched the way every other key is.** Every other binding
routes through `skip-header.sh`, which prints an action for fzf to run. That
output goes through the same parser as the `--listen` HTTP payload, and that
parser refuses `execute()` as remote code execution — fzf drops it silently, so
the key simply did nothing. The `execute()` is therefore bound directly on the
key, and the transform is kept for its other job: while the search input is open,
`t` has to type a `t`. `token-page.sh` reads `$FZF_INPUT_STATE` (fzf exports it
to every child) and returns immediately in that state. The page needs none of the
cursor-carrying that `a` and `ctrl-x` do: it reloads nothing, so fzf redraws the
list exactly as it was.

**A read-key loop, not a second fzf.** Nothing on the page is selectable, so
nesting fzf inside fzf's `execute()` would only mean two sets of bindings
fighting over `j`/`k`. `1` / `7` switch the window in place; every other key is
ignored, so a stray keypress can't drop you out by accident. The keystroke is
read from `/dev/tty` explicitly — a child of `execute()` inherits the picker's
row pipe on stdin, and a plain `read` would hit EOF instantly and flash the page
past. Terminal size comes from `stty size < /dev/tty` rather than `tput`: inside
command substitution tput's stdout is a pipe, so ncurses asks stderr instead, and
with stderr redirected it finds no terminal and reports the terminfo default
24×80 — which sized the page for a third of the real screen.

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
