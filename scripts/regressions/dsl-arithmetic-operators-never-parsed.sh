#!/usr/bin/env bash
# Regression: DSL arithmetic (`+`, `-`, `*`) and negative literals must parse
# and evaluate as numbers.
#
# The bug: the parser had no additive/multiplicative level and no unary-minus
# literal, so `1 + 2`, `x - 1`, `2 * 3` and `-5` were a ParseError and the
# whole post_install body fell back to system Ruby. Fixing only the parser
# would have been worse: `+` reached the string-concat builtin and `1 + 2`
# evaluated to "12".
#
# No CLI subcommand drives the DSL parser without a full network install, so
# the guards are colocated `test {}` blocks (one per layer). This script
# builds the test binary and judges those tests by name; it exits non-zero if
# either regresses or goes missing.
#
# Exits 0 when the bug is absent, non-zero (with a clear message) when
# present. No network required.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
PARSER_T="parser: arithmetic operators and negative literals parse"
INTERP_T="interpreter: integer + integer is arithmetic, never string concat"

# A deleted test would match nothing and pass silently. Fail loudly instead.
if ! grep -Fqs -- "$PARSER_T" "$ROOT/src/core/dsl/parser.zig"; then
  echo "FAIL: the parser arithmetic guard test is missing from parser.zig" >&2
  exit 1
fi
if ! grep -Fqs -- "$INTERP_T" "$ROOT/src/core/dsl/interpreter.zig"; then
  echo "FAIL: the interpreter arithmetic guard test is missing from interpreter.zig" >&2
  exit 1
fi

# Always rebuild: a stale binary would judge the previous tree. The build is
# incremental, so a warm run is cheap.
(cd "$ROOT" && zig build test-bin >/dev/null 2>&1) || {
  echo "FAIL: could not build the test binary (zig build test-bin)" >&2
  exit 1
}

BIN="$ROOT/zig-out/test-bin/lib_tests"
OUT=$("$BIN" 2>&1 || true)
for t in "$PARSER_T" "$INTERP_T"; do
  LINE=$(printf '%s\n' "$OUT" | grep -F -- "$t" || true)
  if [[ "$LINE" != *OK ]]; then
    echo "FAIL: '$t' did not pass: ${LINE:-did not run}" >&2
    exit 1
  fi
done

echo "PASS: DSL arithmetic parses and evaluates as numbers"
