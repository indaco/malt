#!/usr/bin/env bash
# Regression: when the strip of a keg marker cannot delete a read-only
# directory of the marker's name, it moves the directory aside. The aside name
# was built from the pid and a counter that starts at 0, so an archive could
# pre-ship a file at every possible aside name. The move then failed, the
# shipped directory kept the marker's name, and malt's own marker write failed
# on top of it. Doctor then reported a wrong verdict for the keg.
#
# The strip is internal, so a colocated `test {}` drives it. This script
# judges that test by name out of the inline-test binary, and fails if the
# test is missing rather than passing on a filter that matched nothing.
#
# Exits 0 when the bug is absent, non-zero (with a clear message) when present.
# No network, no temp state of its own; the fixture owns its scratch dir.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
CELLAR="$ROOT/src/core/cellar.zig"
BIN="$ROOT/zig-out/test-bin/lib_tests"
TEST="stripKegMarkers frees the marker name when the archive pre-ships the aside names"

fail() {
  printf '  ✗ %s\n' "$*" >&2
  exit 1
}

# Static check first, so a return to the guessable name fails in under a second.
body=$(awk '/^pub fn stripKegMarkers\(/{f=1} f{print} f&&/^}/{exit}' "$CELLAR")
[[ -n "$body" ]] || fail "stripKegMarkers not found in $CELLAR"
if printf '%s' "$body" | grep -q 'getpid'; then
  fail "stripKegMarkers builds the aside name from the pid; an archive can pre-ship it"
fi
printf '%s' "$body" | grep -q 'io.random' ||
  fail "stripKegMarkers aside name is not random"
grep -qF -- "$TEST" "$CELLAR" || fail "guard test missing: $TEST"

# An inherited MALT_* would point the inline tests at a real prefix or cache.
while IFS='=' read -r v _; do unset "$v"; done < <(env | grep '^MALT_' || true)

# Always rebuild: a stale binary reports the old verdict.
(cd "$ROOT" && zig build test-bin >/dev/null 2>&1) ||
  fail "could not build the test binary (zig build test-bin)"

# The runner has no per-test filter, so run the suite and judge only this test.
OUT=$("$BIN" </dev/null 2>&1 || true)
# A log line can split the runner line, so judge the whole block up to the
# next progress line. A here-string, not a pipe: awk exits early.
block=$(awk -v t="test.$TEST..." '
  /^[0-9]+\/[0-9]+ /{ if (on) exit; on = index($0, t) > 0 }
  on { print }' <<<"$OUT")
[[ -n "$block" ]] || fail "guard did not run: $TEST"
# A skip (root, or no chmod) proves nothing; say so instead of blaming the fix.
grep -qx 'SKIP\|.*\.\.\.SKIP' <<<"$block" &&
  fail "guard skipped, run it as a non-root user: $TEST"
grep -qx 'OK\|.*\.\.\.OK' <<<"$block" ||
  fail "an archive can still block the keg marker strip: $block"
grep -q 'leaked' <<<"$block" && fail "guard leaked memory: $block"

printf '  ✓ an archive cannot block the keg marker strip\n'
