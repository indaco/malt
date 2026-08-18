#!/usr/bin/env bash
# Regression: the spawn lint must catch a platform helper reintroduced by bare
# name, including in a multi-line argv literal.
#
# The bug: malt resolves every platform helper through `src/system_tools.zig`
# so a package's own bin directory cannot shadow one via PATH. Nothing enforced
# that, so a bare name could be added back silently. The first guard matched an
# argv *shape* (`[_][]const u8{ "tool"`), which grep evaluates a line at a time
# — and a multi-line argv literal puts the name on its own line. That is the
# exact form the pre-fix code had, so the guard passed on the bug it existed to
# catch.
#
# This drives the real lint: it must be clean on the tree as committed, and
# must fail once a bare `hdiutil` is reintroduced in the multi-line form. The
# edit is reverted whether the check passes or not.
#
# Exits 0 when the guard works, non-zero (with a clear message) when it does
# not. No network required; finishes in seconds.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

LINT=scripts/lint-spawn-invariants.sh
TARGET=src/core/cask.zig
BACKUP=$(mktemp)
# The edit lands in the working tree, so restore on any exit path, not just
# a clean one. `run-regressions.sh` drives these sequentially, so no other
# script sees the window.
trap '/bin/cp -f "$BACKUP" "$TARGET"; rm -f "$BACKUP"' EXIT INT TERM

/bin/cp -f "$TARGET" "$BACKUP"

if ! bash "$LINT" >/dev/null 2>&1; then
  echo "FAIL: the lint already reports a violation on the committed tree" >&2
  bash "$LINT" >&2 || true
  exit 1
fi

# Same shape as the original: the helper name sits on its own line.
python3 - "$TARGET" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
needle = '            system_tools.hdiutil, "attach",'
if needle not in s:
    sys.exit("FAIL: fixture anchor missing from " + p)
open(p, "w", encoding="utf-8").write(s.replace(needle, '            "hdiutil", "attach",', 1))
PY

if bash "$LINT" >/dev/null 2>&1; then
  echo "FAIL: the lint accepted a bare 'hdiutil' in a multi-line argv literal" >&2
  exit 1
fi

echo "OK: the spawn lint catches a bare platform helper across lines"
