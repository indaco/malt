#!/usr/bin/env bash
# Regression: a filesystem post_install step that fails on IO must be reported,
# not counted as handled.
#
# The bug: mkdir_p, touch, write, symlink, link_children and link_dir only
# logged confinement refusals. EACCES, EROFS, ENOSPC and friends were dropped,
# so the run reported a clean native execution with nothing on disk - and
# `write` truncated the user's file before swallowing the failed write. The
# `remove` step and cask uninstall likewise hid a link or tree they could not
# delete.
#
# The guard is the inline tests in post_install_steps.zig, which live in
# lib_tests; a per-file test binary could never fail here. No network.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

SRC="src/core/post_install_steps.zig"

# The destructive truncate-then-swallow shape must not come back.
if grep -Fqs -- "writeStreamingAll(ctx.io, content) catch {}" "$SRC"; then
  echo "FAIL: write drops its write error again" >&2
  exit 1
fi

# A renamed or dropped guard test would leave lib_tests green vacuously.
for t in \
  "write surfaces" \
  "touch surfaces" \
  "mkdir_p surfaces" \
  "symlink surfaces" \
  "symlink source_glob surfaces" \
  "link_children surfaces" \
  "link_dir surfaces" \
  "the link walks report" \
  "file steps report the parent" \
  "link_children refuses" \
  "inreplace surfaces" \
  "set_permissions -R surfaces" \
  "write keeps the original" \
  "remove surfaces" \
  "uninstall mode surfaces" \
  "uninstall mode keeps removing"; do
  if ! grep -Fqs -- "test \"$t" "$SRC"; then
    echo "FAIL: missing guard test: $t" >&2
    exit 1
  fi
done

if [[ "$(id -u)" -eq 0 ]]; then
  echo "SKIP: root ignores directory modes, the guard tests cannot fail"
  exit 0
fi

BIN="$ROOT/zig-out/test-bin/lib_tests"
# Always rebuild so the binary reflects current source. A caller's MALT_*
# overrides stay out, and the tests get the throwaway prefix build.zig gives
# them, never the real install.
if ! env -u MALT_PREFIX -u MALT_CACHE zig build test-bin >/dev/null 2>&1; then
  echo "FAIL: could not build the unit test binary (zig build test-bin)" >&2
  exit 1
fi

OUT=$(env -u MALT_CACHE MALT_PREFIX=/tmp/malt-test-prefix "$BIN" 2>&1) && STATUS=0 || STATUS=$?
if [[ "$STATUS" -ne 0 ]]; then
  echo "FAIL: a filesystem step IO failure was not reported" >&2
  printf '%s\n' "$OUT" | grep -iE "failed|leaked|panic" >&2 || true
  exit 1
fi

echo "PASS: filesystem step IO failures reach the fallback log"
