#!/usr/bin/env python3
"""strip-chrome.py — drop Claude Code's own bottom chrome from a pane capture.

    tmux capture-pane -p -e -t %8 | strip-chrome.py

The bottom of a Claude pane is always the same furniture:

    ─────────────────────────────── name ─   ← top of the input box
    ❯ <whatever is typed>
    ───────────────────────────────────────   ← bottom of the input box
    [model] … context meter                  ← statusline
    ⏵⏵ auto mode on …                        ← mode hint

The picker's preview is anchored to the bottom (`follow`), and in a float
sized to its rows the preview is only a dozen lines tall — which is exactly
that furniture and nothing of what Claude actually said. So cut from the
input box's top border down. Detection is on the ANSI-stripped text: a rule
line, a ❯ prompt within the next few lines, then another rule line. No match
(not a Claude pane, a prompt being answered, a dialog open) means the capture
passes through untouched — a wrong cut would hide more than it saves.
"""
import re
import sys

ANSI = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]")


def is_rule(s):
    s = s.strip()
    return len(s) >= 10 and s.startswith("──")


lines = sys.stdin.read().split("\n")
plain = [ANSI.sub("", l) for l in lines]
cut = None
for i in range(len(plain) - 1, max(-1, len(plain) - 40), -1):
    if not is_rule(plain[i]):
        continue
    after = plain[i + 1:i + 6]
    if any(a.lstrip().startswith("❯") for a in after[:3]) and any(is_rule(a) for a in after[1:]):
        cut = i
if cut is not None:
    lines = lines[:cut]
    while lines and not ANSI.sub("", lines[-1]).strip():
        lines.pop()
sys.stdout.write("\n".join(lines) + "\n")
