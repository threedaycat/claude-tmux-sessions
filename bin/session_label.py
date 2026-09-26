#!/usr/bin/env python3
"""A short, generated name for each session nobody named by hand.

The naming chain (list-rows.sh display_name) had nothing between "a name a
person chose" and "Claude's own pane title". The pane title is Claude Code's
summary of the *opening* ask — a question, often a sentence long, and never
updated after the first turn. When several Claude sessions work in one
project, what tells them apart is which part of it each one is building
("media library", "tmux mouse"), and that's what the question rarely says.

So: sample what the user said across the whole session, ask a small model
for a 2-6 character (or 1-3 word) name of the feature it spends its time on,
and cache it by session id.

**A name is decided once and then left alone.** A name that drifts with the
latest topic is a name you can't learn. The one exception is a session that
was named while still young (under YOUNG prompts) and has since grown to
GROW times the transcript size — its first name was a guess from too little.

**Nothing slow runs in a caller.** Generating takes seconds, so callers only
read the cache and, for sessions without a name, start one detached worker
(`--fill`); the name shows up on the next render. A lock file keeps it to
one worker at a time, and a failed session isn't retried for RETRY seconds.

The name is also written to the pane option `@claude_label`, so a tmux
window-status format can show it (`#{?@claude_label,#{@claude_label},#W}`).
A session renamed with /rename gets the option cleared: the chosen name wins
everywhere.

Everything this writes is its own cache file and that one pane option.
Claude Code's files are only read.
"""
import glob
import json
import os
import re
import subprocess
import sys
import time

CLAUDE_HOME = os.environ.get("CLAUDE_HOME") or os.path.expanduser("~/.claude")
CACHE = os.path.join(CLAUDE_HOME, "tmux-claude-labels.json")
LOCK = CACHE + ".lock"
LOCK_STALE = 300      # a worker older than this died without cleaning up
RETRY = 3600          # a session that failed to get a name waits this long
YOUNG, GROW = 8, 4    # see the module docstring
SAMPLES, SAMPLE_CHARS = 25, 200
MAX_LEN = 16
MODEL = os.environ.get("CLAUDE_TMUX_LABEL_MODEL", "haiku")

PROMPT = (
    "Below are messages a user typed in one coding session, sampled evenly "
    "from start to end. Name the session after the feature or module it "
    "spends most of its time on (not the latest topic). Use the language the "
    "user writes in: 2 to 6 characters for Chinese or Japanese, otherwise 1 "
    "to 3 words. A noun phrase: no question, no leading verb, no "
    "punctuation, no quotes. Output only the name.\n\n")


def _load():
    try:
        with open(CACHE) as f:
            got = json.load(f)
        return got if isinstance(got, dict) else {}
    except Exception:
        return {}


def _save(cache):
    try:
        tmp = f"{CACHE}.{os.getpid()}.tmp"
        with open(tmp, "w") as f:
            json.dump(cache, f, ensure_ascii=False)
        os.replace(tmp, CACHE)
    except Exception:
        pass


def _tmux(*args):
    try:
        return subprocess.run(["tmux", *args], capture_output=True,
                              text=True, timeout=5).stdout
    except Exception:
        return ""


def _size(path):
    try:
        return os.path.getsize(path)
    except (OSError, TypeError):
        return 0


def _needs_name(rec):
    """Does this cache record (or its absence) call for a worker?"""
    if not rec:
        return True
    if rec.get("label"):
        return (rec.get("prompts", YOUNG) < YOUNG and
                _size(rec.get("path")) > GROW * max(1, rec.get("size", 0)))
    return time.time() - rec.get("failed", 0) > RETRY


def labels(data, skip=()):
    """{pane: name} from the cache, for the status file's dict `data`.

    Sessions in `skip` (the hand-named ones) are neither returned nor
    generated. Any others without a usable name go to one background worker.
    """
    cache = _load()
    got, todo = {}, []
    for pane, entry in data.items():
        sid = (entry.get("session_id") or "").strip()
        if not sid or sid in skip:
            continue
        rec = cache.get(sid)
        if rec and rec.get("label"):
            got[pane] = rec["label"]
        if _needs_name(rec):
            todo.append(f"{pane}={sid}")
    if todo:
        spawn(todo)
    return got


