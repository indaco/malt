#!/usr/bin/env bash
# Regression: glob matching must stay bounded, and there must be only one of it.
#
# Patterns come from formula and tap data, and two costs in the old matchers ran
# away on them: brace alternation multiplies combinations, and a recursive star
# matcher re-explores every suffix. Both hang rather than crash, which is why the
# depth cap the original report asked for would not have caught either. Two
# copies of the matcher also disagreed on nested groups, so a reintroduced
# private copy is itself a regression.
#
# No subcommand exposes the matcher, so the guard runs its colocated `test {}`
# blocks. Exits 0 when the bounds hold, non-zero with a clear message when they
# do not. No network; about a minute.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SRC="$ROOT/src/glob.zig"

FILTERS=(
  "matches literals and wildcards"
  "matches a flat alternation"
  "matches a nested alternation"
  "alternation cannot be driven into an unbounded expansion"
  "an exhausted budget refuses instead of exploring"
  "an expansion longer than the buffer is dropped, not truncated"
  "a wide pattern still matches its last combination"
  "a pattern past the ceiling is refused whole, not part-way"
  "repeated wildcards cost steps, not combinations"
)

# If a guard test is ever deleted the name filter would match nothing and
# silently pass. Fail loudly instead.
for F in "${FILTERS[@]}"; do
  if ! grep -qs -- "$F" "$SRC"; then
    echo "FAIL: glob expansion guard test missing: $F" >&2
    exit 1
  fi
done

# Always rebuild: a stale binary from an earlier run cannot contain the guards.
BIN="$ROOT/zig-out/test-bin/lib_tests"
(cd "$ROOT" && zig build test-bin >/dev/null 2>&1) || {
  echo "FAIL: could not build the test binary (zig build test-bin)" >&2
  exit 1
}

# An unbounded matcher does not fail, it stops returning - so cap the run and
# treat exhausting the cap as the regression it is.
set +e
OUT=$(timeout 600 "$BIN" 2>&1)
RC=$?
set -e
if [[ $RC -eq 124 ]]; then
  echo "FAIL: the test binary did not finish - brace expansion is unbounded again" >&2
  exit 1
fi

for F in "${FILTERS[@]}"; do
  LINE=$(printf '%s\n' "$OUT" | grep -F -- "glob.test.$F" || true)
  if [[ -z "$LINE" ]]; then
    echo "FAIL: glob expansion guard test did not run: $F" >&2
    exit 1
  fi
  if [[ "$LINE" != *OK ]]; then
    echo "FAIL: glob brace expansion is no longer bounded: $F" >&2
    exit 1
  fi
done

# One matcher, not two. A reintroduced private copy would silently escape every
# guard above, which is exactly how the two implementations drifted apart.
COPIES=$(grep -rl --include='*.zig' -e 'fn globMatch' -e 'fn starMatch' "$ROOT/src" || true)
if [[ -n "$COPIES" ]]; then
  echo "FAIL: a private glob matcher reappeared, bypassing the shared one:" >&2
  echo "$COPIES" >&2
  exit 1
fi

echo "PASS: glob matching is bounded, nesting-correct, and not duplicated"
