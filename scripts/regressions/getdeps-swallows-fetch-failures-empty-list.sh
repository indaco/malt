#!/usr/bin/env bash
# Regression: deps.resolve must fail loudly when a dependency's own formula
# JSON can't be fetched. getDeps ran `api.fetchFormula(name) catch return &.{}`,
# so a transient ApiUnreachable (or a 404/OOM) on a dep was indistinguishable
# from "this formula declares zero dependencies". resolve folded that empty
# result in and the install proceeded with a truncated graph: the keg reports
# success but is unloadable at runtime (`dyld: Library not loaded`) because the
# missing transitive deps were never queued.
#
# The fix propagates the fetch failure out of getDeps and maps it to
# error.ResolutionFailed in resolve, which the install caller already routes
# into "Failed to resolve <pkg>". No CLI subcommand drives resolve against an
# unreachable API without real network, so the guard is a colocated `test {}`
# that points BrewApi at a refused loopback port (no egress) and asserts the
# empty cache forces getDeps → fetchFormula → ApiUnreachable to surface as
# error.ResolutionFailed rather than a zero-length success slice. This script
# builds the test binary and judges that test by name; it exits non-zero if the
# guard regresses or the test goes missing.
#
# Exits 0 when the bug is absent, non-zero (with a clear message) when present.
# No network required (loopback-only); finishes in about a minute once built.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
FILTER="resolve surfaces a dependency-fetch failure as ResolutionFailed, not an empty graph"

# The guard lives in a colocated `test {}`; if it is ever deleted the name
# filter below would match nothing and silently pass. Fail loudly instead.
if ! grep -Rqs -- "$FILTER" "$ROOT/src/core/deps.zig"; then
  echo "FAIL: the resolve fail-loud guard test is missing from deps.zig" >&2
  exit 1
fi

BIN="$ROOT/zig-out/test-bin/lib_tests"
if [[ ! -x "$BIN" ]]; then
  (cd "$ROOT" && zig build test-bin -Doptimize=ReleaseSafe >/dev/null 2>&1) || {
    echo "FAIL: could not build the test binary (zig build test-bin)" >&2
    exit 1
  }
fi

# The runner has no per-test filter, so run the colocated suite and judge only
# this guard's line: a pass ends in "OK", a regression prints the failure there.
OUT=$("$BIN" 2>&1 || true)
LINE=$(printf '%s\n' "$OUT" | grep -F -- "$FILTER" || true)
if [[ -z "$LINE" ]]; then
  echo "FAIL: the resolve fail-loud guard test did not run" >&2
  exit 1
fi
if [[ "$LINE" != *OK ]]; then
  echo "FAIL: a dependency-fetch failure was swallowed into an empty graph" >&2
  exit 1
fi

echo "PASS: resolve surfaces a dependency-fetch failure instead of a truncated graph"
