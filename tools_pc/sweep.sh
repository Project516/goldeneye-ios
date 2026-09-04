#!/bin/sh
# Run the solo-level sweep and refuse to report anything the binary changed
# under.
#
# This exists because of a specific way the sweep lies. A rebuild while the
# sweep is running replaces the binary, and every level after that point
# reports zero frames with no crash, which is indistinguishable from a hang.
# The result is confident wrong entries in docs/dev/LEVEL-STATUS.md. Comparing
# the binary's hash before each level turns that into an abort.
#
# Usage: tools_pc/sweep.sh
#   SECS=30 tools_pc/sweep.sh          # longer per level
#   LEVELS="09 40" tools_pc/sweep.sh   # just these
set -e
SECS="${SECS:-22}"
# No 40. Citadel is the unfinished multiplayer-only arena and has no language
# bank, so langGetLangBankIndexFromStagenum takes the decomp's deliberate
# while(1){} for an unknown text bank. It hangs on hardware too. D198.
LEVELS="${LEVELS:-09 20 22 23 24 25 26 27 28 29 30 32 33 34 35 36 37 39 41 43 54}"

ROOT=$(cd "$(dirname "$0")/.." && pwd)
BIN=$(ls "$ROOT"/build-pc/ge007.* 2>/dev/null | grep -v '\.log$' | head -1)
[ -n "$BIN" ] || { echo "no binary in $ROOT/build-pc" >&2; exit 1; }
STAMP=$(sha1sum "$BIN" | cut -d' ' -f1)
echo "binary $BIN"
echo "sha1   $STAMP"

for n in $LEVELS; do
  NOW=$(sha1sum "$BIN" | cut -d' ' -f1)
  if [ "$NOW" != "$STAMP" ]; then
    echo "ABORT: $BIN changed mid-sweep ($STAMP -> $NOW)." >&2
    echo "Every result from here on would be absence of data, not a" >&2
    echo "failure. Discard this run and sweep again on an idle tree." >&2
    exit 1
  fi
  sh "$ROOT/tools_pc/run-headless.sh" "$SECS" "-level_$n"
done

echo "sweep complete; binary unchanged throughout ($STAMP)"
