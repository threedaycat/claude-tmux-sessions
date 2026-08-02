#!/usr/bin/env python3
"""Read-only view of Claude Code's Agent Teams state, for the picker.

Why this exists as its own module: the picker lists tmux panes running
Claude, and Agent Teams introduces panes that belong to something bigger
than themselves — a team, with a roster and a shared task list. That
context lives in a handful of JSON files under `~/.claude` whose format
this repo does not own. Keeping every read of it in one place means the
row list and the preview can never disagree about who is on a team; two
parsers drift apart the first time the format moves.

Where the official state lives (Agent Teams is a research preview — treat
every shape below as something that *will* change):

    ~/.claude/teams/{team}/config.json          the roster
    ~/.claude/teams/{team}/inboxes/{name}.json  one member's unread messages
    ~/.claude/tasks/{team}/{n}.json             shared task list, one per file

**Everything here is read-only, and there is deliberately no function that
writes.** These files are runtime state owned by another process, which
rewrites them whenever it likes; anything written here would be clobbered.

Nothing in this module runs unless a `teams/` directory actually exists —
callers check that first (see `available`) and skip the import entirely
otherwise, which is what keeps the picker byte-for-byte unchanged for
everyone who has never switched Agent Teams on.
"""

import glob
import json
import os

# Overridable so the "no teams" degradation path can be exercised against
# an empty directory without touching, or even reading, the real
# ~/.claude. That is this module's only knob; there is no config file.
CLAUDE_HOME = os.environ.get("CLAUDE_HOME") or os.path.expanduser("~/.claude")

# The one role the official format names outright. Every other member's
# agentType is whichever agent type the lead happened to spawn it as
# ("general-purpose"), or absent — so it identifies a *kind of worker*,
# never a role on the team. Only "is this the lead" can be read from it.
LEAD_TYPE = "team-lead"


def teams_dir():
    return os.path.join(CLAUDE_HOME, "teams")


def tasks_dir():
    return os.path.join(CLAUDE_HOME, "tasks")


def available():
    """Is there any team state at all? One stat.

    Only `teams/` counts. `tasks/` is deliberately not consulted as
    evidence: it keeps a directory around for *any* session that ever used
    a task list, long after that session ended, so reading it as "a team
    exists" invents teams that don't. Callers generally inline this check
    rather than calling it, because importing this module to ask the
    question would defeat the point of asking."""
    return os.path.isdir(teams_dir())


def _load(path, default):
    """Read one JSON file. **Every exception becomes the default.**

    These files are rewritten continuously by another process, so reading a
    half-written one is ordinary operation, not an error — and the picker
    must not be the thing that falls over when it happens. A missing team
    is indistinguishable from an unreadable one here, on purpose: both mean
    "nothing to show", and neither is worth a diagnostic in a list of tmux
    panes."""
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except Exception:                                          # noqa: BLE001
        return default


def team_names():
    """Every team with a readable roster, sorted for a stable row order.

    Directory names have had at least two shapes (a `session-` prefix plus
    a truncated id, and bare full-length UUIDs from before that), so this
    globs rather than reconstructing a path from a session id — the name is
    whatever is on disk."""
    d = teams_dir()
    if not os.path.isdir(d):
        return []
    return sorted(
        n for n in os.listdir(d)
        if os.path.isfile(os.path.join(d, n, "config.json"))
    )


def members(team):
    """The roster: `[{name, type, is_lead, pane, cwd, colour}]`, lead first.

    **`pane` is the whole reason this module can say anything useful.** The
    picker's world is keyed by tmux pane id, the team's world is keyed by
    member name, and `tmuxPaneId` is the *only* field joining the two —
    member records carry no session id of any kind, so there is no second
    way to make the connection.

    Two sharp edges, both handled here so no caller has to know about them:

      1. **The lead's `tmuxPaneId` is the literal string `"leader"`**, not a
         pane. Only `%`-prefixed values are treated as panes; the rest
         become empty, which correctly reports the lead as unlinked rather
         than matching some unrelated pane.
      2. **The roster's own `leadSessionId` is not read at all.** A team
         directory outlives the session that made it, and that field is not
         refreshed when the lead moves to a new one — it goes stale while
         still looking authoritative. The lead is identified by `agentType`
         and nothing else.
    """
    cfg = _load(os.path.join(teams_dir(), team, "config.json"), {})
    out = []
    for m in cfg.get("members") or []:
        if not isinstance(m, dict):
            continue
        kind = (m.get("agentType") or "").strip()
        pane = (m.get("tmuxPaneId") or "").strip()
        out.append({
            "name": (m.get("name") or "").strip(),
            "type": kind,
            "is_lead": kind == LEAD_TYPE,
            "pane": pane if pane.startswith("%") else "",
            "cwd": (m.get("cwd") or "").strip(),
            "colour": (m.get("color") or "").strip().lower(),
        })
    out.sort(key=lambda m: (not m["is_lead"], m["name"]))
    return [m for m in out if m["name"]]


