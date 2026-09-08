#!/usr/bin/env bash
# Regression: `Utils.safe_popen_read` must reap its child when the command's
# output overruns the 1 MiB read cap. malt keeps the read end of the pipe open,
# so a child abandoned on that early return never gets EPIPE — it blocks in
# write(2) for the rest of the malt run while the builtin quietly returns "",
# which a formula cannot tell apart from a command that printed nothing.
#
# No CLI subcommand drives the builtin without a network install, so the guard
# lives in a colocated `test {}` that calls it against `yes` and asserts
# waitpid(-1) reports ECHILD afterwards. `zig test` cannot take the builtin as
# its root (its sibling imports leave the module path), so a throwaway root
# harness pulls the file in and a name filter runs just that test.
#
# Exits 0 when the bug is absent, non-zero (with a clear message) when present.
# No network required; finishes in a few seconds.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SRC="src/core/dsl/builtins/process.zig"
FILTER="safe_popen_read reaps the child when output overruns the cap"

# A filter that matches nothing exits 0, so a deleted guard would pass
# silently. Fail loudly instead.
if ! grep -qs -- "$FILTER" "$ROOT/$SRC"; then
  echo "FAIL: the over-cap reap guard test is missing from $SRC" >&2
  exit 1
fi

HARNESS="$ROOT/.popen-reap-regression.$$.zig"
trap 'rm -f "$HARNESS"' EXIT
printf 'test { _ = @import("%s"); }\n' "$SRC" >"$HARNESS"

if (cd "$ROOT" && zig test --test-filter "$FILTER" "$HARNESS") >/dev/null 2>&1; then
  echo "PASS: over-cap safe_popen_read reaps its child"
else
  echo "FAIL: safe_popen_read left a live child behind after the read cap was overrun" >&2
  exit 1
fi
