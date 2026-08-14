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

## The per-window badge (`@claude_win`)

`status-badge.sh` answers *how many* panes want you; it can't answer *which
window* without naming them all, which is exactly the list the picker exists to
show. So each window also carries its own state, inline in tmux's own window
list:

```tmux
set -g window-status-format '#I#{E:@claude_win} #W'
```

`sync_window_badges()` (in `hooks/tmux_status_update.py`) recomputes every
window's badge from the status file and writes it into that window-scoped user
option — the same five states and icons as the picker's labels, with a count
appended when one window holds several Claude panes (an agent team puts four in
one window):

```
3 ✔ dev      6 ◑ algo-eval      2 ⏸2▶ deploy
```

Two properties drove the design:

- **A user option, not `#()`.** A `#(...)` in `window-status-format` would fork
  one subprocess *per window per refresh*; a user option is read straight out of
  tmux's option table and costs nothing at render time. tmux's status drawing
  parses `#[...]` in the *expanded* string, so the styles stored in the option
  are honoured — the same reason `status-badge.sh`'s output can be coloured.
- **Push, don't poll.** Every mode that changes state (`running`/`done`/`notify`
  /`mark-read`/`mark-archived`/`clear`) calls the sync, so the bar flips the
  moment a hook fires rather than at the next `status-interval` tick. `prune`
  calls it too, and `prune` runs from `status-badge.sh` on every status render —
  that's the heartbeat that catches what no hook fires for: an unread `DONE`
  ageing out, a pane killed without `SessionEnd`, options left behind by an
  earlier build.

Only changed windows are written. An unchanged badge would still be a
`set-option`, and every `set-option` forces a status redraw — sync is on the
render path, so writing unconditionally would have the bar redrawing itself
forever.

It inherits the wrong-server guard from `prune()` verbatim: if the status file
is non-empty but overlaps this tmux server by not one pane id, we're talking to
a different server (or a restart renumbered everything) and the badges are left
alone rather than all cleared.

### Why `#{E:...}`, and what that buys

The option isn't always a finished string — for a lone running pane it's a small
format, expanded again at draw time:

```
#{P:#{?#{==:#{s|^.||:pane_id},23},#{?#{m:[ -~],#{=1:pane_title}},▶︎,#{=1:pane_title}},}}
```

That reads *pane %23's live terminal title* and takes its first character.
Claude Code writes a spinner glyph there while it works (`◑◐`, versus `✳` idle),
so RUN animates at Claude's own rate, for free: the title changes, tmux renames
the window, the status line redraws. No timer, no process, no `status-interval`
to shorten. The inner test is the fallback — a title that starts with an ASCII
character means Claude isn't drawing a spinner there, and the static `▶` is used
instead, so this degrades on its own rather than printing a stray letter.

Two details cost a debugging round each:

- `#{s|^.||:pane_id}` strips the leading `%` before comparing, because a literal
  `%23` in a format is eaten by tmux's strftime pass and reaches the comparison
  as `23` — it would never match `#{pane_id}`. (Same class of trap: never use a
  `{1,4}`-style quantifier in a format regex; the `}` closes the `#{...}` and
  the format silently falls apart.)
- Only *one* running pane gets the spinner. Four spinning glyphs in a window
  list is a light show, not information, so a crowded window stays `▶4`.

`#{E:}` also lets the badge ask about its own window at draw time, which is how
the fade below can spare the window you're in.

### What gets colour, and what fades

Colour is this bar's way of saying *look here*, so only the states that want you
get it. WAIT is red, unread DONE is bright green — and RUN, the state you can do
nothing about, is muted gold rather than the picker's bright yellow, precisely
because it's also the one that moves.