def inbox_depth(team, name):
    """How many messages are queued for one member. Unreadable means 0.

    A backlog is only ever reported as a small annotation, never as the
    reason a row exists, so guessing high would be worse than guessing
    low."""
    d = _load(os.path.join(teams_dir(), team, "inboxes", f"{name}.json"), [])
    if isinstance(d, list):
        return len(d)
    if isinstance(d, dict):                 # some versions wrap it in a key
        v = d.get("messages")
        return len(v) if isinstance(v, list) else 0
    return 0


def tasks(team):
    """The shared task list — one file per task, named by number.

    Sorted numerically rather than by filename, or `10.json` sorts ahead of
    `2.json` and the numbers shown against members stop matching the order
    anyone reading the task list sees."""
    out = []
    for p in glob.glob(os.path.join(tasks_dir(), team, "*.json")):
        t = _load(p, None)
        if isinstance(t, dict) and t.get("subject"):
            out.append(t)

    def key(t):
        try:
            return (0, int(str(t.get("id", "0"))))
        except (TypeError, ValueError):
            return (1, 0)

    out.sort(key=key)
    return out


def task_owner(t):
    """Who claimed this task, or empty for nobody.

    Older task files predate the field entirely. Empty means unclaimed and
    is left that way — showing somebody else's work against a member's name
    is worse than showing nothing, because the whole value of that column is
    that you can trust it."""
    v = t.get("owner")
    return v.strip() if isinstance(v, str) else ""


def active_task_of(ts, name):
    """The task this member is working on right now, or None."""
    if not name:
        return None
    for t in ts:
        if t.get("status") == "in_progress" and task_owner(t) == name:
            return t
    return None


def task_counts(ts):
    """Just the four numbers the picker actually prints.

    `blocked` is split out of `pending` because the official status mixes
    two very different situations: work nobody has picked up, and work
    nobody *can* pick up until something else lands. Collapsing them reads
    as "this team is idle" when the truth is "this team is waiting".

    **A blocker is only still blocking if it is on disk and unfinished.**
    The test is deliberately written the positive way round — "is this id
    among the open tasks" — and not "is it missing from the completed
    ones", because the two are not equivalent under the way the official
    task list is actually stored. One file per task, and **finishing a task
    can delete its file**. Asking "is it absent from the completed set" then
    answers yes for a task that finished and was cleaned up, and every task
    that depended on it flips from `待领` to `挡住` — the picker starts
    announcing that work is held up by something that is in fact done. That
    is not an edge case; deletion is the normal end of a task's life.

    So an id that names no file at all is treated as **finished**, not as
    pending-and-therefore-blocking. The failure mode this rules out is
    over-reporting, which is the expensive direction: `挡住` is the count
    that makes someone go looking, and sending them after a task that no
    longer exists costs more than a missed one would."""
    open_ids = {str(t.get("id")) for t in ts if t.get("status") != "completed"}
    c = {"pending": 0, "blocked": 0, "in_progress": 0, "completed": 0}
    for t in ts:
        s = t.get("status")
        if s == "pending":
            waiting = [b for b in t.get("blockedBy") or [] if str(b) in open_ids]
            c["blocked" if waiting else "pending"] += 1
        elif s in c:
            c[s] += 1
    return c


def label_overrides():
    """`$CLAUDE_TMUX_TEAM_LABELS` names a JSON file mapping member name to
    the word shown in front of that member's row: `{"docs-writer": "..."}`.

    The picker cannot tell you what any of those words mean, and that is
    the design. The official format distinguishes exactly one role — the
    lead. Every finer distinction is an editorial claim about one specific
    team, which belongs to whoever runs that team rather than to a generic
    pane list. Same seam as `$CLAUDE_TMUX_EXTRA_CMD`: this repo transports
    the value and never interprets it.

    Anything malformed degrades to no overrides, leaving the two labels
    that can always be derived from official data."""
    p = os.environ.get("CLAUDE_TMUX_TEAM_LABELS")
    if not p:
        return {}
    d = _load(p, {})
    if not isinstance(d, dict):
        return {}
    return {
        str(k): str(v) for k, v in d.items()
        if isinstance(k, str) and isinstance(v, (str, int))
    }


