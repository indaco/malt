#!/usr/bin/env bash
# Regression: the subprocess extractors (/usr/bin/tar, /usr/bin/unzip) never
# inspect link targets themselves - bsdtar's linkname security refuses the
# hard-link vectors and the post-extract walk wipes escaping symlinks. This
# pins that delegation through the colocated guard tests: it fails if a guard
# regresses, goes missing, or the system tar stops refusing. No network; ~1 min cold.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
FILTERS=(
  "extractTarXzFile rejects a hard link whose target climbs out"
  "extractTarXzFile rejects a file written through an archive symlink"
  "extractTarXzFile rejects a pax linkpath that overrides a benign hard link"
  "extractTarXzFile rejects a pax linkpath that overrides a benign symlink"
)

# The guards live in colocated `test {}` blocks; if one is ever deleted the
# name filter below would match nothing and silently pass. Fail loudly instead.
for f in "${FILTERS[@]}"; do
  if ! grep -Fqs -- "$f" "$ROOT/src/fs/archive.zig"; then
    echo "FAIL: guard test missing from archive.zig: $f" >&2
    exit 1
  fi
done

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
for f in "${FILTERS[@]}"; do
  LINE=$(printf '%s\n' "$OUT" | grep -F -- "$f" || true)
  if [[ -z "$LINE" ]]; then
    echo "FAIL: guard did not run: $f" >&2
    exit 1
  fi
  if [[ "$LINE" != *OK ]]; then
    echo "FAIL: a link target escaped the destination unchecked: $f" >&2
    exit 1
  fi
done

echo "PASS: subprocess extractor link-target refusals hold"
