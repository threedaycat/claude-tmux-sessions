#!/usr/bin/env python3
"""The picker's overview: one screen that answers "I'm back — what's the
situation", opened with `o`.

The row list shows you everything in tmux order and leaves the reading to
you. This answers the question you actually have when you sit down, in the
order you have it:

  1. does anything need me right now  (⏸ WAIT first, then unread ✔ DONE)
  2. what is still working            (▶ RUN)
  3. how are the teams doing          (roster + task counts + each member's
                                       own state, joined in by pane id)

and nothing else. The resource half of the screen — 5h quota, 7-day window,
today's tokens — is `bin/usage-footer.sh` printed underneath by
overview-page.sh, unchanged: it already computes exactly that, in ANSI, and
two implementations of one number is how they come to disagree.

**Nothing here classifies a pane by itself.** `display_name`, `label_of` and
`fmt_age` are imported from bin/session-digest.py, so a pane is called the
same thing and its state is worded the same way as in the list and in the
preview of that list. The only local rule is which bucket a pane lands in,
which is this screen's own editorial judgement — and the one thing the other
screens have no opinion about.

Read-only: the status file, the roster, and `tmux list-panes`. It marks
nothing read — looking at the bridge is not visiting a pane.
"""
import importlib.util
import json
import os
import subprocess
import sys
import time

BIN_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BIN_DIR)
import agent_teams                                            # noqa: E402

# session-digest.py can't be imported by name (the hyphen isn't a legal
# module name), and it is worth the four lines: it is where the naming and
# state-wording rules already live, guarded by a __main__ check so importing
# it runs nothing. Copying them here instead would make a third copy of
# rules DESIGN.md already calls out as dangerous to duplicate.
_spec = importlib.util.spec_from_file_location(
    "session_digest", os.path.join(BIN_DIR, "session-digest.py"))
sd = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(sd)

STATUS_FILE = os.path.expanduser("~/.claude/tmux-claude-status.json")
# Same threshold and env override as the row list and the ambient bar: an
# unread DONE nobody came back to for this long is abandoned, not pending.
IDLE_STALE = int(os.environ.get("CLAUDE_TMUX_IDLE_STALE_SECS", "7200"))

DIM = "\033[2m"
RESET = "\033[0m"
BOLD = "\033[1m"
RED = "\033[1;31m"
GREEN = "\033[1;32m"
CYAN = "\033[36m"

# rank -> the icon the row list puts in front of the label. Keyed on rank,
# not on status, so the state logic itself stays in one place: label_of
# answers *what* this pane is, this only says how to draw it.
ICON = {-1: "⏸︎", 1: "✔︎", 2: "▶︎", 3: "✓︎"}

# `input` (Claude idle, waiting on your next message) is rendered as DONE,
# the way the row list renders it: both mean "it finished, it's your turn",
# and this screen already groups them under 等你. session-digest's own
# preview keeps them apart because there the subject is one pane in detail;
# here a second word for the same situation would just make the list and the
# overview disagree about what a pane is called. Collapsing the rank is what
# does it — label and age phrasing both follow from it.
IDLE_RANK, DONE_RANK = 0, 1
DONE_LABEL = "\033[1;32mDONE\033[0m"

NAME_W = 22
WHERE_W = 15


def collect():
    """Every tracked, live, unarchived pane, bucketed. Panes that are gone
    or archived are dropped rather than counted: the question on this screen
    is what is in front of you *now*."""
    try:
        with open(STATUS_FILE) as f:
            data = json.load(f)
    except Exception:
        data = {}

    # Names and window names from tmux itself rather than from the recorded
    # entry — a window renamed after the status was written still reads
    # correctly. Same choice as the ambient bar and the picker.
    try:
        out = subprocess.check_output(
            ["tmux", "list-panes", "-a", "-F",
             "#{pane_id}\t#{session_name}\t#{window_index}\t#{window_name}"
             "\t#{pane_title}"], text=True)
    except Exception:
        out = ""
    live = {}
    for line in out.splitlines():
        p = line.split("\t")
        if len(p) == 5:
            live[p[0]] = p[1:]

    snap = agent_teams.snapshot()
    now = time.time()
    buckets = {"wait": [], "done": [], "run": []}
    totals = {"read": 0, "stale": 0, "tracked": 0}
    by_pane = {}
    for pane, e in data.items():
        if pane not in live or e.get("archived"):
            continue
        session, win_idx, win_name, pane_title = live[pane]
        member = snap["by_pane"].get(pane)
        age = int(now - e.get("updated_at", now))
        status = e.get("status", "running")
        totals["tracked"] += 1
        if status == "blocked" and not e.get("read"):
            kind = "wait"
        elif status == "blocked":
            # Blocked but already visited: the prompt is still up, but you
            # have seen it, so it is not what this screen should shout about.
            kind = "read"
        elif status in ("done", "input") and e.get("read"):
            kind = "read"
        elif status in ("done", "input") and age >= IDLE_STALE:
            kind = "stale"
        elif status in ("done", "input"):
            kind = "done"
        else:
            kind = "run"
        label, rank = sd.label_of(e)
        if rank == IDLE_RANK:
            label, rank = DONE_LABEL, DONE_RANK
        row = {"pane": pane, "where": f"{session}:{win_idx}", "age": age,
               "kind": kind, "rank": rank, "label": label,
               "name": sd.display_name(pane, e, win_name, pane_title, member)}
        by_pane[pane] = row
        if kind in buckets:
            buckets[kind].append(row)
        else:
            totals[kind] += 1

    # Longest-waiting first among the things that need you — that is the
    # order in which they became your problem. Newest first among the
    # finished and the running: "what just landed" and "what did I start
    # last" are the useful ends of those lists.
    buckets["wait"].sort(key=lambda r: -r["age"])
    buckets["done"].sort(key=lambda r: r["age"])
    buckets["run"].sort(key=lambda r: r["age"])
    return buckets, totals, by_pane


