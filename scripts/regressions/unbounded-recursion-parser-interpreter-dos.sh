#!/usr/bin/env bash
# Regression: an adversarial formula body with pathological expression nesting
# or unbounded self-recursion must degrade to a catchable DSL diagnostic, not
# abort the process.
#
# The bug: the recursive-descent parser had no nesting-depth limit and the
# interpreter had no user-method call-depth limit. A post_install body of the
# form `((((( ... )))))` drove `parseExpression` one native frame per level,
# and `def f; f; end\nf` drove `invokeUserMethod` one frame per call. Both
# exhausted the native stack — an uncatchable SIGSEGV on Zig, below the
# `executePostInstall(...) catch {}` boundary — so the whole `malt install`
# process died instead of the formula degrading to a partial skip.
#
# A real overflow assertion is hostile to the test runner (it aborts the whole
# process, not one test), so the guard is exercised by two colocated `test {}`
# blocks that assert the depth limits fire as a bounded ParseError / diagnostic
# well before any native limit. This script builds the lib test binary and runs
# those tests by name; it exits non-zero if either guard regresses or its test
# goes missing.
#
# Exits 0 when the guards hold, non-zero (with a clear message) when the bug is
# present. No network required; finishes well under 30s once the binary builds.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)

# One test per recursion axis: bracket nesting, `!` chains, statement-block
# nesting, and `#{…}` interpolation each bypass the others, so every guard is
# checked independently.
PARSER_FILTERS=(
  "parser: expression nesting beyond the depth limit is a bounded ParseError"
  "parser: unary-not chain beyond the depth limit is a bounded ParseError"
  "parser: block nesting beyond the depth limit is a bounded ParseError"
  "parser: deeply nested interpolation stays bounded and does not overflow"
)
INTERP_FILTER="interpreter: self-recursive method hits the call-depth guard and degrades"

# The guards live in colocated `test {}` blocks; if one is deleted the name
# filter below would match nothing and silently pass. Fail loudly instead.
for filter in "${PARSER_FILTERS[@]}"; do
  if ! grep -Rqs -- "$filter" "$ROOT/src/core/dsl/parser.zig"; then
    echo "FAIL: a parser depth-guard test is missing from parser.zig: $filter" >&2
    exit 1
  fi
done
if ! grep -Rqs -- "$INTERP_FILTER" "$ROOT/src/core/dsl/interpreter.zig"; then
  echo "FAIL: the interpreter call-depth guard test is missing from interpreter.zig" >&2
  exit 1
fi

BIN="$ROOT/zig-out/test-bin/lib_tests"
if [[ ! -x "$BIN" ]]; then
  (cd "$ROOT" && zig build test-bin >/dev/null 2>&1) || {
    echo "FAIL: could not build the test binary (zig build test-bin)" >&2
    exit 1
  }
fi

# The runner has no per-test filter, so run the colocated suite once and judge
# each guard's line: a pass ends in "OK", a regression prints the failure there.
OUT=$("$BIN" 2>&1 || true)

for filter in "${PARSER_FILTERS[@]}" "$INTERP_FILTER"; do
  LINE=$(printf '%s\n' "$OUT" | grep -F -- "$filter" || true)
  if [[ -z "$LINE" ]]; then
    echo "FAIL: depth-guard test did not run: $filter" >&2
    exit 1
  fi
  if [[ "$LINE" != *OK ]]; then
    echo "FAIL: a DSL depth guard regressed (process can overflow on adversarial input): $filter" >&2
    exit 1
  fi
done

echo "PASS: parser + interpreter depth guards hold; adversarial input degrades without a crash"
