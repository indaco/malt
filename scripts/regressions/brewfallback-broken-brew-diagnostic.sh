#!/usr/bin/env bash
# Regression: brewFallback must diagnose a broken brew correctly. A brew binary
# that is present but not executable is a broken install, not a missing one —
# malt must say so and exit 126, never print "Install Homebrew" and exit as if
# the command was simply unknown. A genuinely absent brew exits 127. A working
# brew's exit code is forwarded verbatim. MALT_BREW_PATH points the fallback at
# a stub so all three cases run hermetically, no real brew required.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
MT="${MALT_BIN:-$ROOT/zig-out/bin/malt}"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0

# (a) working brew stub → exit code forwarded verbatim.
printf '#!/bin/sh\nexit 7\n' >"$tmp/ok"
chmod +x "$tmp/ok"
set +e
MALT_BREW_PATH="$tmp/ok" "$MT" cellar >/dev/null 2>&1
code=$?
set -e
if [ "$code" -ne 7 ]; then
  echo "FAIL(forward): expected forwarded exit 7, got $code" >&2
  fail=1
fi

# (b) present but not executable → broken install: exit 126, no install hint.
: >"$tmp/broken"
chmod 644 "$tmp/broken"
set +e
err=$(MALT_BREW_PATH="$tmp/broken" "$MT" cellar 2>&1 >/dev/null)
code=$?
set -e
if [ "$code" -ne 126 ]; then
  echo "FAIL(unrunnable-code): expected 126, got $code" >&2
  fail=1
fi
if ! grep -qi "could not execute" <<<"$err"; then
  echo "FAIL(unrunnable-msg): missing broken-install diagnostic" >&2
  fail=1
fi
if grep -qi "Install Homebrew" <<<"$err"; then
  echo "FAIL(unrunnable-msg): misreported a broken brew as not installed" >&2
  fail=1
fi

# (c) genuinely absent brew → exit 127.
set +e
MALT_BREW_PATH="$tmp/nope" "$MT" cellar >/dev/null 2>&1
code=$?
set -e
if [ "$code" -ne 127 ]; then
  echo "FAIL(notfound-code): expected 127, got $code" >&2
  fail=1
fi

[ "$fail" -eq 0 ] || exit 1
echo "PASS: broken brew → 126, absent brew → 127, working brew forwards its code"