def state_cell(row):
    """`⏸︎ WAIT` plus the age worded for that state — both from
    session-digest, so this screen cannot drift from the other two."""
    icon = ICON.get(row["rank"], "·")
    label, when = row["label"], sd.fmt_age(row["rank"], row["age"])
    if row["kind"] == "stale":
        # Aged-out unread: still listed, dimmed, exactly as the row list
        # treats it — reachable, but not competing for attention.
        return f"{DIM}{icon} DONE{RESET}", f"{DIM}{when}{RESET}"
    return f"{icon} {label}", when


def row_line(row, name_w):
    label, when = state_cell(row)
    return (f"    {label}  {sd.pad(sd.clip(row['name'], name_w), name_w)}"
            f"  {DIM}{sd.pad(row['where'], WHERE_W)}{RESET}{when}")


def render(width, budget):
    buckets, totals, by_pane = collect()
    need = buckets["wait"] + buckets["done"]
    out = []

    # The greeting is the one-line answer, readable without looking at
    # anything below it: the number that decides what you do next, and the
    # good case said out loud rather than left to be inferred from three
    # empty lists.
    if buckets["wait"]:
        head = f"{RED}{len(buckets['wait'])} 个等你确认{RESET}"
    elif buckets["done"]:
        head = f"{GREEN}{len(buckets['done'])} 个有结果等你看{RESET}"
    elif buckets["run"]:
        head = f"{DIM}没人等你 · {len(buckets['run'])} 个还在跑{RESET}"
    else:
        head = f"{DIM}没人等你 · 也没人在跑{RESET}"
    out.append(f"  {BOLD}舰桥{RESET}  {DIM}{time.strftime('%H:%M')}{RESET}  {head}")
    tail = (f"在册 {totals['tracked']} · 在跑 {len(buckets['run'])} · "
            f"等你 {len(need)} · 已读 {totals['read']}")
    if totals["stale"]:
        tail += f" · 放久了 {totals['stale']}"
    out.append(f"  {DIM}{tail}{RESET}")
    out.append(f"  {DIM}{'─' * max(10, width - 4)}{RESET}")

    name_w = max(14, min(34, width - 46))

    # Room goes to `等你` first and only what is left to `在跑`. A screen
    # that clipped `等你` to keep `在跑` whole would be clipping the one part
    # nobody can afford to miss.
    if need:
        out.append("")
        out.append(f"  {BOLD}等你 {len(need)}{RESET}")
        for r in need[:budget]:
            out.append(row_line(r, name_w))
        if len(need) > budget:
            out.append(f"    {DIM}还有 {len(need) - budget} 个未显示{RESET}")
    room = max(0, budget - len(need[:budget]))
    if buckets["run"]:
        out.append("")
        out.append(f"  {DIM}在跑 {len(buckets['run'])}{RESET}")
        for r in buckets["run"][:room]:
            out.append(row_line(r, name_w))
        if len(buckets["run"]) > room:
            out.append(f"    {DIM}还有 {len(buckets['run']) - room} 个未显示{RESET}")

    # Teams. Every member is listed, including the ones with no pane — a
    # member that has not reported in is a fact to show, not a row to hide —
    # and each pane's state is joined in from the bucketing above, so the
    # block answers "is anyone on this team stuck" without re-reading the
    # lists.
    for team in agent_teams.snapshot()["teams"]:
        c = team["counts"]
        out.append("")
        out.append(f"  {CYAN}编队 {sd.clip(team['team'], 28)}{RESET}  {DIM}队员 "
                   f"{len(team['members'])} · 在做 {c['in_progress']} · 待领 "
                   f"{c['pending']} · 挡住 {c['blocked']} · 完成 "
                   f"{c['completed']}{RESET}")
        for m in team["members"]:
            sgr = f"\033[{m['sgr']}m" if m.get("sgr") else ""
            name = sgr + sd.pad(sd.clip(m["name"], 16), 16) + (RESET if sgr else "")
            if not m["pane"]:
                out.append(f"    {name}  {DIM}没有 pane{RESET}")
                continue
            row = by_pane.get(m["pane"])
            if row is None:
                # Has a pane id, but no tracked status for it: the pane is
                # gone, or Claude in it never fired a hook.
                out.append(f"    {name}  {DIM}{m['pane']} 没在跟踪{RESET}")
                continue
            label, when = state_cell(row)
            box = f"  {RED}信箱 {m['inbox']}{RESET}" if m.get("inbox") else ""
            doing = (f"  {DIM}{sd.clip(m['doing'], max(10, width - 70))}{RESET}"
                     if m["doing"] else "")
            out.append(f"    {name}  {label}  {sd.pad(when, 16)}"
                       f"{DIM}{sd.pad(row['where'], WHERE_W)}{RESET}{box}{doing}")
    return out


def main():
    width, budget = 100, 8
    args = sys.argv[1:]
    for i, a in enumerate(args):
        if a == "--width" and i + 1 < len(args):
            width = max(60, int(args[i + 1]))
        elif a == "--top" and i + 1 < len(args):
            budget = max(2, int(args[i + 1]))
    print("\n".join(render(width, budget)))


if __name__ == "__main__":
    main()
