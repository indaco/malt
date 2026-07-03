#!/usr/bin/env bash
# Regression: `mt run` must forward the child's exit status and every
# forwarded argument to the shell.
#
# The bug: execBinary waited fire-and-forget (`_ = child.wait() catch {}`),
# so `mt run` always exited 0 regardless of what the run binary returned —
# breaking `mt run … && …` and any scripted conditional. It also assembled
# argv into a fixed [64]-slot stack buffer and clamped with `@min(len, 63)`,
# silently dropping the 64th and later forwarded arguments.
#
# Drives the installed fast path ({prefix}/bin/<name>) so this is offline,
# deterministic, and fast — that path routes through the same execBinary as
# the download path.
set -euo pipefail

malt="$(pwd)/zig-out/bin/malt" # plain `zig build` first — shell regs don't rebuild
[ -x "$malt" ] || {
  echo "SKIP: build malt first (zig build)"
  exit 1
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export MALT_PREFIX="$tmp/prefix"
export NO_COLOR=1
export MALT_NO_EMOJI=1
mkdir -p "$MALT_PREFIX/bin"

# (a) exit-code forwarding: a fake bin that exits 7 makes `mt run` exit 7.
printf '#!/bin/sh\nexit 7\n' >"$MALT_PREFIX/bin/faila"
chmod +x "$MALT_PREFIX/bin/faila"
set +e
"$malt" run faila
code=$?
set -e
[ "$code" -eq 7 ] || {
  echo "FAIL(a): expected exit 7, got $code"
  exit 1
}

# (c) argv not truncated at 63: forward all 100 args and count them.
printf '#!/bin/sh\necho $#\n' >"$MALT_PREFIX/bin/countargs"
chmod +x "$MALT_PREFIX/bin/countargs"
# shellcheck disable=SC2046
n="$("$malt" run countargs -- $(seq 1 100) | tail -1)"
[ "$n" -eq 100 ] || {
  echo "FAIL(c): expected 100 args, got $n"
  exit 1
}

echo "OK"
