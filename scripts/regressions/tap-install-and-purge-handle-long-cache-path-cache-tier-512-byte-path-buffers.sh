#!/usr/bin/env bash
# Regression: the cache-tier sweeps and the tap archive helpers formatted
# `{MALT_CACHE}/...` into 512-byte buffers while the validator accepts a
# 512-byte cache dir, so a long MALT_CACHE silently skipped `purge --cache`,
# `purge --downloads` and doctor's tap-cache figure.
#
# Usage: scripts/regressions/tap-install-and-purge-handle-long-cache-path-cache-tier-512-byte-path-buffers.sh
# Requirements: built malt at $MALT_BIN or zig-out/bin/malt.
# No network access required. The tap install and legacy adoption legs are
# covered by inline tests (they need lib_tests, too slow for this budget).

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BIN="${MALT_BIN:-$ROOT/zig-out/bin/malt}"
[[ -x "$BIN" ]] || {
  echo "build malt first: zig build" >&2
  exit 2
}

P=$(mktemp -d /tmp/mt_cache512.XXXXXX)
trap 'rm -rf "$P"' EXIT
export MALT_PREFIX="$P/prefix"
export MALT_OFFLINE=1
export NO_COLOR=1
export MALT_NO_EMOJI=1
# Longest cache dir the validator accepts (512), so `{cache}/downloads` and
# `{cache}/subdir` already overflow the old 512-byte buffers.
pad=$((512 - ${#P} - 2))
MALT_CACHE="$P/$(printf 'c%.0s' $(seq 1 $((pad / 2))))/$(printf 'c%.0s' $(seq 1 $((pad - pad / 2))))"
export MALT_CACHE

fail() {
  printf '  \xe2\x9c\x97 %s\n' "$*" >&2
  exit 1
}

mkdir -p "$MALT_PREFIX/db" "$MALT_CACHE/downloads" "$MALT_CACHE/subdir" "$MALT_CACHE/Tap"
sha=$(printf 'a%.0s' {1..64})
((${#MALT_CACHE} + 10 > 512 && ${#MALT_CACHE} <= 512)) || {
  echo "fixture length out of range: ${#MALT_CACHE}" >&2
  exit 2
}

# Doctor first: the sweeps below would age out nothing here, but keep order explicit.
head -c 1048576 /dev/zero >"$MALT_CACHE/Tap/$sha.tar.gz"
line=$("$BIN" doctor 2>&1 | grep -F 'Tap archive cache' || true)
[[ $line == *"1.0 MB"* ]] || fail "doctor reported no tap cache bytes: $line"

: >"$MALT_CACHE/downloads/stale.bin"
"$BIN" purge --downloads --yes >/dev/null 2>&1 || fail "purge --downloads exited $?"
[[ ! -e $MALT_CACHE/downloads/stale.bin ]] || fail "downloads sweep skipped a long cache path"

: >"$MALT_CACHE/subdir/old.tmp"
touch -t 200001010000 "$MALT_CACHE/subdir/old.tmp"
"$BIN" purge --cache=1 --yes >/dev/null 2>&1 || fail "purge --cache exited $?"
[[ ! -e $MALT_CACHE/subdir/old.tmp ]] || fail "cache prune skipped a nested path over 512 B"
echo "long MALT_CACHE tiers: OK"
