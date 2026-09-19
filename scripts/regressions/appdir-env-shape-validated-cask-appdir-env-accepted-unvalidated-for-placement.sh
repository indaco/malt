#!/usr/bin/env bash
# Regression: a `MALT_APPDIR` that is the filesystem root, carries `..` or
# `//`, or ends in a slash used to become the `.app` placement directory
# verbatim; a trailing slash also stored `<appdir>//<Name>.app`, which the
# running-app guard never matches. The resolver now applies the shared
# env-root shape check and trims trailing slashes.
#
# The resolver is pure, so the pins live in tests/cask_test.zig: half one
# checks they and the predicate are still in the source, half two builds
# `test-bin` and runs that binary (seconds warm, cold dominates). No network.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
T="$ROOT/tests/cask_test.zig"
SRC="$ROOT/src/core/cask.zig"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# 1. Static pins: a revert or a rename cannot pass silently.
PINS=(
  "resolveAppDir: a root MALT_APPDIR falls back to the default"
  "resolveAppDir: a traversal or empty-component MALT_APPDIR falls back to the default"
  "resolveAppDir: trailing slashes on MALT_APPDIR are trimmed"
)
for name in "${PINS[@]}"; do
  grep -qF -- "test \"$name\"" "$T" || fail "missing pin test: $name"
done
awk '/pub fn resolveAppDir\(/,/^}/' "$SRC" | grep -q 'validateShape' ||
  fail "resolveAppDir no longer shape-validates MALT_APPDIR"

# 2. Behaviour: run the integration binary that carries the pins.
(cd "$ROOT" && zig build test-bin >/dev/null 2>&1) ||
  fail "could not build the test binaries (zig build test-bin)"
"$ROOT/zig-out/test-bin/cask_test" >/dev/null 2>&1 || fail "cask_test reports a failure"

echo "PASS: MALT_APPDIR is shape-validated before cask placement"
