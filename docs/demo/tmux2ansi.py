#!/usr/bin/env python3
"""Turn tmux status-line markup into ANSI, so status-badge.sh's output can go
through the same renderer as a captured pane.

status-badge.sh emits `#[fg=#rrggbb,bg=#rrggbb,bold]` because that is what a
tmux status-right consumes — it never passes through a terminal, so there are
no escape sequences to capture. Mapping the attributes to true-colour SGR is
exact for the hex colours the script actually uses.
"""
import re
import sys

ESC = "\x1b["


def sgr(spec):
    if spec in ("default", "") or spec == "none":
        return ESC + "0m"
    codes = []
    for part in spec.split(","):
        part = part.strip()
        if part.startswith("fg=#") or part.startswith("bg=#"):
            base = 38 if part.startswith("fg") else 48
            h = part[4:]
            r, g, b = (int(h[i : i + 2], 16) for i in (0, 2, 4))
            codes.append(f"{base};2;{r};{g};{b}")
        elif part in ("bold", "bright"):
            codes.append("1")
        elif part == "dim":
            codes.append("2")
        elif part == "underscore":
            codes.append("4")
        elif part == "reverse":
            codes.append("7")
        elif part == "default":
            codes.append("0")
    return ESC + ";".join(codes) + "m" if codes else ""


text = sys.stdin.read()
out = re.sub(r"#\[([^\]]*)\]", lambda m: sgr(m.group(1)), text)
sys.stdout.write(out.rstrip("\n") + "\x1b[0m\n")
