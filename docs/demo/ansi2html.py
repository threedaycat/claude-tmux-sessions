#!/usr/bin/env python3
"""Render `tmux capture-pane -e` output to a terminal-looking HTML page.

Why a cell grid instead of just dropping the text in a <pre>: the whole
point of these screenshots is that the columns line up, and that alignment
depends on every CJK glyph advancing exactly two Latin cells. A terminal
guarantees that; a browser font stack does not (PingFang advances 1em, Menlo
0.602em, so CJK would drift left by ~0.2 cells per character and the image
would show misalignment the real tool doesn't have). So every non-ASCII cell
is emitted as an inline-block of exactly one or two cell widths — the same
contract a terminal enforces.

usage: ansi2html.py <capture.ansi> <out.html> [font_px]
"""
import html
import re
import sys
import unicodedata

# Base16-ish palette, close to a default dark terminal.
BG = "#1b1d1e"
FG = "#c9ccc9"
NORMAL = ["#2b2e2b", "#cc5c5c", "#8fb84e", "#d3a44a", "#5f9fd8", "#b07cc4", "#59b3ab", "#c9ccc9"]
BRIGHT = ["#5c625c", "#f06a6a", "#a8d95f", "#f0c674", "#7ab8ea", "#c99ee0", "#74d4cb", "#f2f4f2"]


def xterm(n):
    if n < 8:
        return NORMAL[n]
    if n < 16:
        return BRIGHT[n - 8]
    if n < 232:
        n -= 16
        r, g, b = n // 36, (n % 36) // 6, n % 6
        f = lambda v: 0 if v == 0 else 55 + 40 * v
        return "#%02x%02x%02x" % (f(r), f(g), f(b))
    v = 8 + (n - 232) * 10
    return "#%02x%02x%02x" % (v, v, v)


class Style:
    __slots__ = ("fg", "bg", "bold", "dim", "rev", "ul")

    def __init__(self):
        self.fg = self.bg = None
        self.bold = self.dim = self.rev = self.ul = False

    def copy(self):
        s = Style()
        s.fg, s.bg = self.fg, self.bg
        s.bold, s.dim, s.rev, s.ul = self.bold, self.dim, self.rev, self.ul
        return s

    def key(self):
        return (self.fg, self.bg, self.bold, self.dim, self.rev, self.ul)

    def css(self):
        fg = self.fg or FG
        bg = self.bg
        if self.bold and self.fg is None:
            fg = BRIGHT[7]
        if self.rev:
            fg, bg = bg or BG, fg
        out = []
        if fg != FG:
            out.append(f"color:{fg}")
        if bg:
            out.append(f"background:{bg}")
        if self.bold:
            out.append("font-weight:600")
        if self.dim:
            out.append("opacity:.55")
        if self.ul:
            out.append("text-decoration:underline")
        return ";".join(out)


def apply_sgr(st, params):
    i = 0
    if not params:
        params = [0]
    while i < len(params):
        p = params[i]
        if p == 0:
            st.fg = st.bg = None
            st.bold = st.dim = st.rev = st.ul = False
        elif p == 1:
            st.bold = True
        elif p == 2:
            st.dim = True
        elif p == 4:
            st.ul = True
        elif p == 7:
            st.rev = True
        elif p == 22:
            st.bold = st.dim = False
        elif p == 24:
            st.ul = False
        elif p == 27:
            st.rev = False
        elif 30 <= p <= 37:
            st.fg = NORMAL[p - 30]
        elif p == 39:
            st.fg = None
        elif 40 <= p <= 47:
            st.bg = NORMAL[p - 40]
        elif p == 49:
            st.bg = None
        elif 90 <= p <= 97:
            st.fg = BRIGHT[p - 90]
        elif 100 <= p <= 107:
            st.bg = BRIGHT[p - 100]
        elif p in (38, 48):
            target = "fg" if p == 38 else "bg"
            if i + 1 < len(params) and params[i + 1] == 5:
                setattr(st, target, xterm(params[i + 2]))
                i += 2
            elif i + 1 < len(params) and params[i + 1] == 2:
                r, g, b = params[i + 2 : i + 5]
                setattr(st, target, "#%02x%02x%02x" % (r, g, b))
                i += 4
        i += 1


