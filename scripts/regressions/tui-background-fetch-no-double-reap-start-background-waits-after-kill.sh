#!/usr/bin/env bash
# Regression: the TUI interpreter must reap a background audit exactly once.
#
# `std.process.Child.kill` blocks to termination, reaps, and clears the pid;
# `wait` opens with `assert(child.id != null)`. A `wait` after a `kill` is
# therefore a panic, not a belt-and-braces reap — and `catch {}` cannot
# absorb an assert.
#
# No `malt` subcommand can reach the pipe-less spawn arm this protects, so the
# guard judges the source shape and the colocated inline guard test instead of
# driving the CLI. It stays a static check on purpose: the inline test it pins
# is executed by `just test`, and rebuilding the suite here would cost minutes
# for no extra signal.
#
# The `.wait(` ban is file-scoped by design. A `wait` after a *drain* is the
# correct idiom and is used legitimately elsewhere in the tree.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SRC="$ROOT/src/tui/perform.zig"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

HIT=$(grep -n '\.wait(' "$SRC" || true)
[[ -n "$HIT" ]] && fail "perform.zig waits on a child; kill already reaps it: ${HIT%%:*}"

# Catch a reintroduction under a different receiver name.
grep -n -A3 'kill(' "$SRC" | grep -q 'wait(' &&
  fail "perform.zig waits within three lines of a kill - double reap"

grep -q 'test "startBackground never waits after a kill"' "$SRC" ||
  fail "the inline no-wait guard test was removed from src/tui/perform.zig"

echo "PASS: the TUI interpreter reaps each background audit exactly once"
exit 0
