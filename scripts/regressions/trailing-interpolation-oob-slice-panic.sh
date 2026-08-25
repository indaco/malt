#!/usr/bin/env bash
# Regression: a double-quoted string whose content ends in a dangling `#{`
# (no matching `}`) must parse to a plain literal, not abort the process.
#
# The bug: parseStringInterpolation opened an interpolation segment on `#{`
# but always sliced the inner expression as `content[i + 2 .. j - 1]`,
# assuming `j` landed one byte past a matching brace. When `#{` were the
# final two bytes, the brace scan never advanced (`j == content.len`,
# depth stays 1) and the slice became `content[len .. len - 1]` —
# start > end — an unconditional safety panic. A formula post_install body
# carrying a lexeme as innocuous as `"#{"` aborted the whole `mt` process
# before the --use-system-ruby fallback could engage.
#
# No CLI subcommand drives the DSL parser without a full network install,
# and a real slice panic aborts the whole test runner, so the guard is
# exercised by a colocated `test {}` that feeds dangling `#{` strings to
# parseStringInterpolation and asserts a single literal part comes back.
# This script builds the test binary and judges that test by name; it
# exits non-zero if the guard regresses or the test goes missing.
#
# Exits 0 when the bug is absent, non-zero (with a clear message) when
# present. No network required; finishes in about a minute once the test
# binary is built.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
FILTER="parser: dangling #{ in a string is a literal, not an out-of-bounds slice"

# The guard lives in a colocated `test {}`; if it is ever deleted the name
# filter below would match nothing and silently pass. Fail loudly instead.
if ! grep -Rqs -- "$FILTER" "$ROOT/src/core/dsl/parser.zig"; then
  echo "FAIL: the dangling-interpolation guard test is missing from parser.zig" >&2
  exit 1
fi

BIN="$ROOT/zig-out/test-bin/lib_tests"
if [[ ! -x "$BIN" ]]; then
  (cd "$ROOT" && zig build test-bin >/dev/null 2>&1) || {
    echo "FAIL: could not build the test binary (zig build test-bin)" >&2
    exit 1
  }
fi

# The runner has no per-test filter, so run the colocated suite and judge only
# this guard's line: a pass ends in "OK", a regression aborts the runner with a
# slice panic so the line never reaches "OK".
OUT=$("$BIN" 2>&1 || true)
LINE=$(printf '%s\n' "$OUT" | grep -F -- "$FILTER" || true)
if [[ -z "$LINE" ]]; then
  echo "FAIL: the dangling-interpolation guard test did not run (parser aborted?)" >&2
  exit 1
fi
if [[ "$LINE" != *OK ]]; then
  echo "FAIL: a dangling #{ sliced out of bounds and aborted the parser" >&2
  exit 1
fi

echo "PASS: dangling #{ handled as a literal without panic"