SGR = re.compile(r"\x1b\[([0-9;]*)m")
OTHER_ESC = re.compile(r"\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b[\[\(][0-9;?]*[A-Za-z]|\x1b.")


def cells(line, st):
    """Split one line into (text, width, style) cells. Zero-width joiners and
    variation selectors ride along with the character they modify — VS15
    (U+FE0E) in particular is load-bearing here: the tool appends it to ⏸ ▶ ✔
    to force the narrow text presentation, and treating it as its own cell
    would shift the rest of the row."""
    out = []
    pos = 0
    while pos < len(line):
        m = SGR.match(line, pos)
        if m:
            apply_sgr(st, [int(x) if x else 0 for x in m.group(1).split(";")])
            pos = m.end()
            continue
        m = OTHER_ESC.match(line, pos)
        if m:
            pos = m.end()
            continue
        ch = line[pos]
        pos += 1
        if unicodedata.combining(ch) or ch in "︎️‍":
            if out:
                out[-1][0] += ch
            continue
        w = 2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1
        out.append([ch, w, st.copy()])
    return out


def render(path, out_path, font_px=15.0):
    raw = open(path, encoding="utf-8", errors="replace").read().split("\n")
    while raw and not raw[-1].strip():
        raw.pop()
    st = Style()
    rows = []
    width = 0
    for line in raw:
        cs = cells(line, st)
        width = max(width, sum(c[1] for c in cs))
        rows.append(cs)

    body = []
    for cs in rows:
        parts = []
        buf, buf_key, buf_style = "", None, None

        def flush():
            nonlocal buf, buf_key, buf_style
            if buf:
                css = buf_style.css()
                if css:
                    parts.append(f'<span style="{css}">{html.escape(buf)}</span>')
                else:
                    parts.append(html.escape(buf))
            buf, buf_key, buf_style = "", None, None

        for text, w, style in cs:
            ascii_narrow = len(text) == 1 and ord(text) < 128
            if ascii_narrow:
                if buf_key is not None and buf_key != style.key():
                    flush()
                if buf_key is None:
                    buf_key, buf_style = style.key(), style
                buf += text
            else:
                flush()
                css = style.css()
                klass = "c2" if w == 2 else "c1"
                parts.append(
                    f'<span class="{klass}"'
                    + (f' style="{css}"' if css else "")
                    + f">{html.escape(text)}</span>"
                )
        flush()
        body.append("<div class=r>" + "".join(parts) + "</div>")

    # Menlo advances 0.60229em; deriving the cell width from that (rather
    # than CSS `ch`) keeps the fixed-width cells correct even though they
    # carry a different font-family for the CJK glyphs.
    cell = font_px * 0.60229
    doc = f"""<!doctype html><meta charset="utf-8"><title>terminal</title>
<style>
  html,body{{margin:0;background:{BG}}}
  .t{{display:inline-block;padding:16px 18px;background:{BG};color:{FG};
      font:{font_px}px/1.46 Menlo,"SF Mono",monospace;
      -webkit-font-smoothing:antialiased}}
  .r{{white-space:pre;height:1.46em}}
  .c1,.c2{{display:inline-block;overflow:hidden;vertical-align:top;
      text-align:center;font-family:Menlo,"PingFang SC","Hiragino Sans",
      "Apple Symbols","Apple Color Emoji",monospace}}
  .c1{{width:{cell:.4f}px}}
  .c2{{width:{cell * 2:.4f}px}}
</style>
<div class=t>{''.join(body)}</div>
"""
    open(out_path, "w", encoding="utf-8").write(doc)
    px_w = int(width * cell + 36 + 2)
    px_h = int(len(rows) * font_px * 1.46 + 32 + 2)
    print(f"{px_w} {px_h}")


if __name__ == "__main__":
    render(sys.argv[1], sys.argv[2], float(sys.argv[3]) if len(sys.argv) > 3 else 15.0)
