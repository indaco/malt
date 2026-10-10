#!/usr/bin/env bash
# Regression: test runs must not inherit the developer's MALT_CACHE, and
# regression guards must find their binary and repo root from any cwd.
#
# Static checks plus one cwd check. No build, no network.
#
# Exits 0 when the bug is absent, non-zero (with a clear message) when present.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# 1. Each test Run step that sets MALT_PREFIX also drops MALT_CACHE.
# Comment lines do not count: a commented-out call must not satisfy the guard.
code=$(grep -v '^[[:space:]]*//' "$ROOT/build.zig")
n_prefix=$(grep -c 'setEnvironmentVariable("MALT_PREFIX"' <<<"$code" || true)
n_cache=$(grep -c 'removeEnvironmentVariable("MALT_CACHE")' <<<"$code" || true)
[ "$n_prefix" -gt 0 ] || fail "build.zig: no MALT_PREFIX test runs found"
[ "$n_prefix" -eq "$n_cache" ] ||
  fail "build.zig: $n_prefix test runs set MALT_PREFIX, $n_cache drop MALT_CACHE"

# 2. No regression script resolves its binary relative to cwd.
hits=$(grep -rnE '[$][{][A-Za-z_]+:-[.]/zig-out/bin|[$][(]pwd[)]/zig-out|[$]PWD/zig-out|git rev-parse --show-top[l]evel' "$ROOT/scripts/regressions" || true)
[ -z "$hits" ] || fail "cwd-relative binary default: $hits"

# 3. Runners, and every script that drives purge, cleanup or uninstall or seeds
# the Cask/Tap cache, drop MALT_CACHE. Those paths delete or plant files under
# the cache root, so an inherited one would be damaged. Comment lines do not count.
# shortcut: detection is per line, so a continued command is missed, and a '#'
# inside a string cuts its line short; upgrade when a script needs either.
code_of() { grep -v '^[[:space:]]*#' "$1" | sed -E 's/[[:space:]]#.*$//'; }
scrubs() {
  local code
  code=$(code_of "$1")
  grep -qE '^unset MALT_CACHE[[:space:]]*$|env -u MALT_CACHE' <<<"$code" && return 0
  # shortcut: a per-command `MALT_CACHE=x cmd` counts for the whole script.
  # An echo line or a value that reads the inherited one does not count.
  grep -E '(^|[[:space:];])(export[[:space:]]+)?MALT_CACHE=' <<<"$code" |
    grep -vE '^[[:space:]]*(echo|printf)|[$][{]?MALT_CACHE' | grep -q .
}
touches_cache() {
  code_of "$1" | grep -qE '("?[$][{]?[A-Za-z_]+[}]?"?|mt|malt)([[:space:]]+-[A-Za-z-]+(=[^[:space:]]*)?)*[[:space:]]+(purge|cleanup|uninstall)([[:space:]]|$)|cache/(Cask|Tap)'
}
cd "$ROOT"
for f in scripts/coverage.sh scripts/test-concurrent.sh scripts/run-regressions.sh \
  scripts/regressions/{appdir-env-shape,cellar-scan-error-cap,migrate-honours-brew,outdated_test_concurrent,vulns-scans-tap-kegs}*.sh; do
  [ -r "$f" ] || fail "$f unreadable"
  scrubs "$f" || fail "$f keeps an inherited MALT_CACHE"
done
for f in scripts/regressions/*.sh scripts/smokes/*.sh; do
  [ -r "$f" ] || fail "$f unreadable"
  [ "$f" != "scripts/regressions/${0##*/}" ] || continue
  touches_cache "$f" || continue
  scrubs "$f" || fail "$f touches the cache on an inherited MALT_CACHE"
done

# 4. Scripts that run test binaries also pin the prefix: an inherited
# MALT_PREFIX would otherwise decide where the cache resolves.
for f in scripts/coverage.sh scripts/test-concurrent.sh; do
  grep -v '^[[:space:]]*#' "$f" | grep -qx 'export MALT_PREFIX=/tmp/malt-test-prefix' ||
    fail "$f does not pin MALT_PREFIX"
done
for f in scripts/regressions/{appdir-env-shape,cellar-scan-error-cap,outdated_test_concurrent,vulns-scans-tap-kegs}*.sh; do
  grep -v '^[[:space:]]*#' "$f" | grep -q 'env -u MALT_CACHE MALT_PREFIX=/tmp/malt-test-prefix' ||
    fail "$f does not pin MALT_PREFIX"
done

# 5. The reinstall guard names a missing binary instead of failing in sqlite3.
G=$ROOT/scripts/regressions/reinstall-refuses-uninstalled-extra-names-reinstall-cask-routing-keyed-off-first-positional.sh
rc=0
out=$(cd /tmp && MALT_BIN=/nonexistent/mt bash "$G" </dev/null 2>&1) || rc=$?
[ "$rc" -ne 0 ] || fail "guard passed with no binary"
grep -q 'malt binary not found at' <<<"$out" || fail "guard error does not name the binary: $out"
echo PASS