READ and the aged-out DONE get no colour at all, just dimness, and the dimming
doesn't stop at the icon: when *nothing* in a window is unread, the badge ends
on the dim colour instead of `#[default]` and the window name inherits it, so
the whole entry recedes. This is safe to leave hanging because tmux re-applies
`window-status-style` at the start of every window entry — the fade stops at
that window's edge. The one exception is `#{?window_active,...}`: the current
window is a bright highlight bar and dim grey on it is unreadable, so the entry
you're sitting in stays legible even after you've read it.

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
- **Looking at it also counts.** Reading a pane's output *is* reading it, and
  for a while the only way to set `read` was to arrive through this tool's own
  UI — so a window you simply switched to and read stayed a bright unread
  `DONE`, nagging you about something you'd already seen. Two paths close that:
  - `mark-seen <pane>`, wired to tmux's `pane-focus-in` hook, fires the moment
    you switch to a pane. It is deliberately *not* `mark-read`: a `blocked` pane
    is left alone, because cycling past a window must never silently dismiss a
    WAIT alert. That one you dismiss by dealing with the prompt, or by jumping
    to it on purpose.
  - `mark_watched_read()`, inside the badge sync, marks whatever the *focused*
    client is looking at right now (`client_flags` contains `focused`). This is
    the backstop and it catches the case the hook can't: a pane that finishes
    while you're already sitting in it, where no focus change ever happens.
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

### Empty, and nowhere to stand

Escapable is not the same as honest. Once the keyboard worked again, the
picker still sat in these states saying nothing, under a header advertising
eleven keys of which three did anything — while the one key that always
worked, `esc`, was the one never named. And `Enter` **closed the picker and
jumped nowhere**, which is worse than a dead key: it did something nobody
asked for.

**There are five of these and they are not one thing.** Measured, each with
its own recipe:

| | state | rows underneath | recovers by |
|---|---|---|---|
| ① | genuinely empty — everything archived or exited | none | nothing; legitimate and permanent |
| ② | `f` filtered everything away | yes | itself — the rebuild drops the filter |
| ③ | `/` matched nothing | yes | Backspace, or `Esc` |
| ④ | **pane mode with no pane to stop on** | yes — a header and a `⋯ 收起` line | `a` |
| ⑤ | session mode with no header to stop on | yes — all provider rows | `l` |

④ is the one that matters, because it needs no teams, no filter and no
search: **two tracked panes in one tmux session, both read, is enough.**
Collapsing fires at two, the pane rows fold into a `⋯ 收起 N 个` line, and
what is left is a header the cursor cannot stop on in pane mode plus a label
that is not a destination in either. The list is not empty. There is simply
nowhere to go, and every key that moves said nothing about it.

**So the test is "how many stops does *this mode* have", not "how many rows
are there".** Those are different questions and ④ and ⑤ live in the gap
between them. ①④⑤ are all derived from that one count, in `stops_here()`;
②③ keep the mechanisms they already had, which were already right, and
**must not be folded in** — the likeliest way to damage this area is to
"unify" four working behaviours into one.

> **An event is not a state, and they cannot share a mechanism.** `f`
> dropping its filter is an event: it happened once, a one-shot notice is
> correct, and the next cursor move clearing it is correct too. Emptiness is
> a state: it persists, so it has to be *recomputed* on every header, not
> latched. The proof that latching fails is that **`j` still fires when
> there is nothing to move to** — it re-sends the mode's header, so a
> one-shot empty notice is wiped by the first keypress after it, while the
> state that produced it has not changed. When both apply at once the state
> wins: the way out outranks the explanation, and the explanation would be
> erased a keypress later anyway.

**The header for these states is assembled from the keys that are live**,
not written as a sentence. `a` appears only when something is actually
collapsed; `h`/`l` only when the other mode has stops. Digits, `ctrl-x`,
`j`/`k` and `Enter` are inert here, so none of them is named.

Three constraints on the copy, each paid for by something measured:

- **The way out comes first.** In a half-width list the header is truncated
  well before its end, and `q 退出` was landing past the cut — the only exit
  named was routinely off-screen. What survives truncation must be the part
  you cannot do without, so the string opens `q/esc 退出` and the
  explanation is what gets lost.
- **No parentheses**, anywhere in it. fzf parses `change-header(…)` by
  matching them and one here truncates the header at that point.
- **No team vocabulary.** ① and ④ are *more* likely for someone who has
  never enabled Agent Teams — one Claude that exits, or two that have both
  been read — so a word about teams here would be both wrong and a breach
  of the "costs nothing if you don't use it" invariant.

For ① the wording is the startup guard's, verbatim minus its full stop.
Reaching the same condition by a different route should not be described in
different words — and until now one route printed a sentence and the other
printed nothing at all.

