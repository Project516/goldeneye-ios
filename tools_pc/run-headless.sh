#!/bin/sh
# Run the port on an offscreen X display and print the verification numbers.
#
# Always use this for automated runs. On the real display the game window
# grabs focus every time, which makes a sweep unusable for whoever is at the
# keyboard. Xvfb gives Mesa software GL, which is slower but renders the same
# frames.
#
# Usage: tools_pc/run-headless.sh [seconds] [game args...]
#   tools_pc/run-headless.sh 40
#   tools_pc/run-headless.sh 25 -level_09
set -e
SECS="${1:-40}"
shift 2>/dev/null || true
ROOT=$(cd "$(dirname "$0")/.." && pwd)
BIN=$(ls "$ROOT"/build-pc/ge007.* 2>/dev/null | grep -v '\.log$' | head -1)
[ -n "$BIN" ] || { echo "no binary in $ROOT/build-pc" >&2; exit 1; }

LOG=$(mktemp)
trap 'rm -f "$LOG"' EXIT
cd "$ROOT"
# WAYLAND_DISPLAY must go. SDL2 prefers its Wayland backend when that variable
# is set, and xvfb-run only sets DISPLAY, so the game connected to the real
# compositor and opened a real window despite running "headless".
timeout "$SECS" env -u WAYLAND_DISPLAY SDL_VIDEODRIVER=x11 \
  xvfb-run -a -s "-screen 0 1280x960x24" "$BIN" "$@" >"$LOG" 2>&1 || true

# Frames rendered is the only honest signal: the D51 vi post counter is
# timer-driven and keeps counting through a hang. A crash logged after the
# quit line is teardown racing the texture cache, not a gameplay failure.
# Prefer the quit line's total. If the timeout killed the process before the
# quit path ran, fall back to the highest "frame N rendered" note, which is
# logged for the first few frames and then every 300.
FRAMES=$(grep -oE 'quit requested after [0-9]+' "$LOG" | grep -oE '[0-9]+$' | tail -1)
if [ -z "$FRAMES" ]; then
  FRAMES=$(grep -oE '^\[NOTE \] frame [0-9]+ rendered' "$LOG" \
    | grep -oE '[0-9]+' | sort -n | tail -1)
  [ -n "$FRAMES" ] && FRAMES="${FRAMES}+"
fi
CRASH=$(awk '/quit requested/{q=1} /FATAL: Crashed/{if(!q)c++} END{print c+0}' "$LOG")
HB=$(grep -c 'kernel heartbeat' "$LOG" || true)
printf 'args=%-12s frames=%-6s crash=%s heartbeat=%s\n' "${*:-none}" "${FRAMES:-0}" "$CRASH" "$HB"

if [ "$CRASH" != "0" ]; then
  echo "--- first crash ---"
  sed -n '/BACKTRACE/,/^$/p' "$LOG" | head -8 | grep -oE '\[0x[0-9a-f]+\]' \
    | tr -d '[]' | xargs -r addr2line -e "$BIN" -f -C | head -12
fi
