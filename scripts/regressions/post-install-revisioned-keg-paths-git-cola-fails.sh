#!/usr/bin/env bash
# Regression: the DSL's ExecContext built `cellar_path` — and every
# keg-relative binding (prefix, bin, pkgshare, ...) — from the raw
# `version`, while the on-disk keg dir is named by pkg_version
# (`<version>_<revision>`). For any revision-bumped formula a
# post_install `system bin/"tool"` spawned a nonexistent argv0 and
# execvp failed. Compounding it, `system()` mapped a non-zero child
# exit to a plain `false` without recording anything in the
# FallbackLog, so the router printed "post_install completed" over a
# failed hook.
#
# Both defects are pinned by colocated `test {}` blocks; this script
# asserts the fix is present statically and then runs the lib test
# binary and judges those guards' lines.
#
# Exits 0 when the bugs are absent, non-zero (with a message naming
# the failing assertion) when present. No network required; finishes
# in about a minute once the test binary is built.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)

# 1. Static guard: cellar_path must be formatted from pkg_version.
if ! grep -q 'ref\.pkg_version' "$ROOT/src/core/dsl/context.zig"; then
  echo "FAIL: ExecContext cellar_path no longer uses ref.pkg_version" >&2
  exit 1
fi

# 2. Behavioural guards live in colocated `test {}` blocks; if either is
#    ever deleted the run below would silently pass. Fail loudly instead.
PATH_TEST="ExecContext binds keg paths from the revision-qualified pkg_version"
EXIT_TEST="system records a fatal flog entry when the child exits non-zero"
if ! grep -Rqs -- "$PATH_TEST" "$ROOT/src/core/dsl/context.zig"; then
  echo "FAIL: revisioned keg-path guard test missing from context.zig" >&2
  exit 1
fi
if ! grep -Rqs -- "$EXIT_TEST" "$ROOT/src/core/dsl/builtins/process.zig"; then
  echo "FAIL: system() exit-status guard test missing from process.zig" >&2
  exit 1
fi

# Rebuild the lib test binary so the run reflects the working tree.
if ! (cd "$ROOT" && zig build test-bin >/dev/null 2>&1); then
  echo "FAIL: could not build the test binary (zig build test-bin)" >&2
  exit 1
fi

BIN="$ROOT/zig-out/test-bin/lib_tests"

# The runner has no per-test filter, so run the suite and judge only the
# two guards' lines: a pass ends in "OK".
OUT=$("$BIN" 2>&1 || true)
for NAME in "$PATH_TEST" "$EXIT_TEST"; do
  LINE=$(printf '%s\n' "$OUT" | grep -F -- "$NAME" || true)
  if [[ -z "$LINE" ]]; then
    echo "FAIL: guard test did not run: $NAME" >&2
    exit 1
  fi
  if [[ "$LINE" != *OK ]]; then
    echo "FAIL: $NAME: $LINE" >&2
    exit 1
  fi
done

echo "OK: post_install keg paths revision-qualified; failures surface"
