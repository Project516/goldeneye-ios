#!/bin/sh
# Enumerate every pointer-width truncation site the compiler can see.
#
# The port's recurring bug class is the decomp's `(s32)ptr` / `(u32)ptr` idiom,
# a no-op on the N64 and a lost top half here. GCC already flags all of them as
# -Wpointer-to-int-cast / -Wint-to-pointer-cast, so this is a finite list to
# audit rather than a series of crashes to walk into one at a time (D197 walked
# into twelve).
#
# Triage rule:
#   - CONSTRUCTION, a cast to a pointer type wrapping the truncated value, is a
#     bug. Use PORT_PTRADD, N64_TO_HOST or N64_TO_HOST_OR_NULL from n64mem.h.
#   - COMPARISON, `(s32)a == (s32)b`, truncates both operands consistently and
#     is left as the decomp wrote it. Rewriting those is churn on byte-matched
#     code with no behavioural gain.
#
# Usage: tools_pc/truncscan.sh [ROMID]   (default ntsc-final)
set -e
ROMID="${1:-ntsc-final}"
ROOT=$(cd "$(dirname "$0")/.." && pwd)
BUILD=$(mktemp -d)
trap 'rm -rf "$BUILD"' EXIT

cmake -S "$ROOT" -B "$BUILD" -DROMID="$ROMID" >/dev/null
cmake --build "$BUILD" -j"$(nproc 2>/dev/null || echo 4)" >"$BUILD/build.log" 2>&1 || true

grep -B2 -E 'pointer-to-int-cast|int-to-pointer-cast' "$BUILD/build.log" \
  | grep -oE "^$ROOT/[^:]+\.c:[0-9]+" \
  | sed "s|^$ROOT/||" \
  | sort -u
