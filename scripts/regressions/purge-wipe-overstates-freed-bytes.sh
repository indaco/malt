#!/usr/bin/env bash
# Regression: `purge --wipe` returned the preflight byte sum over every
# existing target as `totals.bytes`, regardless of how many deletes failed.
# On a partial wipe (an undeletable target) the byte total claimed space
# that was never freed, disagreeing with `removed` (which excludes the
# failures). Every other purge tier credits bytes only on success; wipe is
# brought in line.
#
# This drives a real partial wipe against a throwaway prefix holding one
# sized, undeletable Cellar target plus one freeable store target, parses
# `--json`, and asserts that `totals.bytes` excludes the un-freed 1 MiB
# blob. Exits 0 when the bug is absent, non-zero (with a diagnostic) when
# `totals.bytes` still carries the preflight sum. No network; under 30s.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BIN="${MALT_BIN:-$ROOT/zig-out/bin/malt}"
[[ -x "$BIN" ]] || {
  echo "build malt first: zig build" >&2
  exit 2
}
command -v python3 >/dev/null || {
  echo "python3 required" >&2
  exit 2
}

ROOTDIR="$(mktemp -d)"
PREFIX="$ROOTDIR/opt-malt"
cleanup() {
  chflags -R nouchg "$PREFIX/Cellar" 2>/dev/null || true
  rm -rf "$ROOTDIR"
}
trap cleanup EXIT

mkdir -p "$PREFIX/Cellar/demo" "$PREFIX/store"
head -c 1048576 /dev/zero >"$PREFIX/Cellar/demo/blob" # 1 MiB, will fail to delete
head -c 4096 /dev/zero >"$PREFIX/store/free"          # 4 KiB, will be freed
chflags -R uchg "$PREFIX/Cellar"                      # make Cellar undeletable

out="$(MALT_PREFIX="$PREFIX" "$BIN" purge --wipe --yes --json)"

# The JSON summary is the one line carrying a `totals` object; the rest of
# stdout is the human plan/banner. Pull totals.bytes from it.
bytes="$(printf '%s\n' "$out" | python3 -c '
import sys, json
for line in sys.stdin:
    line = line.strip()
    if not line.startswith("{"):
        continue
    try:
        o = json.loads(line)
    except ValueError:
        continue
    if "totals" in o:
        print(o["totals"]["bytes"])
        break
')"

[[ -n "$bytes" ]] || {
  echo "FAIL: could not parse totals.bytes from --json output" >&2
  printf '%s\n' "$out" >&2
  exit 1
}

# Bug present if bytes still includes the 1 MiB un-freed Cellar blob.
if [[ "$bytes" -ge 1048576 ]]; then
  echo "FAIL: totals.bytes=$bytes credits the undeletable 1 MiB target" >&2
  exit 1
fi

echo "OK: freed bytes ($bytes) exclude the un-freed target"
