#!/usr/bin/env bash
# Regression: a store entry no keg holds is reclaimable whatever its
# counter says.
#
# Older binaries could leave `store_refs.refcount` above zero with no
# `kegs` row behind it (a claim taken before the keg row, never undone).
# Both reclaim paths — `purge --store-orphans` and `doctor` — treated
# `refcount <= 0` as the only collectible state, so those bytes were
# pinned for the life of the prefix: doctor stayed silent and purge
# reported nothing to do. `kegs` is the authority on ownership; the
# counter must not veto it.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

BIN="${MALT_BIN:-$ROOT/zig-out/bin/malt}"
if [[ ! -x "$BIN" ]] && ! zig build >/dev/null 2>&1; then
  echo "FAIL: could not build zig-out/bin/malt" >&2
  exit 1
fi

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

tmp="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT

prefix="$tmp/prefix"
sha="beef$(printf '0%.0s' $(seq 1 60))"

mkdir -p "$prefix"/{store,Cellar,Caskroom,opt,bin,lib,tmp,cache,db} \
  "$prefix/store/$sha/planted/1.0"
echo stranded >"$prefix/store/$sha/planted/1.0/README"

export MALT_PREFIX="$prefix" NO_COLOR=1 MALT_NO_EMOJI=1 MALT_OFFLINE=1

# A dry run creates the schema without touching the store.
"$BIN" purge --store-orphans --dry-run >/dev/null 2>&1 || true

# The stranded shape: a claim row with zero owning kegs.
sqlite3 "$prefix/db/malt.db" \
  "INSERT INTO store_refs (store_sha256) VALUES ('$sha');"

"$BIN" doctor >"$tmp/doctor.txt" 2>&1 || true
grep -q '1 orphaned store entry' "$tmp/doctor.txt" ||
  fail "doctor did not report the stranded entry no keg holds"

"$BIN" purge --store-orphans >"$tmp/purge.txt" 2>&1 ||
  fail "purge --store-orphans exited non-zero: $(cat "$tmp/purge.txt")"

[[ ! -e "$prefix/store/$sha" ]] ||
  fail "purge --store-orphans left the stranded entry in place"

n=$(sqlite3 "$prefix/db/malt.db" \
  "SELECT count(*) FROM store_refs WHERE store_sha256='$sha';")
[[ "$n" == "0" ]] ||
  fail "purge --store-orphans reclaimed the bytes but left the ref row behind"

echo "PASS: a store entry no keg holds is reclaimed however high its counter drifted"
