#!/usr/bin/env bash
# Regression: a termination signal delivered to `mt tui` must not wedge the
# user's shell. The dashboard enters raw mode + the alternate screen, but its
# restore ran only on error-return and normal-exit paths; SIGTERM/SIGHUP/
# SIGQUIT kept their default disposition (immediate death), leaving the pty
# with echo off, byte-at-a-time input, and the alt buffer active — the user
# had to blind-type `reset`.
#
# Drives the built binary on a real pty via BSD script(1), kills it with
# SIGTERM, then asserts the pty came back in cooked mode (echo restored) and
# the alt-screen leave sequence was emitted before death.
#
# Exits 0 when the bug is absent, non-zero with a message when present.
# No network (a throwaway MALT_PREFIX keeps the launch audits local); cleans
# up its temp state; finishes well under 30s once built.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BIN="${MALT_BIN:-$ROOT/zig-out/bin/malt}"
[[ -x "$BIN" ]] || {
  echo "build malt first: zig build" >&2
  exit 2
}

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

OUT=$(mktemp -t mt_tui_sigterm.XXXXXX)
PREFIX=$(mktemp -d -t mt_tui_sigterm_prefix.XXXXXX)
trap 'rm -rf "$OUT" "$PREFIX"' EXIT

# script(1) gives the child a fresh pty and records everything written to it.
# The TUI refuses under CI/NO_COLOR, so both are scrubbed inside; the
# throwaway prefix keeps the launch audits off the real store and the network.
# The KILL fallback only bounds a hang — a killed TUI never restored, so the
# assertions below still fail.
# shellcheck disable=SC2016 # the inner sh expands these, not this shell
MALT_TUI_BIN="$BIN" MALT_PREFIX="$PREFIX" \
  script -q "$OUT" sh -c '
    # `&` defaults stdin to /dev/null; the TUI reads and draws through fd 0,
    # so hand it the pty read-write.
    env -u CI -u NO_COLOR "$MALT_TUI_BIN" tui 0<>/dev/tty &
    pid=$!
    sleep 2
    kill -TERM "$pid" 2>/dev/null
    i=0
    while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 50 ]; do
      sleep 0.1
      i=$((i + 1))
    done
    kill -KILL "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    echo "WAITSTATUS:$?"
    stty -a
  ' </dev/null >/dev/null || true

# Cooked mode restored: stty must not report echo disabled. Right-anchored so
# `-echonl`/`-echoprt` (off even in cooked mode) do not false-positive.
if grep -aqE '(^|[[:space:]])-echo([[:space:]]|$)' "$OUT"; then
  fail 'pty left in raw mode (-echo) after SIGTERM'
fi

# The alt-screen leave sequence must have been emitted before death.
grep -aqF $'\x1b[?1049l' "$OUT" ||
  fail 'alt-screen leave sequence never emitted after SIGTERM'

# Death must still be BY SIGTERM (128+15): a handler whose re-raise is not
# fatal loops until the KILL fallback (137) or exits cleanly — both wrong.
grep -aq 'WAITSTATUS:143' "$OUT" ||
  fail 'tui did not die by SIGTERM after restoring'

printf 'PASS: SIGTERM restored the pty to cooked mode and left the alt-screen\n'
