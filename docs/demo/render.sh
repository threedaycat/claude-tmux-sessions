#!/usr/bin/env bash
# ansi -> html -> png. Headless Chrome silently ignores --window-size when it
# reuses a lingering headless process, so kill any first and verify the result
# is the size we asked for, retrying once.
# usage: render.sh <in.ansi> <out.png> [font_px]
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IN="${1:?input .ansi}"
OUT="${2:?output .png}"
FONT="${3:-15}"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
HTML="${OUT%.png}.html"

read -r W H <<<"$(python3 "$DIR/ansi2html.py" "$IN" "$HTML" "$FONT")"

shoot() {
  pkill -f "Google Chrome --headless" 2>/dev/null || true
  sleep 1
  rm -f "$OUT"
  "$CHROME" --headless=old --disable-gpu --hide-scrollbars \
    --force-device-scale-factor=2 --window-size="$W,$H" \
    --screenshot="$OUT" "$HTML" >/dev/null 2>&1 || true
  sips -g pixelWidth "$OUT" 2>/dev/null | awk '/pixelWidth/{print $2}'
}

got="$(shoot)"
if [ "$got" != "$((W * 2))" ]; then
  echo "retry (got ${got}px, wanted $((W * 2))px)"
  got="$(shoot)"
fi
[ "$got" = "$((W * 2))" ] || { echo "FAILED: got ${got}px, wanted $((W * 2))px"; exit 1; }
echo "$OUT  ${W}x${H} css / $((W * 2))x$((H * 2)) px"
