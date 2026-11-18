#!/usr/bin/env bash
# Regression: a cask with nothing malt can place (for example only a
# `command_wrapper` with inline content) failed with a bare `InstallFailed`.
# The user saw neither the cause nor the skipped wrapper.
#
# Static guard plus unit run: the two CLI failure sites have no unit seam, so
# each must go through the shared reporter. The full `zig build test` runs
# because inline tests live only in lib_tests.
#
# Usage: scripts/regressions/cask-wrapper-only-fails-with-reason-wrapper-only-cask-install-fails-opaquely.sh
# Requirements: zig, grep, awk. No network access required. Creates no temp state.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

grep -q 'NothingToPlace' src/core/cask.zig || fail "core error missing"
# The zip and tarball fall-throughs must not collapse to the generic error.
n=$(awk '/findAppInDir\(self.io, (extract_dir|caskroom_ver),/{getline; if ($0 ~ /NothingToPlace/) c++} END{print c+0}' src/core/cask.zig)
[[ "$n" -eq 2 ]] || fail "placeExtracted/installTarball do not return NothingToPlace ($n of 2)"

for f in src/cli/install.zig src/cli/install/local.zig; do
  grep -q 'reportCaskInstallFailure(allocator, &cask, e, sink)' "$f" ||
    fail "$f: install failure bypasses the reporter"
done
grep -q 'test "reportCaskInstallFailure' src/cli/install.zig || fail "reporter test missing"
grep -q 'nothing to place' tests/cask_binary_zip_test.zig || fail "core test missing"

# `just test` runs the inline tests itself; static-only mode keeps this guard cheap.
if [[ -n "${MALT_STATIC_ONLY:-}" ]]; then
  echo "OK: an empty cask install says why (static-only)"
  exit 0
fi

env -u MALT_PREFIX zig build test || fail "unit tests red"
echo "OK: an empty cask install says why"