# Defaults for the two roles the official data really does distinguish.
LEAD_LABEL = "中枢"
MEMBER_LABEL = "队员"

# The official palette. A teammate is handed one `color` when it is spawned
# and keeps it for the life of the team, which makes it the one per-member
# identity that costs no columns to show — the reason this map exists at
# all (see DESIGN.md, "Naming a pane").
#
# Eight names, and this is the whole set: they are theme tokens on the
# official side, not ANSI names, so the translation to a terminal colour is
# ours to make and is made here rather than in either renderer — two copies
# would drift, and a member would then be one colour in the list and
# another in the preview of that list.
#
# Five map onto ANSI's basic eight, which is what we use for them: a basic
# colour follows whatever palette the terminal is themed with, so it sits
# beside the list's existing cyan and yellow instead of fighting them.
# Purple, orange and pink have no basic equivalent and get the nearest
# xterm-256 index; on a 16-colour terminal those are downsampled rather
# than dropped.
#
# **A colour is never the only thing saying a row is a teammate.** An
# unknown value here — the palette gains a ninth name, a config is
# hand-edited — returns "", which renders the name plainly. That has to
# stay a cosmetic loss, so nothing may key off this map being non-empty.
COLOUR_SGR = {
    "red": "31",
    "blue": "34",
    "green": "32",
    "yellow": "33",
    "cyan": "36",
    "purple": "38;5;141",
    "orange": "38;5;208",
    "pink": "38;5;213",
}


def colour_of(member):
    """The SGR parameters for a member's assigned colour, or "" for none.

    Empty covers three cases that all want the same handling: the lead (no
    colour is assigned to it), an older config written before the field
    existed, and a value this map has never heard of."""
    return COLOUR_SGR.get((member or {}).get("colour") or "", "")


def snapshot():
    """Everything the picker needs, read once.

    Returns `{"teams": [...], "by_pane": {pane: member}}`. `by_pane` is the
    join the row list works from: a pane either appears in it, and is a
    team member, or it doesn't, and is an ordinary Claude pane.

    A member with no pane is still in `teams` but absent from `by_pane`.
    That is the normal state for the lead, and the temporary state for any
    teammate that has not yet reported in, so it is a fact to display
    rather than an error to handle."""
    overrides = label_overrides()
    out, by_pane = [], {}
    for team in team_names():
        ms = members(team)
        ts = tasks(team)
        for m in ms:
            m["team"] = team
            m["inbox"] = inbox_depth(team, m["name"])
            m["label"] = overrides.get(
                m["name"], LEAD_LABEL if m["is_lead"] else MEMBER_LABEL
            )
            # Resolved once, here, so neither renderer has to reach for this
            # module to draw a member — and so the row list and the preview
            # of that row cannot disagree about what colour somebody is.
            m["sgr"] = colour_of(m)
            at = active_task_of(ts, m["name"])
            # activeForm is the present-tense phrasing the task list keeps
            # for exactly this purpose ("Fixing pyright type errors"), so
            # it beats the subject line when the question is "what is this
            # pane doing right now".
            m["doing"] = (at or {}).get("activeForm") or (at or {}).get("subject") or ""
            m["doing_id"] = str((at or {}).get("id") or "")
            if m["pane"]:
                by_pane[m["pane"]] = m
        out.append({
            "team": team,
            "members": ms,
            "counts": task_counts(ts),
            "tasks": ts,
            "unlinked": [m["name"] for m in ms if not m["pane"]],
        })
    return {"teams": out, "by_pane": by_pane}


if __name__ == "__main__":                       # a quick look from a shell
    snap = snapshot()
    if not snap["teams"]:
        print(f"没有找到任何编队。(找的是 {teams_dir()}/*/config.json)")
    for t in snap["teams"]:
        c = t["counts"]
        print(f"编队 {t['team']}  在做 {c['in_progress']} · 待领 {c['pending']}"
              f" · 挡住 {c['blocked']} · 完成 {c['completed']}")
        for m in t["members"]:
            box = f" · 信箱 {m['inbox']}" if m["inbox"] else ""
            print(f"  {m['label']}  {m['name']:16} {m['pane'] or '(没有 pane)':6}"
                  f"{box}  {m['doing']}")
