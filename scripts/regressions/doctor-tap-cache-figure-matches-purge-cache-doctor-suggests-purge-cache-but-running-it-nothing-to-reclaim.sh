#!/usr/bin/env bash
# Regression: the tap-cache figure `doctor` attaches to `mt purge --cache`
# must be what that command actually frees.
#
# `purge --cache` only deletes entries older than the default retention
# window, but doctor used to report the cache's total size and name the
# sweep as its reclaim - so a fresh cache advertised megabytes that the
# command then freed 0 B of. Doctor now splits total from reclaimable and
# drops the hint when nothing is old enough.
#
# Drives the built binary end-to-end under a throwaway prefix, offline, and
# cleans up. Exits 0 when the advertised figure and the sweep agree;
# non-zero with the mismatching line otherwise.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

BIN="${MALT_BIN:-$ROOT/zig-out/bin/malt}"
# Shell regressions run the built binary, which `zig build test` does not
# rebuild - build it here so a stale binary never masks the fix.
zig build >/dev/null

PREFIX="$(mktemp -d)/malt"
export MALT_PREFIX="$PREFIX"
trap 'rm -rf "$(dirname "$PREFIX")"' EXIT
export MALT_OFFLINE=1
export NO_COLOR=1
export MALT_NO_EMOJI=1

mkdir -p "$PREFIX/cache/Tap"
fresh="$PREFIX/cache/Tap/$(printf 'ab%.0s' {1..32}).tar.gz"
stale="$PREFIX/cache/Tap/$(printf 'cd%.0s' {1..32}).tar.gz"
head -c 1048576 /dev/zero >"$fresh"
head -c 2097152 /dev/zero >"$stale"
# Back-dated past the default retention window.
touch -t "$(date -v-40d +%Y%m%d%H%M)" "$stale"

line=$("$BIN" doctor 2>&1 | grep 'Tap archive cache' || true)
[[ "$line" == *"3.0 MB"* && "$line" == *"2.0 MB older than 30 days"* && "$line" == *"Run: mt purge --cache"* ]] ||
  {
    echo "FAIL: doctor line does not split total vs reclaimable: $line" >&2
    exit 1
  }

json=$("$BIN" doctor --json 2>/dev/null || true)
[[ "$json" == *'"tap_cache":{"bytes":3145728,"reclaimable_bytes":2097152}'* ]] ||
  {
    echo "FAIL: doctor --json tap_cache does not expose reclaimable bytes: $json" >&2
    exit 1
  }

"$BIN" purge --cache --yes >/dev/null 2>&1 || true
[[ ! -e "$stale" && -e "$fresh" ]] ||
  {
    echo "FAIL: purge --cache did not free exactly the advertised entry" >&2
    exit 1
  }

# A fresh-only cache must carry no reclaim hint (the original report).
line=$("$BIN" doctor 2>&1 | grep 'Tap archive cache' || true)
[[ "$line" == *"1.0 MB"* && "$line" != *"Run: mt purge --cache"* ]] ||
  {
    echo "FAIL: doctor still suggests purge --cache with nothing older than 30 days: $line" >&2
    exit 1
  }

echo "PASS: doctor's tap-cache figure matches what purge --cache reclaims"
