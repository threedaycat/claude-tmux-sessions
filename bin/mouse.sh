#!/usr/bin/env bash
# mouse.sh — what a mouse click in the picker means. Prints fzf actions.
#
#   mouse.sh row <n> <field4>    single click on a list row
#   mouse.sh header <n>          click on the key-hint header
#                                (the clicked word is in $FZF_CLICK_HEADER_WORD)
#
# Every answer is the *same* action the matching key already runs — this file
# only decides which key a click stands for, so a click and a keypress can
# never drift apart in behaviour.
#
# Row: fzf has already moved the cursor onto the clicked row before the
# left-click binding runs (terminal.go: vset(cy), then the LeftClick
# actions), so "click = Enter" is just Enter on {n}. One exception: the
# "⋯ 收起 N 个 · a 展开" row (field 4 is "-") means "show me the rest", which
# is `a`, not a jump.
#
# Header: clickable hints are drawn as chips (bin/header-chips.sh); a click
# anywhere on a chip presses its key. Plain hints (j/k, 数字直跳) do nothing.

BIN_DIR="$(cd "$(dirname "$(readlink "$0" || echo "$0")")" && pwd)"
SH="$BIN_DIR/skip-header.sh"

case "${1:-}" in
  row)
    if [ "${3:-}" = "-" ]; then
      exec "$SH" "$2" showall a
    fi
    exec "$SH" "$2" enter
    ;;
  header)
    n="$2"
    # The header text on screen is in $HEADER_FILE (written by chips(), see
    # header-chips.sh) — fzf's FZF_CLICK_HEADER_WORD can't be trusted for it.
    # Find the token under FZF_CLICK_HEADER_COLUMN, counting CJK characters
    # as the two columns they occupy.
    word=$(python3 -c '
import os, unicodedata
try:
    line = open(os.environ["HEADER_FILE"]).read()
except Exception:
    line = os.environ.get("FZF_CLICK_HEADER_WORD", "")
col = int(os.environ.get("FZF_CLICK_HEADER_COLUMN") or 0)
x = 0
for tok in line.split(" "):
    w = sum(2 if unicodedata.east_asian_width(c) in "WF" else 1 for c in tok)
    if tok and x < col <= x + w:
        # A chip (bin/header-chips.sh) is one token held together by NBSPs;
        # its first word is the key, which is what the case below matches.
        words = tok.replace("\u00a0", " ").split()
        print(words[0] if words else ""); break
    x += w + 1
' 2>/dev/null)
    case "$word" in
      ✕|关闭)            echo abort ;;
      o|总览)            echo "transform($SH \"$n\" overview o)+execute($BIN_DIR/overview-page.sh)+transform($SH \"$n\" jumped)" ;;
      t|token)           echo "transform($SH \"$n\" tokens t)+execute($BIN_DIR/token-page.sh 1)+transform($SH \"$n\" jumped)" ;;
      a|全部)            exec "$SH" "$n" showall a ;;
      f|编队)            exec "$SH" "$n" teamonly f ;;
      p|预览)            exec "$SH" "$n" preview p ;;
      h|session)         exec "$SH" "$n" left h ;;
      l|切回选窗口|展开队员) exec "$SH" "$n" right l ;;
      /|搜索)            exec "$SH" "$n" slash / ;;
      Enter|跳转|跳到该)  exec "$SH" "$n" enter ;;
      ctrl-x|归档)       exec "$SH" "$n" archive ;;
      q|q/esc|退出)      exec "$SH" "$n" quit q ;;
      Esc)               exec "$SH" "$n" esc ;;
    esac
    ;;
esac
