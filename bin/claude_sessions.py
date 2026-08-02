#!/usr/bin/env python3
"""Read-only view of Claude Code's own per-session records, for the picker.

The picker's name column has always reserved its first level for "the name
somebody chose for this session", and until now nothing filled it: the
status file this repo writes has no such field, and — checked against the
binary — neither does any hook payload, so the hooks cannot record one.

Claude Code does keep it, in its own files:

    ~/.claude/sessions/{pid}.json

with `name` and, when the name was generated rather than chosen,
`nameSource: "derived"`. That is the whole reason this module exists as its
own file rather than a few lines in either renderer: it is a second
external format this repo does not own, and the rule that kept
`agent_teams.py` honest applies unchanged — one parser, so the row list and
the preview of that row can never disagree about what a pane is called.

**Everything here is read-only, and there is deliberately no function that
writes.** These files belong to another process.

Nothing here runs unless the directory exists — callers stat it first and
skip the import otherwise, exactly as they do for teams.
"""

import json
import os

# Same knob, same reason as agent_teams.CLAUDE_HOME: the degradation path
# ("no such directory") has to be exercisable without touching the real
# ~/.claude.
CLAUDE_HOME = os.environ.get("CLAUDE_HOME") or os.path.expanduser("~/.claude")


def sessions_dir():
    return os.path.join(CLAUDE_HOME, "sessions")


def available():
    """Is there anything to read? One stat."""
    return os.path.isdir(sessions_dir())


_cache = None


def manual_names():
    """`{session_id: name}`, and only for names a person actually chose.

    Three things about the files make this more than a dict comprehension,
    and all three are properties of a format we don't control:

    **1. Only the hand-picked names count.** Claude Code names every
    session, most of them by derivation from the cwd (`api-server-8f`) —
    including from `$HOME` itself, which is how a *user name* ends up in
    one — and marks those `nameSource: "derived"`. A derived
    name is strictly worse than what levels 2-4 of the chain already
    produce — it is the directory this pane sits in, which the row's own
    trailing field says better — so promoting one to the top of the chain
    would make the name column *less* accurate for everybody who has never
    renamed anything.

    The test is therefore "the field is absent", not "the field isn't
    derived". `/rename` writes no `nameSource` at all, so absence is what a
    chosen name looks like today. The strict reading is the safe one under
    a format that will change: a future `nameSource: "user"` would be
    rejected, which loses a name that was never shown before and is
    invisible; the loose reading would let a future `nameSource: "auto"`
    through and quietly downgrade the column for people with no teams and
    no renames anywhere near them.

    **2. The files are keyed by pid, not by session.** A crashed Claude
    leaves its file behind, and a resumed session gets a new pid and a new
    file while the old one still names the same `sessionId`. So this
    indexes by `sessionId` — which is what the status file records and the
    only key the two sides share — and when two files claim the same one,
    the larger `updatedAt` wins. `status` is *not* used for this: it holds
    `idle`/`busy`, which says what a session was doing and nothing about
    whether the process is still there.

    **3. Anything unreadable is skipped, never fatal.** These files are
    rewritten by another process, so catching a half-written one is
    ordinary operation. A name that fails to load simply falls through to
    the next level of the chain, which is where it was before this module
    existed.

    Memoised for the life of the process. Every caller is a short-lived
    render, and within one render the answer cannot change."""
    global _cache
    if _cache is not None:
        return _cache

    best = {}
    try:
        entries = os.listdir(sessions_dir())
    except OSError:
        entries = []

    for n in entries:
        if not n.endswith(".json"):
            continue
        try:
            with open(os.path.join(sessions_dir(), n), encoding="utf-8") as f:
                rec = json.load(f)
        except Exception:                                      # noqa: BLE001
            continue
        if not isinstance(rec, dict) or "nameSource" in rec:
            continue
        sid = rec.get("sessionId")
        name = rec.get("name")
        if not isinstance(sid, str) or not sid.strip():
            continue
        if not isinstance(name, str) or not name.strip():
            continue
        ts = rec.get("updatedAt")
        ts = ts if isinstance(ts, (int, float)) else 0
        prev = best.get(sid.strip())
        if prev is None or ts > prev[0]:
            best[sid.strip()] = (ts, name.strip())

    _cache = {sid: v[1] for sid, v in best.items()}
    return _cache


def name_of(session_id):
    """The chosen name for one session, or "" — the shape both renderers
    want at the top of their naming chain."""
    if not session_id:
        return ""
    return manual_names().get(session_id.strip(), "")


if __name__ == "__main__":                       # a quick look from a shell
    d = manual_names()
    if not d:
        print(f"没有找到任何人起的会话名。(找的是 {sessions_dir()}/*.json)")
    for sid, name in sorted(d.items(), key=lambda kv: kv[1]):
        print(f"{name:24} {sid}")
