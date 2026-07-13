#!/usr/bin/env bash
# Regression: `purge --cache` must reclaim relocated kegs left under a
# superseded relocation-logic version, and must never touch foreign entries.
#
# The relocated-keg cache is keyed `store-relocated/v<N>/<sha>`. Bumping the
# logic version turns old `v<N-1>/` trees into orphans that no command
# reclaimed — the cache is path-only, so `purge --store-orphans` (DB-driven)
# and `doctor` both skip it. The fix folds a version-aware reap into the
# `--cache` scope so `purge --cache` / `--housekeeping` / `cleanup` reclaim it.
#
# Drives the built binary end-to-end under a throwaway prefix, offline, and
# cleans up. Exits 0 when the stale version tree is reclaimed and the foreign
# sibling survives; non-zero otherwise.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

BIN="${MALT_BIN:-$ROOT/zig-out/bin/malt}"
# Shell regressions run the built binary, which `zig build test` does not
# rebuild — build it here so a stale binary never masks the fix.
zig build >/dev/null

PREFIX="$(mktemp -d)/malt"
export MALT_PREFIX="$PREFIX"
trap 'rm -rf "$(dirname "$PREFIX")"' EXIT
export NO_COLOR=1
export MALT_NO_EMOJI=1

sha=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef

# A version segment far above any real logic version → always stale.
stale="$PREFIX/store-relocated/v999999"
mkdir -p "$stale/$sha"
printf 'x' >"$stale/$sha/keg-file"

# A non-`v<digits>` sibling must never be reaped.
foreign="$PREFIX/store-relocated/keep"
mkdir -p "$foreign"

"$BIN" purge --cache --yes >/dev/null 2>&1 || true

[ ! -d "$stale" ] || {
  echo "FAIL: purge --cache did not reclaim the stale relocated version tree ($stale)" >&2
  exit 1
}
[ -d "$foreign" ] || {
  echo "FAIL: purge --cache deleted a foreign store-relocated entry ($foreign)" >&2
  exit 1
}

echo "PASS: purge --cache reclaims stale relocated-keg versions and spares foreign entries"
