#!/usr/bin/env bash
# Regression: `purge --cache` reclaims relocated-keg snapshots that no bottle
# backs any more: the pre-versioning `store-relocated/<sha>/` layout, and
# current-version snapshots (plus their sidecars) with no `store/<sha>`.
# Pre-fix only a stale `v<M>/` tree was reaped, so both kinds grew forever.
#
# Live entries must survive: a snapshot with a store sibling, a foreign
# top-level name, and an in-flight `<sha>.tmp.<hex>` save.
#
# Usage: scripts/regressions/relocated-store-reclaim-relocated-store-entries-are-never-reclaimed.sh
# Requirements: built malt at $MALT_BIN or zig-out/bin/malt.
# No network access required.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BIN="${MALT_BIN:-$ROOT/zig-out/bin/malt}"
[[ -x "$BIN" ]] || {
  echo "build malt first: zig build" >&2
  exit 2
}

P="/tmp/mt_reloc_reclaim_$$"
trap 'rm -rf "$P"' EXIT

hex() { printf '%064d' 0 | tr 0 "$1"; }
A=$(hex a)
B=$(hex b)
C=$(hex c)
VER=$(awk -F'[ ;]+' '/pub const RELOC_LOGIC_VERSION/ { print $6 }' "$ROOT/src/core/relocated_store.zig")
[[ "$VER" =~ ^[0-9]+$ ]] || {
  echo "cannot read RELOC_LOGIC_VERSION" >&2
  exit 2
}
R="$P/store-relocated"
V="$R/v$VER"

mkdir -p "$P/db" "$P/store/$C" "$R/$A" "$R/notes" "$V/$B" "$V/$C" "$V/$C.tmp.deadbeef"
echo x >"$R/$A/f"
echo x >"$V/$B/f"
: >"$V/$B.verified"
: >"$V/$B.keg"

env -u MALT_CACHE MALT_PREFIX="$P" PATH=/usr/bin:/bin "$BIN" purge --cache </dev/null >/dev/null

for gone in "$R/$A" "$V/$B" "$V/$B.verified" "$V/$B.keg"; do
  [[ ! -e "$gone" ]] || {
    echo "FAIL: not reclaimed: ${gone#"$P"/}" >&2
    exit 1
  }
done
for kept in "$V/$C" "$R/notes" "$V/$C.tmp.deadbeef"; do
  [[ -e "$kept" ]] || {
    echo "FAIL: live entry removed: ${kept#"$P"/}" >&2
    exit 1
  }
done
echo "ok: relocated store reclaim"
