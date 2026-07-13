#!/usr/bin/env bash
# Regression: `mt install --download-only --force <same-version>` must not
# prune the installed keg. The bottle path ran the --force prune before its
# download-only early return, deleting the cellar with nothing to re-populate
# it. Driving the full CLI needs a real bottle download (network) and the bug
# is a deleteTree, so the guard is exercised through the colocated Zig test.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
FILTER="install: --download-only suppresses the --force reinstall prune"

# Guard test must exist, else the name filter silently passes.
grep -Rqs -- "$FILTER" "$ROOT/src/cli/install.zig" ||
  {
    echo "FAIL: download-only force-prune guard test is missing" >&2
    exit 1
  }

# The real call site must be gated by the predicate, not a bare `if (force)`.
# The colocated test re-implements the gate, so this grep is what catches a
# revert of the wiring at the prune site.
grep -Rqs -- "if (flags.pruneForReinstall())" "$ROOT/src/cli/install.zig" ||
  {
    echo "FAIL: --force prune is not gated by InstallFlags.pruneForReinstall" >&2
    exit 1
  }

BIN="$ROOT/zig-out/test-bin/lib_tests"
[[ -x "$BIN" ]] || (cd "$ROOT" && zig build test-bin >/dev/null 2>&1) ||
  {
    echo "FAIL: could not build test binary" >&2
    exit 1
  }

# The colocated test creates a temp prefix + Cellar/<name>/<ver>, drives the
# force/download-only prune decision with download_only=true and asserts the
# dir survives (and, with download_only=false, that it is pruned). A regression
# either aborts the run or fails the assertion, so the line never reaches OK.
LINE=$("$BIN" 2>&1 | grep -F -- "$FILTER" || true)
[[ -n "$LINE" && "$LINE" == *OK ]] ||
  {
    echo "FAIL: --download-only did not suppress the --force prune" >&2
    exit 1
  }
echo "PASS: download-only leaves the installed keg intact under --force"
