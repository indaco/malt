#!/usr/bin/env bash
# Regression: the subprocess extractors (/usr/bin/tar for .tar.xz, unzip for
# .zip) wrote whatever an archive inflated to. A zip's declared sizes are not
# what unzip writes, so the bound counts the decoder's own output before any
# file reaches disk. Pins that through the colocated guard tests: it fails if
# a guard regresses or goes missing. No network; ~1 min cold.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
FILTERS=(
  "extractTarXzFile refuses an archive whose payload exceeds the byte budget"
  "extractZip counts what unzip writes, not what the archive declares"
  "extractZip extracts an archive that fits the byte budget"
  "extractZip refuses an encrypted archive instead of waiting on a password"
  "installZip bounds what an unpinned zip inflates to, and only an unpinned one"
)

# A deleted guard would match nothing below and pass silently; fail loudly.
for f in "${FILTERS[@]}"; do
  if ! grep -Fqs -- "$f" "$ROOT/src/fs/archive.zig" "$ROOT/src/core/cask.zig"; then
    echo "FAIL: guard test missing: $f" >&2
    exit 1
  fi
done

BIN="$ROOT/zig-out/test-bin/lib_tests"
(cd "$ROOT" && zig build test-bin >/dev/null 2>&1) || {
  echo "FAIL: could not build the test binary (zig build test-bin)" >&2
  exit 1
}

# The runner has no per-test filter, so run the colocated suite once and judge
# each guard's line: a pass ends in "OK", a regression prints the failure there.
OUT=$(MALT_PREFIX=/tmp/malt-test-prefix "$BIN" 2>&1 || true)
for f in "${FILTERS[@]}"; do
  LINE=$(printf '%s\n' "$OUT" | grep -F -- "$f" || true)
  if [[ -z "$LINE" ]]; then
    echo "FAIL: guard did not run: $f" >&2
    exit 1
  fi
  if [[ "$LINE" != *OK ]]; then
    echo "FAIL: an archive inflated past the byte budget: $f" >&2
    exit 1
  fi
done

echo "PASS: xz and zip extraction stay within the byte budget"
