#!/usr/bin/env bash
# Pin that a command which already printed its own error line ends there.
#
# restore, backup, services and purge printed a "✗ ..." line and then
# returned a command-local named error. main only treats `Aborted` as
# already-reported, so std's start code appended "error: <Name>" (and, in
# Debug builds, a return trace) after the message.
#
# Pinned behaviour, per failure path (argv-only, or a declined purge prompt):
#   1. exit status is 1
#   2. the command's own line is printed (an error line, or "aborted")
#   3. no "error: <Name>" line and no return-trace frame follows it
#
# Hermetic: throwaway prefix, no network.
#
# Usage: scripts/regressions/raw-error-after-message-commands-print-raw-error-after-their-own-message.sh

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

MALT_BIN=${MALT_BIN:-$ROOT/zig-out/bin/malt}
if [[ ! -x "$MALT_BIN" ]]; then
  printf 'FAIL: malt binary not found at %s - run "zig build" first.\n' "$MALT_BIN" >&2
  exit 1
fi

PFX=$(mktemp -d -t mt_raw_err.XXXXXX)
trap 'rm -rf "$PFX"' EXIT
export MALT_PREFIX="$PFX" MALT_CACHE="$PFX/cache" NO_COLOR=1 MALT_NO_EMOJI=1

fail=0
# check <expected-line-regex> <stdin> <argv...>
check() {
  local want=$1 input=$2 out rc
  shift 2
  set +e
  out=$(printf '%s' "$input" | "$MALT_BIN" "$@" 2>&1)
  rc=$?
  set -e
  if [[ $rc -ne 1 ]]; then
    printf 'FAIL mt %s: exit %s, want 1\n' "$*" "$rc" >&2
    fail=1
  fi
  if ! grep -qE "$want" <<<"$out"; then
    printf 'FAIL mt %s: missing its own line\n' "$*" >&2
    fail=1
  fi
  if grep -qE '^error: [A-Za-z]+$|\.zig:[0-9]+:[0-9]+: 0x' <<<"$out"; then
    printf 'FAIL mt %s: raw error name or trace after its message:\n' "$*" >&2
    printf '%s\n' "$out" | while IFS= read -r l; do printf '  %s\n' "$l" >&2; done
    fail=1
  fi
}

err='^  x '
check "$err" '' restore
check "$err" '' restore --nope
check "$err" '' restore /nonexistent-malt-regression
check "$err" '' backup --nope
check "$err" '' services start
check "$err" '' services bogus
check "$err" '' purge --nope
check "$err" '' bundle --nope
# A declined confirmation is the user's answer, not a fault.
check 'aborted' 'no
' purge --downloads
check 'aborted' 'no
' cleanup --downloads

if [[ $fail -ne 0 ]]; then
  exit 1
fi
printf 'OK: failing commands end on their own line\n'
