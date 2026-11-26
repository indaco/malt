#!/usr/bin/env bash
# Regression: the text relocation pass swapped path bytes inside
# length-prefixed files and left the declared lengths alone. PHP could
# not read pear.conf or the PEAR registry, so every pear and pecl command
# stopped. The same pass also rewrote upstream /usr/local text in bottles
# built elsewhere, so autoconf's frozen state failed to load. And
# configure_php never ran, so pecl left a new extension disabled.
#
# A Zig test guards each defect. This script checks that the three
# guards exist, builds the test binaries, and judges each guard's own
# result line.
#
# Exits 0 when the bugs are absent, non-zero (with a message naming the
# failing guard) when present. No network, no PHP.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)

# Keep the test runs off the developer's cache and live prefix.
unset MALT_CACHE
MALT_PREFIX=$(mktemp -d /tmp/mt_php_lengths.XXXXXX)
export MALT_PREFIX
trap 'rm -rf "$MALT_PREFIX"' EXIT

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

SER="patchTextFiles keeps PHP-serialized lengths correct across a prefix change"
UL="relocateKegTree leaves /usr/local text alone in a skip-relocation bottle"
PHP="configure_php repairs a corrupt pear.conf and records the persistent paths"

# A deleted guard leaves no line to judge, and the runs below would pass.
# So each guard must exist first.
grep -Fqs -- "$SER" "$ROOT/tests/patcher_test.zig" || fail "serialized length guard missing from patcher_test.zig"
grep -Fqs -- "$UL" "$ROOT/tests/cellar_test.zig" || fail "/usr/local text guard missing from cellar_test.zig"
grep -Fqs -- "$PHP" "$ROOT/src/core/post_install_steps.zig" || fail "configure_php guard missing from post_install_steps.zig"

# Debug build: the guards rely on its leak and double-free checks.
(cd "$ROOT" && env -u MALT_PREFIX zig build test-bin >/dev/null 2>&1) || fail "could not build the test binaries (zig build test-bin)"

# The runners have no per-test filter, so run each suite once and judge
# only the guard's line. A pass ends in "OK".
check() {
  local bin="$1" name="$2" out line
  out=$("$ROOT/zig-out/test-bin/$bin" 2>&1 || true)
  line=$(printf '%s\n' "$out" | grep -F -- ".test.$name..." || true)
  [[ -n "$line" ]] || fail "guard test did not run in $bin: $name"
  [[ "$line" == *OK ]] || fail "$name: $line"
}

check patcher_test "$SER"
check cellar_test "$UL"
# Inline tests in src/ run only inside lib_tests.
check lib_tests "$PHP"

echo "OK: relocated text keeps its recorded lengths"
