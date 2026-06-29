#!/usr/bin/env bash
# Regression: the TUI is the sole DB orchestrator. It runs each tab's audit as a
# background `mt … --json` child and multiplexes it with live input. When the
# user triggers an inline mutation (upgrade/uninstall/service action/doctor
# --fix/install) while an audit is still in flight, two `mt` processes open the
# WAL DB at once. Every open writes (`schema.initSchema` seeds the version row),
# so the mutator's `BEGIN IMMEDIATE` races the audit's writer and SQLite returns
# `Busy` immediately — surfacing as RefCountError / "database is locked" and a
# `ChildFailed` upgrade footer.
#
# The fix drains every in-flight audit before dispatching a mutating child, so
# the audit closes its DB connection first. No CLI subcommand drives the TUI's
# input-multiplex-then-mutate path in isolation (driving the real TUI from a
# script is impractical), so the guard is a colocated `test {}` in app.zig that
# asserts `service` quiesces an active fetch before a mutating dispatch. This
# script builds the test binary and judges that test by name; it exits non-zero
# if the guard regresses or the test goes missing.
#
# Exits 0 when the bug is absent, non-zero (with a clear message) when present.
# No network required; finishes well under 30s once built.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
FILTER="service quiesces an in-flight audit before a mutating dispatch"

# The guard lives in a colocated `test {}`; if it is ever deleted the name filter
# below would match nothing and silently pass. Fail loudly instead.
if ! grep -Rqs -- "$FILTER" "$ROOT/src/tui/app.zig"; then
  echo "FAIL: the pre-mutation drain guard test is missing from app.zig" >&2
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
  echo "FAIL: the pre-mutation drain guard test did not run" >&2
  exit 1
fi
if [[ "$LINE" != *OK ]]; then
  echo "FAIL: a mutating dispatch left a background audit live — the DB writer races" >&2
  exit 1
fi

echo "PASS: the TUI drains in-flight audits before a mutating dispatch"
