#!/usr/bin/env bash
# Regression: a post-install path spec with a wildcard in a directory name
# (`StarNetv*CLI_MacOS/starnet++`) was refused, so the binary kept no execute bit.
#
# Static guard plus unit run: the expander has no seam outside the inline tests.
#
# Usage: scripts/regressions/post-install-glob-wildcard-in-directory-name-starnet-not-executable.sh
# Requirements: zig, grep. No network access required. Creates no temp state.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

SRC=src/core/post_install_steps.zig
grep -q 'fn expandInnerGlob' "$SRC" || fail "directory-name expansion missing"
grep -q 'test "set_permissions expands a wildcard inside a directory name"' "$SRC" ||
  fail "expansion test missing"
grep -q 'test "a directory wildcard with no match is a no-op, and a linked directory is not followed"' "$SRC" ||
  fail "no-match and symlink test missing"

if [[ -n "${MALT_STATIC_ONLY:-}" ]]; then
  echo "OK: wildcard in a directory name is expanded (static-only)"
  exit 0
fi

env -u MALT_PREFIX zig build test || fail "unit tests red"
echo "OK: wildcard in a directory name is expanded"
