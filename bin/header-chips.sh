# header-chips.sh — sourced by claude-tmux-picker.sh and skip-header.sh.
#
# chips "<key> <label> · <key> <label> · …"
#
# Turns the key-hint header into something that looks clickable. Items whose
# key bin/mouse.sh knows how to press become grey chips; the rest (j/k,
# 数字直跳, 输入过滤 …) stay as dim plain text, so the eye can tell a button
# from a hint. Inside a chip the spaces are NBSPs: fzf reports the clicked
# word by splitting on plain spaces, so a chip comes back as one word
# wherever in it you click — including the gap between key and label.
#
# The header strings themselves stay plain text everywhere they're defined;
# only this function knows about styling, at the moment they're shown.
# No parentheses are emitted: fzf parses change-header(…) up to the first `)`.

chips() {
  local rest="$1" item key out="" plain="" nb=$' '
  local on=$'\e[48;5;238;38;5;252m' dim=$'\e[38;5;244m' off=$'\e[0m'
  while [ -n "$rest" ]; do
    if [[ "$rest" == *" · "* ]]; then
      item="${rest%% · *}"; rest="${rest#* · }"
    else
      item="$rest"; rest=""
    fi
    key="${item%% *}"
    case "$key" in
      ✕|o|t|a|f|p|h|l|/|Enter|ctrl-x|q|q/esc|Esc)
        out+="${on}${nb}${item// /$nb}${nb}${off} "
        plain+="${nb}${item// /$nb}${nb} " ;;
      *)
        out+="${dim}${item}${off} "
        plain+="${item} " ;;
    esac
  done
  # What is on screen, as plain text, for bin/mouse.sh to look the clicked
  # column up in: fzf's own FZF_CLICK_HEADER_WORD is unreliable here (the
  # whole line under the picker's tab --delimiter, and empty once the line
  # holds NBSPs), while FZF_CLICK_HEADER_COLUMN is exact.
  [ -n "${HEADER_FILE:-}" ] && printf '%s' "${plain% }" > "$HEADER_FILE"
  printf '%s' "${out% }"
}
