#!/usr/bin/env python3
"""What each tracked pane is actually working on, for the picker's rows.

The name column answers "which Claude is this"; it does not answer "what
is it doing". Most of the time it nearly does — the window name follows
Claude's own pane title, and `Nearbygroup 标签页来源` needs no gloss — but
the names that don't carry are exactly the ones you can't place: `fix`,
`product`, `后台`, `claude`. The session's opening ask is the closest
thing to a task label that exists (see session-digest.first_prompt, which
this borrows rather than copying), so it fills the row's trailing field.

Why a cache: first_prompt reads up to 300KB off the head of a transcript,
and the picker renders every tracked pane at once — on this machine, 29 of
them, so ~8MB of reads per open. But a session's *first* prompt is the one
thing about it that can never change, so it is worth exactly one read ever.
Keyed by session_id, which is stable across renames, moves and restarts.

Only hits are cached. A miss means the transcript isn't there yet or holds
nothing but meta records — both true only for a session that has barely
started, and both cheap to re-check (a failed open, or a short file). Cache
those and a pane that was new once would stay blank forever.
"""
import importlib.util
import json
import os

CACHE = os.path.expanduser("~/.claude/tmux-claude-tasks.json")
PROJECTS_DIR = os.path.expanduser("~/.claude/projects")


def _first_prompt():
    """session-digest.py's extractor, loaded by path because the filename
    has a hyphen in it. Safe to exec: that file guards its main."""
    src = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                       "session-digest.py")
    spec = importlib.util.spec_from_file_location("_session_digest", src)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod.first_prompt


def _load():
    try:
        with open(CACHE) as f:
            got = json.load(f)
        return got if isinstance(got, dict) else {}
    except Exception:
        return {}


def _save(cache):
    """Temp file + rename, same reason the status file does it: this runs
    from the picker, which the user closes whenever they feel like it."""
    try:
        tmp = f"{CACHE}.{os.getpid()}.tmp"
        with open(tmp, "w") as f:
            json.dump(cache, f)
        os.replace(tmp, CACHE)
    except Exception:
        pass


def tasks(data):
    """{pane: opening ask} for the entries that have one.

    `data` is the status file's dict. Panes with no session_id or cwd are
    skipped — without both there's no transcript path to look up.
    """
    cache = _load()
    fresh = {}
    extract = None
    for pane, entry in data.items():
        sid, cwd = entry.get("session_id"), entry.get("cwd")
        if not sid or not cwd:
            continue
        if sid in cache:
            if cache[sid]:
                fresh[pane] = cache[sid]
            continue
        if extract is None:
            try:
                extract = _first_prompt()
            except Exception:
                return fresh      # can't load it at all — degrade to no tasks
        path = os.path.join(PROJECTS_DIR, cwd.replace("/", "-"), sid + ".jsonl")
        try:
            got = extract(path)
        except Exception:
            got = None
        if got:
            cache[sid] = got
            fresh[pane] = got
    if fresh:
        _save(cache)
    return fresh
