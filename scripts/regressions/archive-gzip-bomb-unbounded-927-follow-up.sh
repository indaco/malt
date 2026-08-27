#!/usr/bin/env bash
# Regression: a gzip stream may expand ~1000x, so a tap-controlled tar.gz of a
# few hundred kilobytes could write terabytes into the Cellar. Neither the
# extract path nor its pre-scan counted the bytes an archive declared, and SHA
# pinning is no defence on the two exposed paths (a tap formula supplies both
# the archive and its digest; a `:no_check` cask is never hashed at all).
#
# No CLI subcommand drives a raw archive extract in isolation, so the budget is
# exercised by colocated `test {}` fixtures that inject a tiny limit. This
# script judges those tests by name out of the inline-test binary, and fails
# loudly if one goes missing rather than passing on a filter that matched
# nothing.
#
# Exits 0 when the bug is absent, non-zero (with a clear message) when present.
# No network, no temp state of its own; the fixtures own their scratch dirs.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
ARCHIVE="$ROOT/src/fs/archive.zig"
BIN="$ROOT/zig-out/test-bin/lib_tests"

fail() {
  printf '  ✗ %s\n' "$*" >&2
  exit 1
}

TESTS=(
  "extractTarGz refuses an archive whose payload exceeds the byte budget"
  "extractTarGz extracts an archive that fits the byte budget"
  "extractTarGz refuses an archive whose entry count exceeds the budget"
  "extractTarGz counts hard links against the entry budget"
  "extractTarGz refuses an archive that inflates past the budget without declaring it"
  "extractTarGz applies the shipping decompression limits"
)

for t in "${TESTS[@]}"; do
  grep -Rqs -- "$t" "$ARCHIVE" || fail "guard test missing: $t"
done

# A budget inlined at one call site drifts out of the shipping default the
# moment someone tunes it; keep it a named constant the tests can read back.
grep -q 'max_decompressed_bytes' "$ARCHIVE" || fail "no byte budget constant"

# Always rebuild: a stale binary from before the guard was touched reports the
# old verdict, which is the one way this script could go green on a broken tree.
(cd "$ROOT" && zig build test-bin >/dev/null 2>&1) ||
  fail "could not build the test binary (zig build test-bin)"

# The runner has no per-test filter, so run the colocated suite and judge only
# these lines: a pass ends in "OK", a regression prints the failure there.
OUT=$("$BIN" 2>&1 || true)
for t in "${TESTS[@]}"; do
  line=$(printf '%s\n' "$OUT" | grep -F -- "$t" || true)
  [[ -n "$line" ]] || fail "guard did not run: $t"
  [[ "$line" == *OK ]] || fail "an archive may still expand without bound: $t"
done

printf '  ✓ archive expansion is bounded\n'
