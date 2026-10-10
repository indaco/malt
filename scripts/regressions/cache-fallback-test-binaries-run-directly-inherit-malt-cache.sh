#!/usr/bin/env bash
# Regression: a test binary run directly, without the build.zig or runner
# scrubs, must not use an inherited MALT_CACHE outside /tmp. Test builds then
# fall back to {prefix}/cache, so the developer's real cache stays untouched.
#
# The atomic_test assertion is the guard. The sentinel check also catches a
# test that changes the cache before a test resets MALT_CACHE.
#
# Builds test-bin (Debug), runs two test binaries. No network.
#
# Exits 0 when the bug is absent, non-zero (with a clear message) when present.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
fail() {
  echo "FAIL: $*" >&2
  exit 1
}

grep -q 'test builds ignore a MALT_CACHE outside /tmp' "$ROOT/tests/atomic_test.zig" ||
  fail "guard test missing from tests/atomic_test.zig"

(cd "$ROOT" && env -u MALT_PREFIX -u MALT_CACHE zig build test-bin >/dev/null) ||
  fail "zig build test-bin failed"

# The sentinel must sit outside /tmp: test builds still honour a /tmp cache.
# Arm the trap first so a failed mktemp cannot leave the sentinel in $HOME.
SENT="" PREFIX=""
trap 'rm -rf ${SENT:+"$SENT"} ${PREFIX:+"$PREFIX"}' EXIT
SENT=$(mktemp -d "$HOME/.mt_cache_guard.XXXXXX")
PREFIX=$(mktemp -d /tmp/mt_cache_guard.XXXXXX)
case "$SENT" in /tmp/*) fail "HOME is under /tmp; the sentinel would be honoured" ;; esac
mkdir -p "$SENT/downloads" "$SENT/api"
echo keep >"$SENT/downloads/marker"
echo keep >"$SENT/api/marker"
before=$(command ls -lR "$SENT")

for b in atomic_test purge_scopes_test; do
  bin="$ROOT/zig-out/test-bin/$b"
  [ -x "$bin" ] || fail "missing test binary $bin"
  MALT_PREFIX="$PREFIX" MALT_CACHE="$SENT" "$bin" >/dev/null 2>&1 ||
    fail "$b failed with inherited MALT_CACHE=$SENT"
  [ "$(command ls -lR "$SENT" 2>/dev/null)" = "$before" ] ||
    fail "$b changed the inherited cache $SENT"
done

echo "OK: test binaries left the inherited cache untouched"
