#!/usr/bin/env bash
# Regression: uninstalling a cask whose app is still running used
# to abort with the opaque `UninstallFailed`. The cask installer now refuses
# with a distinct `AppRunning` error, the CLI prints "the app is running. Quit
# it and try again." and exits with a dedicated code, and the TUI maps that code
# to a named footer instead of "ChildFailed".
#
# The detection needs a live process whose command line carries the bundle path
# (so `pgrep -f` matches), which no plain CLI invocation sets up in isolation.
# The guard is therefore a colocated integration test that stages a live process
# and asserts `uninstall` returns `AppRunning`. This script builds the test
# binary and judges that test by name; it exits non-zero if the guard regresses
# or the test goes missing.
#
# Exits 0 when the bug is absent, non-zero (with a clear message) when present.
# No network required; finishes well under 30s once built.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
FILTER="CaskInstaller.uninstall refuses with AppRunning while the app bundle is live"

# The guard lives in a test file; if it is ever deleted the name filter below
# would match nothing and silently pass. Fail loudly instead.
if ! grep -Rqs -- "$FILTER" "$ROOT/tests/cask_extra_test.zig"; then
  echo "FAIL: the cask app-running guard test is missing from cask_extra_test.zig" >&2
  exit 1
fi

BIN="$ROOT/zig-out/test-bin/cask_extra_test"
if [[ ! -x "$BIN" ]]; then
  (cd "$ROOT" && zig build test-bin -Doptimize=safe >/dev/null 2>&1) || {
    echo "FAIL: could not build the test binary (zig build test-bin)" >&2
    exit 1
  }
fi

# The runner has no per-test filter, so run the suite and judge only this guard's
# line: a pass ends in "OK", a regression prints the failure there.
OUT=$("$BIN" 2>&1 || true)
LINE=$(printf '%s\n' "$OUT" | grep -F -- "$FILTER" || true)
if [[ -z "$LINE" ]]; then
  echo "FAIL: the cask app-running guard test did not run" >&2
  exit 1
fi
if [[ "$LINE" != *OK ]]; then
  echo "FAIL: uninstall no longer reports AppRunning while the app is live" >&2
  exit 1
fi

echo "PASS: a live cask app is refused with a distinct AppRunning error"

# Upgrades replace the bundle while its process keeps running, on both routes.
FILTERS=(
  "upgrade replaces a running app and runs its stored steps"
  "a tap-routed upgrade replaces a running app and runs its stored steps"
)
for filter in "${FILTERS[@]}"; do
  grep -Fqs -- "$filter" "$ROOT/tests/cask_flight_steps_test.zig" || {
    echo "FAIL: missing running-app upgrade test: $filter" >&2
    exit 1
  }
done
BIN="$ROOT/zig-out/test-bin/cask_flight_steps_test"
if [[ ! -x "$BIN" ]]; then
  (cd "$ROOT" && zig build test-bin -Doptimize=safe >/dev/null 2>&1) || exit 1
fi
OUT=$("$BIN" 2>&1 || true)
for filter in "${FILTERS[@]}"; do
  LINE=$(printf '%s\n' "$OUT" | grep -F -- "$filter" || true)
  if [[ "$LINE" != *OK ]]; then
    echo "FAIL: running-app upgrade test did not pass: $filter" >&2
    exit 1
  fi
done
echo "PASS: core and tap casks upgrade while their app keeps running"