**`Enter` does nothing when there are no rows.** It is routed through the
transform for that one case and answers `accept` in every other, so nothing
else changes. Doing nothing is not much, but closing the window is what `q`
and `esc` are for.

**A sixth case belongs to this family without being empty at all:** `f`,
with a team whose only member is the lead, on a machine with an external
provider configured. The lead's pane can only be deduced from where its
teammates are, so a team with none is unfindable and contributes no rows —
and provider rows are emitted regardless of the filter. The list is then
neither empty nor stop-less; it is a screenful of somebody's to-do items
under a key labelled 编队. That is the same lie told the other way round, so
`f` refuses to stay on: under the filter, a pane row *is* a team row by
construction, so "did the filter find anything" is exactly "is there a pane
row", and finding none drops the filter and says so — the recovery ② already
had.

> **Do not turn the position sets into arrays.** `HEADER_POS`, `PANE_POS`
> and `EXTRA_POS` are comma-separated strings, and under `set -u` on bash
> 3.2 — which is what `/bin/bash` is on macOS — expanding an empty array is
> a fatal error rather than an empty result. A transform that exits prints
> nothing, and a key that prints nothing is a key that does nothing: exactly
> the failure the section above exists to prevent, reintroduced by a
> refactor that looks like tidying. An empty string is just an empty string,
> and "this set is empty" is a daily occurrence here, not an edge case.

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

### Finding the lead's pane, which the roster refuses to name

**No field in the official data says which pane a lead is sitting in.**
`tmuxPaneId` on a lead's roster entry is the literal string `"leader"`, and
`leadSessionId` is a session id that is not refreshed when the lead moves,
so it goes stale while still looking authoritative. Believing either would
match nothing at best and something unrelated at worst — `members()` keeps
only `%`-prefixed values for exactly that reason.

That left the lead's pane looking, to every consumer of `by_pane`, like a
pane on no team at all — and `f`, which filters to "panes that are on a
team", **dropped the lead's row entirely**. The team's own row. It was
never a filter bug: the filter's question was right and the data answered
it wrongly, so the fix is in the join, not in the filter.

**The fix is to keep the row, not to name it.** Those are separable, and
only the first was ever required. `agent_teams.attach_lead()` takes the
caller's world — `{pane: session}` — rather than reading tmux itself, so the
module stays a pure reader of `~/.claude/teams` and both renderers get the
same answer, and all it does is this: every tracked pane in a team's session
that is not a teammate joins `by_pane`, marked as **neither lead nor mate**
and carrying no name. The lead is guaranteed to be among them. That is
enough for `f` to stop dropping it.

**Nothing infers which one is the lead, and an earlier version's rule for
doing so was wrong.** It crowned the candidate whenever there was exactly
one — reading "one" as evidence, when all it means is "there is one pane
here I cannot explain". A lead running in a different tmux session, or
outside tmux altogether, leaves exactly one unrelated pane unexplained, and
that pane was named `team-lead`, tagged `中枢`, and written back into the
roster with every downstream reader believing it. The rule was unstable in
the other direction too: opening one more unrelated Claude pane in that
session took the count from one to two and the lead silently lost its
identity, so the label flickered with traffic that had nothing to do with
the team. Two teams in one session made it worse — the first team in
alphabetical order took the only candidate.

The costs are lopsided, which is what decides it:

| | cost |
|---|---|
| crowning the wrong pane | somebody else's pane is named `team-lead`, tagged, and the claim is written into the roster where no later reader can tell it from fact |
| crowning nobody | the lead's row has no tag. **It is still in `by_pane`, still survives `f`, still keeps its number.** |

So the row survives and no one is crowned. `is_lead` and `中枢` are still
produced — but only from real data, a roster whose `tmuxPaneId` is a genuine
`%NN`. That path works and is tested; it is dead only because of what
upstream currently writes, so **it comes alive the day that changes and must
not be deleted for looking unused.**

Two consequences, both deliberate:

- **Over-inclusion is the accepted price.** An unrelated Claude pane sharing
  the session appears under `f`. It cannot be narrowed without guessing
  which pane is the lead, and guessing is the thing that was removed. One
  row too many is recoverable; the wrong pane wearing the lead's name is
  not. **Do not "tighten" this** — tightening means guessing again.
