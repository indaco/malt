#!/usr/bin/env bash
# Regression: a cask `command_wrapper` that malt cannot run is skipped in core.
# Pre-fix the CLI never learned of the skip, so install, reinstall and upgrade
# reported success with no `<prefix>/bin/<name>` and no message.
#
# Static guard plus unit run: the three cask finish sites have no unit seam,
# so each must call the warning helper. The full `zig build test` runs because
# inline tests live only in lib_tests; a per-file binary could never fail.
#
# Usage: scripts/regressions/cask-wrapper-skip-warning-skipped-command-wrappers-install-silently.sh
# Requirements: zig, rg, awk. No network access required. Creates no temp state.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

for f in src/cli/install.zig src/cli/install/local.zig src/cli/upgrade.zig; do
  # The call must follow the success line, so an early return cannot skip it.
  rg -Uq 'success\(.*\n\s*(install_mod\.)?warnSkippedWrappers\(allocator, ' "$f" || fail "$f: skipped command wrappers are not reported"
done

rg -q 'pub fn skippedCommandWrappers' src/core/cask.zig || fail "core helper missing"
# Core must stay silent: only the CLI layer prints.
body=$(awk '/pub fn skippedCommandWrappers/{p=1} p{print} p&&/^}/{exit}' src/core/cask.zig)
if rg -q 'print|output\.' <<<"$body"; then fail "core helper prints"; fi
rg -q 'test "skippedCommandWrappers' src/core/cask.zig || fail "core test missing"
rg -q 'test "warnSkippedWrappers' src/cli/install.zig || fail "warning text test missing"

# `just test` runs the inline tests itself; static-only mode keeps this guard cheap.
if [[ -n "${MALT_STATIC_ONLY:-}" ]]; then
  echo "OK: skipped command wrappers are reported (static-only)"
  exit 0
fi

env -u MALT_PREFIX zig build test || fail "unit tests red"
echo "OK: skipped command wrappers are reported"