def ensure(pane, sid, manual=""):
    """For the Stop hook: keep `@claude_label` on this pane right, and start
    a worker if the session still needs a name. One cache read, at most one
    tmux call."""
    if not pane or not sid:
        return
    if manual:
        _tmux("set", "-pu", "-t", pane, "@claude_label")
        return
    rec = _load().get(sid)
    if rec and rec.get("label"):
        _tmux("set", "-p", "-t", pane, "@claude_label", rec["label"])
    if _needs_name(rec):
        spawn([f"{pane}={sid}"])


def spawn(todo):
    """Start the worker detached, unless one is already running."""
    try:
        if time.time() - os.path.getmtime(LOCK) < LOCK_STALE:
            return
    except OSError:
        pass
    try:
        with open(LOCK, "w") as f:
            f.write(str(os.getpid()))
        subprocess.Popen([sys.executable, os.path.abspath(__file__), "--fill", *todo],
                         stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                         stderr=subprocess.DEVNULL, start_new_session=True)
    except Exception:
        pass


def transcript(sid):
    hits = glob.glob(os.path.join(CLAUDE_HOME, "projects", "*", sid + ".jsonl"))
    return max(hits, key=_size) if hits else None


def prompts(path):
    """What the user typed, main thread only, oldest first."""
    out = []
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            if '"user"' not in line:
                continue
            try:
                e = json.loads(line)
            except ValueError:
                continue
            if e.get("type") != "user" or e.get("isSidechain") or e.get("isMeta"):
                continue
            c = (e.get("message") or {}).get("content")
            if isinstance(c, list):
                if any(isinstance(b, dict) and b.get("type") == "tool_result" for b in c):
                    continue
                c = " ".join(b.get("text", "") for b in c
                             if isinstance(b, dict) and b.get("type") == "text")
            if isinstance(c, str) and c.strip() and not c.lstrip().startswith("<"):
                out.append(c.strip())
    return out


def clean(raw):
    """The model's answer, reduced to a name or ""."""
    lines = [l for l in (raw or "").strip().splitlines() if l.strip()]
    if not lines:
        return ""
    name = re.sub(r"[\"'`“”‘’「」『』《》*#。，、：:,.!?！？]", "", lines[0]).strip()
    return name[:MAX_LEN]


def generate(said):
    step = max(1, len(said) // SAMPLES)
    sample = "\n---\n".join(p[:SAMPLE_CHARS] for p in said[::step])
    # No tmux vars: the throwaway session must not show up as a pane of its
    # own. No setting sources: no hooks, so it doesn't reach the status file
    # (or this worker) either. No persistence: no transcript left behind.
    env = {k: v for k, v in os.environ.items() if k not in ("TMUX", "TMUX_PANE")}
    try:
        r = subprocess.run(
            ["claude", "-p", "--model", MODEL, "--setting-sources", "",
             "--no-session-persistence", PROMPT + sample],
            capture_output=True, text=True, env=env, timeout=120, cwd="/")
    except Exception:
        return ""
    return clean(r.stdout) if r.returncode == 0 else ""


def fill(todo):
    try:
        for item in todo:
            pane, _, sid = item.partition("=")
            if not _needs_name(_load().get(sid)):
                continue
            path = transcript(sid)
            said = prompts(path) if path else []
            if not said:
                continue            # nothing to go on yet; next render retries
            name = generate(said)
            cache = _load()         # re-read: someone may have written meanwhile
            if name:
                cache[sid] = {"label": name, "prompts": len(said),
                              "size": _size(path), "path": path, "at": int(time.time())}
                _tmux("set", "-p", "-t", pane, "@claude_label", name)
            else:
                cache[sid] = {**(cache.get(sid) or {}), "failed": int(time.time())}
            _save(cache)
            os.utime(LOCK)          # still alive
    finally:
        try:
            os.remove(LOCK)
        except OSError:
            pass


if __name__ == "__main__":
    if sys.argv[1:2] == ["--fill"]:
        fill(sys.argv[2:])
    else:                                        # a quick look from a shell
        for sid, rec in sorted(_load().items(), key=lambda kv: kv[1].get("at", 0)):
            print(f"{rec.get('label') or '(failed)':16} {sid}")