- **The roster is never edited.** An inference must not be written into the
  structure holding what was actually read, or nothing downstream can tell
  the two apart. `inferred_pane` sits beside the roster's own `pane` as the
  place a future inference would go; it is empty today and nothing consults
  it. That separation is worth more than the inference it currently doesn't
  hold.

> **The deduction is anchored on the teammates' session, so a team with no
> teammates has no anchor.** Such a team reaches none of the above and
> contributes no rows at all — a boundary of the design rather than a gap in
> it, and the reason a team directory outliving its members stays invisible
> (see "Empty, and nowhere to stand" for what `f` does about it).

One further effect worth naming rather than leaving to be discovered: the
session-header preview decides which team boards to draw from the panes in
that session that are in `by_pane`, so a candidate can now supply that
answer. It changes nothing while a teammate's pane is live, because the
teammate already supplied it. It matters only when every teammate pane has
died but the status file has not been pruned yet: the board now renders
where it previously would not have. That is the better answer — the team
and its roster still exist, and the roster is the only surface that can name
members with no pane — and it self-corrects at the next prune. (The
selection there is per *session*, not per window, despite `win_of`'s name.)

> Those extra entries are a **third kind** of thing in `by_pane`, and that
> is why `is_mate` is a stated field rather than `not is_lead`. Derived, a
> candidate would have come out as a teammate — indented, unnumbered,
> skipped by the cursor — which is the exact opposite of why it was kept.
> Three places ask the question and all three now ask the entry: the row's
> shape, the naming chain's level 2, and whether the session preview gives
> the pane a card.

A lead identified from real roster data keeps its own `pane_title` as its
name rather than taking the roster name, in both renderers. Its roster name
is its agent type, which is the same word on every team's lead, while its
pane title is the session summary. Level 2 of the naming chain is therefore
teammates-only — which is also what makes an unnamed candidate fall through
to its own title instead of borrowing somebody's.

**`中枢` is a word on a row, which `队员` was not allowed to be.** The
difference is arithmetic: `队员` was paid once per member on every row of a
team, to repeat what three other signals already said; `中枢` is paid once
per team, on one row, to say the thing none of them say. Removing the first
is what afforded the second.

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
`Enter`. What remains is `l` (below, which lifts it for one team at a
time), `/` search (which can still surface and act on one — Enter there
jumps to the pane, and that path is left working on purpose), tmux's own
pane switching once you're in the window, and `f`.

Under `f` the marker is not emitted at all, so teammates are ordinary pane
rows again. That mode exists to look at them, so there they are the
destinations. Encoding this in the producer keeps one rule — field 5 says
what a row is — rather than two that have to be kept in agreement.

**`f`** filters down to the sessions that have a team, on the same
machinery as `a` — including numbering *before* filtering, so nothing
renumbers. With no team present the key is inert and the header doesn't
mention it.

It survived the fold because it acquired a second job on the way: for a
while it was the only way to put the cursor on a teammate. Without it the
marker above would have made them permanently unreachable except through
`/` search, so the key that looked redundant once teams stopped having
their own block turned out to be the escape hatch for the row kind that
stopped being selectable.

**`l` unfolds one lead's teammates** so `j`/`k` walk them, and `h` on one
of them folds the team again. `h` and `l` were already one level out and
one level in — session mode is the level above panes — and on these two
kinds of row they simply mean one level further. Everywhere else they still
switch cursor mode exactly as before.

It is the small version of `f`: `f` re-renders the whole list as teams,
which is what you want when the question is *who is on which team*; `l` is
what you want when the question is *this* team and the answer is two rows
down. Nothing is rebuilt and nothing renumbers — the rows were on screen
the whole time, only unreachable.

**The entire state is one row index**, in `$EXPAND_FILE`. It can be that
small because `bin/list-rows.sh` emits a team's members directly below
their lead, so the teammates *are* the contiguous run of `mate` rows under
that index. Nothing in the cursor code needs to know agent ids, or which
pane leads which, and nothing has to stay in agreement with the roster.

The unfold is an excursion, not a mode: walking out of the run folds it
again, and so does anything that rebuilds the list (`a`, `f`, `ctrl-x`) or
jumps away by number. The lead itself counts as inside the run, so `k` off
the first teammate lands on its lead with the team still open, and one more
`k` closes it on the way past.

Three things had to be handled for that to hold together:

- **A rebuild while sitting on a teammate.** `remember_cursor` walks up to
  the lead before remembering, because the rebuild folds the team: without
  it the pane-id match finds the teammate again and `pos()` parks the cursor
  on a row `j`/`k` can no longer move from. Under `f` it never fires —
  there the marker is absent, teammates are ordinary rows, and staying on
  one is correct.
- **The header after a rebuild.** `reload_keeping_place` now sends one, and
  deliberately without a row: it runs from key branches *above* the row
  predicates, where `is_pane`/`is_mate` don't exist yet — and a call to a
  not-yet-defined function inside a condition fails *quietly*, which is how
  the row-aware version silently never fired there. It would be wrong even
  working: those predicates are built from the rows that function has just
  replaced.
- **A stale index.** If the remembered lead has no `mate` row under it any
  more, the unfold folds itself on the next keypress rather than trusting
  the number.

The `l 展开队员` hint is **contextual, and goes in front**. The pane header
is already 115 columns while the list side of a split picker is around 79,
so it arrives truncated — a permanent thirteenth entry would only push an
existing one off the end, and anything *appended* is never on screen at all.
It is advertised on the rows where the key does something, which is also
where you would look for it, and on a lead row `l` is the most interesting
key there is.

While the lead's pane was unidentifiable, `f` showed a list in which **no
row had a number** — teammates decline them by design, and the only row
that would have carried one was the lead's, which the filter was dropping.
The header went on advertising 数字直跳 to a screen where every digit
resolved to nothing. Identifying the lead fixes that as a side effect
rather than as a second change: the lead's row comes back, and it brings
its number with it. The number is the same one it has with the filter off,
because rows are numbered before filtering.

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

### `挡住`, and why a missing task counts as finished

The shared task list is one file per task, and **finishing a task can
delete its file**. That single fact decides how `blockedBy` has to be read,
and reading it the other way round is wrong in the common case rather than
in an edge case.

The test is written positively — *is this blocker among the tasks that are
open* — and never as *is it absent from the completed ones*:

```python
open_ids = {str(t.get("id")) for t in ts if t.get("status") != "completed"}
waiting  = [b for b in (t.get("blockedBy") or []) if str(b) in open_ids]
```

Asked the other way, a blocker that finished and was cleaned up is absent
from the completed set too, so everything depending on it flips from `待领`
to `挡住` and the preview announces `等 #1` against a task that no longer
exists. Reproduced by deleting one completed task file: a `待领` row became
`挡住 … 等 #1`, and with two blockers it named the deleted one while
ignoring the one genuinely holding the work up.

**An id that names no file is therefore treated as finished.** The error
this rules out is over-reporting, and that is the expensive direction:
`挡住` is the count that sends somebody looking, and sending them after a
task that has been deleted costs more than a missed blocker would.

**Three** call sites ask this — the counts on the session header, the
shared task list in the preview, and a member's own current task — so it is
one function, `agent_teams.open_task_ids`, and not a set comprehension
copied about. Writing both copies down here was the defence while there
were two; having one is the better one. Same class of problem as the colour
map, and the failure it prevents is the header reading `挡住 1` above a list
that reads `待领`.

A member's line in the pane preview carries `等 #N` too, in the wording the
shared task list uses. Nothing stops somebody claiming work whose
prerequisite hasn't landed, and until that line existed such a member
looked busy from its own pane and stuck from the session header — one fact
that only one of the two surfaces would tell you.

> **What this rule gives up, deliberately.** "A blocker I cannot see" has
> two causes, and **on disk they are the same thing**: a task that finished
> and had its file deleted, and a `blockedBy` pointing at an id that never
> existed. Nothing distinguishes them — there is no tombstone, and ids are
> not dense enough to infer one. Treating the invisible case as *finished*
> is right for the first, which is the normal end of every task's life, and
> it means **a dangling reference will never be reported again**. That is
> the price, it is paid knowingly, and the alternative costs more: a real
> `挡住` against a deleted task sends somebody looking for work that is
> done, every day, while a dangling id is a malformed task list nobody has
> in practice. **Do not "fix" this back** — the two are indistinguishable,
> so any change that surfaces dangling ids also resurrects the false
> positive. The private task-runner repo states the same rule for the same
> reason; the two must not diverge.

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
待领 2`). Once the lead is identified it takes the member line above instead,
naming itself; this summary is what remains for the panes beside it, and for
the case where the lead could not be picked out of several candidates (see
"Finding the lead's pane"). Keying it on the session rather than the pane is
what makes it right in both, and the same summary on a sibling pane is at
worst harmless.

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

## The overview page (`o`)

The row list is a list: it shows every tracked pane in tmux order and leaves
the reading to you. That is the right shape for *going somewhere* and the
wrong shape for the question you have when you sit back down, which is not
"where is pane 12" but **"what happened while I was away"**.

`o` answers it as **one card per tmux session**, ordered by urgency: the
session holding the longest-waiting pane comes first, and inside a card the
panes are ordered the same way (⏸ WAIT, then unread ✔ DONE, then ▶ RUN, then
the quiet ones). The resource half — 5h quota, 7-day window, today's tokens
by model, the 14-day sparkline — is pinned in fzf's footer, where it stays
while you walk the cards.

**Cards by session, not blocks by state.** The first version grouped panes
into a `等你` block and a `在跑` block. That answered "what needs me" and then
left you to work out where those panes actually were — and it split a session
in half whenever one of its panes finished. A session is a place you go, so
it is the unit worth drawing a box around; urgency lives in the *order* of
the boxes instead, which loses nothing, because the top of the page is still
whatever needs you most. Session order here is therefore the opposite choice
from the picker's list, where it is tmux's own creation order specifically so
the list doesn't reshuffle under you while you work: this screen is read once,
on arrival, and then acted on.

**A card title's chips are only the three states that mean something** — ⏸ / ✔
/ ▶ — with everything quiet collapsed into a dim `+6 安静`. Aged-out DONE and
READ both draw with a tick, so listing them as chips put the same glyph on the
line twice, distinguishable only by intensity, hiding exactly the distinction
(unread vs already-seen) that must not need a second look.

**The rows are selectable and Enter jumps.** A pane row jumps to its pane; a
card title jumps to that session's active pane — where you last were in it.
Two kinds of row have nothing to jump to: the blank line between cards, and a
teammate the roster knows about that has no pane (or a pane nothing is
tracking). Those keep an empty jump field, and Enter on one puts a warning in
the footer instead of leaving the page. **Listing them at all is the point** —
the picker's list can't, because every row there is a jump target and one that
silently swallowed Enter would be worse than not listing it. This page can,
because here Enter can explain itself.

**The preview is state, not screen.** The picker's own preview is the live
screen; a second copy of it here would say nothing new. So a pane's card
answers what a screen dump can't: where it is, how long it has been in this
state, how full its context is (`ctx_bar`, the same meter as the statusline),
which team owns it and what that member is on, what it has read in today, and
its opening prompt. A session's card is the same question one level up —
per-state counts, which windows it spans, its most urgent pane, the teams
running in it, and a per-pane 读入 column the list has no room for. The 今日
figures come from a `token-report.py` cache warmed in the background, so a
card drawn in the first half-second simply has no 今日 line rather than
waiting for one.

**The greeting line is the whole point.** It states the number that decides
what you do next — `5 个有结果等你看` — and states the good case out loud
(`没人等你 · 2 个还在跑`) rather than leaving you to infer it from three
empty lists. A dashboard you have to interpret is a list with extra steps.

Three deliberate reuses, because this screen's only original content is the
*bucketing*:

- `display_name`, `label_of` and `fmt_age` are imported from
  `bin/session-digest.py` (which has a `__main__` guard, so importing it
  runs nothing; the hyphen in the filename is why it goes through
  `importlib` rather than a plain import). A pane is therefore called the
  same thing and its age worded the same way here as in the list and in the
  preview. The first version of this screen named panes after their tmux
  *window*, and three teammates in one window all came out as `lead` —
  exactly the bug `display_name` exists to prevent.
- The resource half is `bin/usage-footer.sh`, printed verbatim. It already
  computes those numbers, in ANSI, and two implementations of one number is
  how they come to disagree.
- `agent_teams.snapshot()` for the roster and task counts.

`input` (Claude idle, waiting on your next message) is rendered as DONE, the
way the row list renders it — both mean "it finished, it's your turn", and
this screen already groups them under `等你`. The rank is collapsed rather
than the label, so the age phrasing follows automatically.
`session-digest`'s own preview keeps IDLE separate because there the subject
is one pane in detail.

**What each part costs, which is why the page is shaped this way.** The cards
are ~0.05s (one status file, one `tmux list-panes`, one roster read), so `r`
can rebuild rows, greeting and footer freely. A card preview adds a transcript
tail read. The quota block costs ~0.5s and is computed **once**, at open: `r`
is about the panes, and none of the keys change the quota. The token cache is
warmed in the background and nothing waits on it. Nothing is marked read:
looking at the bridge is not visiting a pane.

**Footers are swapped through `transform-footer(cat FILE)`, never inlined.**
fzf parses an action's argument by matching parentheses, and this page's footer
carries the sparkline line `峰值 9.1M (07-31)`. Balanced brackets happen to
survive, but the first unbalanced one in whatever the quota block prints would
silently truncate the action — so both versions of the footer (clean, and with
the Enter warning) are written to disk and the actions only ever `cat` them.

## The token page (`t`)

The footer answers "how much quota is left". The token page answers the next
question — **where did it go** — across every tracked pane rather than one:
`bin/token-report.py` builds it, `bin/token-page.sh` owns the screen, `t` opens
it, `q` leaves.

**Two blocks, in the order the question gets asked.** An overview of the window
(turns, and the four token classes as share bars) as fzf's header, then a
per-session ranking as the list itself. Only the second one is actionable: with
two dozen Claudes running, "today cost a lot" isn't news — "*this* one costs a
lot" is. Every session in the window gets a row now that the list scrolls, so the
old "还有 N 个会话未显示" footnote has nothing left to say; the column head is the
last header line, which keeps it pinned above the rows.

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

**It is a second fzf, and it started out not being one.** The first version was
a read-key redraw loop, on the reasoning that nothing on the page was selectable,
so nesting fzf inside fzf's `execute()` would only mean two sets of bindings
fighting over `j`/`k`. Both halves of that were wrong, and the page said so out
loud: the ranking *is* a list, what you want from a row ("which session is this,
and what is it doing with all those tokens") is exactly what a preview window is
for, and — the part that actually hurt — **the loop redrew on every keypress,
including the keys it went on to ignore.** One `case` handled `1`/`7`/`q`; every
other key fell through to a fresh ~1s transcript scan that arrived back at the
same screen. Reported as "每次点击一个按键就要刷新 1s,感觉很卡".

Terminal size still comes from `stty size < /dev/tty` rather than `tput`: inside
command substitution tput's stdout is a pipe, so ncurses asks stderr instead, and
with stderr redirected it finds no terminal and reports the terminfo default
24×80 — which sized the page for a third of the real screen. The page runs
without `--height`, so fzf takes the alternate screen buffer and leaving it
restores the picker's screen underneath instead of making it redraw.

**The scan is split from the rendering by a cache file, and that is what makes
the page cheap.** `token-report.py --scan --days N --cache F` writes one JSON
file; `--overview`, `--rows` and `--detail` only ever read it. So a cursor move
costs a small JSON read (~30ms including the live screen capture), not a scan.
Three consequences worth knowing:

- **Renders never scan.** A missing cache makes `--rows`/`--detail` print nothing
  and exit 0, rather than quietly doing the 1s of work this split exists to keep
  off the keypress.
- **The window switch is warmed in the background.** Opening the page scans the
  window you asked for, then forks a scan of the other one. `7` is usually
  instant (measured 117ms and 132ms for the round trip); beat the warmer to it
  and the bind's own `--scan` does the work instead — duplicated, never corrupt,
  because the cache is replaced with `os.replace`.
- **The page tracks no state of its own.** Each row carries the cache it was
  built from as its third field, so `{3}` tells the preview what to read and
  tells `r` what to rescan. `--scan --force` with no `--days` takes the window
  from the cache it is replacing, which is what lets `r` be one string for both
  windows. The cost is an empty window (no turns at all): no row, so no `{3}`,
  so `r` does nothing there.

**`reload`, not `reload-sync`, put the preview one window behind.** The switch is
four actions — `execute-silent(scan)+reload(rows)+transform-header(overview)+first`
— and `reload` is asynchronous: `first` applied to the *old* list, the preview
fired for the old row 1 out of the old cache, and nothing re-fired it when the
new rows landed. The screen then showed the 7-day ranking beside a card of
today's numbers, which is the one failure mode a page like this must not have.
`reload-sync` waits for the rows before applying the rest.

**The ranking finally has session names in it.** It used to print `sid[:8]` — the
one thing about a session that means nothing to the person reading it. The chain
is the picker's chain (`list-rows.sh`), joined to a transcript through the status
file's `session_id`: a name someone chose (`claude_sessions.py`) → the Agent
Teams roster name → the pane title → the tmux window name. Below that sits one
level the picker doesn't have: **a session's opening prompt**, which is the only
human-readable label a transcript with no live pane has left. It is marked dim in
the list and titled `未命名会话` in the card, because a sentence is not a name and
a truncated one must not read as somebody's choice. Bounded to the top 30 rows —
it is a file read per session, and the tail of the ranking is not what anybody is
looking at.

**Enter jumps, and a page inside `execute()` cannot do that by itself.** The
page runs as a child of the picker's fzf, so it can neither exit the picker nor
usefully switch the client — switching from inside the popup leaves the picker
sitting open on top of the pane you just asked to be taken to. So the jump is a
handoff: `bin/jump-handoff.sh` writes the pane id to `$JUMP_FILE` (created by the
picker, cleaned up in its trap) and returns `abort`; the `t` binding's **trailing**
transform runs after `execute()` returns and turns a non-empty `$JUMP_FILE` into
an `abort` for the picker's own fzf; and the jump itself happens in the one place
that already knew how — the picker's tail, with its existence check, its
`mark-read`, and its `switch-client`/`select-window`/`select-pane`. Run outside
the picker (`token-page.sh` by hand) there is no `$JUMP_FILE` and no one to hand
to, so that path switches the client itself.

**A dead row must not leave the page.** Half of a token ranking is sessions that
have already closed — that is what the 7-day window is for — and exiting on Enter
there would read as a jump that failed. Field 4 of a row is the pane, empty for
those, and Enter on one swaps the footer for a warning (with the key hints still
in it) and stays put.

**`tmux display-message -p -t <pane> ''` is not a liveness check**, which three
scripts here believed for months. For a pane id that no longer exists it exits 0
and prints an empty format — measured with `%99999` — so every "pane 已经不存在了"
guard in this repo was dead code, and a stale pane fell through to a raw tmux
error instead. `tmux has-session -t <pane>` does the right thing (exit 1,
`can't find pane: %99999`). It resolves an *empty* target to the current pane and
exits 0, so callers still have to reject empty first.

**Never let a probe run reach `switch-client`.** Verifying the jump end-to-end in
a detached probe session moved the *real* client into the probe: a tmux command
run from a pane whose session has no client attached resolves "the current
client" to the most recently active client on the server, which is the one in
front of the person running the test. Nothing was lost and the client was already
back where it started, but the safe shape for this test is a stub `tmux` on
`PATH` that logs `switch-client`/`select-window`/`select-pane` and forwards
everything else.

**What the preview says, and why the live screen is at the bottom of it.** The
card is who the session is (name, status, elapsed, `session:window`, pane id,
short id, cwd), what it was asked to do (its opening prompt), and where its
tokens went (turns, mean per turn, peak, model, last activity, the four classes
as share bars, a per-day sparkline in the 7-day view, and its share of the
window's read volume). Under that: the live screen for a session still open in a
pane, or the tail of its last reply for one that has closed. This is the
*opposite* order from `preview-row.sh`, which puts the screen first because a
pane preview is a screen dump with a footnote. Here the numbers are the point, so
they get the top and the capture is trimmed to what is actually left over
(`capture-pane -S -N` returns N + pane-height lines, so a 30-row budget came
back as 75 and pushed the card off the top until the tail was taken explicitly).

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
