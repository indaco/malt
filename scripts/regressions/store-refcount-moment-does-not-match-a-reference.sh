#!/usr/bin/env bash
# Regression: a store entry a live `kegs` row references must never be
# reclaimed, whatever `store_refs.refcount` says.
#
# The install path claimed a ref only when the bottle download was cold, so
# a warm materialize (install → uninstall → install of the same version)
# wrote a `kegs` row without taking one. The entry then sat at refcount 0
# with a live keg holding its bytes, and both `mt purge --store-orphans` and
# `mt doctor --fix` classified it as a purgeable orphan and deleted it — a
# maintenance command reclaiming bytes a live keg owns.
#
# Property under test: the reclaim predicate consults `kegs`, not just the
# counter. The second half guards the opposite over-correction — with no keg
# row left, the same entry must still be reclaimable.
#
# Usage: scripts/regressions/store-refcount-moment-does-not-match-a-reference.sh
# Requirements: built `malt` at $MALT_BIN or zig-out/bin/malt. Offline.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

MALT_BIN=${MALT_BIN:-$ROOT/zig-out/bin/malt}
if [[ ! -x "$MALT_BIN" ]]; then
  printf 'FAIL: malt binary not found at %s — run "zig build" first.\n' "$MALT_BIN" >&2
  exit 1
fi

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

PFX=$(mktemp -d -t mt_store_refcount_live_keg.XXXXXX)
export MALT_PREFIX="$PFX"
trap 'rm -rf "$PFX"' EXIT

SHA=$(printf 'ab%.0s' {1..32})
mkdir -p "$PFX/db" "$PFX/store/$SHA" "$PFX/Cellar/probe/1.0"

# Let the real initializer create the schema, then seed the exact state a
# warm reinstall after an uninstall leaves behind: refcount 0, live keg.
"$MALT_BIN" purge --store-orphans </dev/null >/dev/null 2>&1 || true
sqlite3 "$PFX/db/malt.db" \
  "INSERT INTO store_refs (store_sha256, refcount) VALUES ('$SHA', 0);
   INSERT INTO kegs (name, full_name, version, revision, store_sha256, cellar_path)
     VALUES ('probe','probe','1.0',0,'$SHA','$PFX/Cellar/probe/1.0');"

"$MALT_BIN" purge --store-orphans </dev/null >/dev/null 2>&1 || true
[[ -d "$PFX/store/$SHA" ]] ||
  fail 'purge --store-orphans reaped a store entry a live keg references'

"$MALT_BIN" doctor --fix </dev/null >/dev/null 2>&1 || true
[[ -d "$PFX/store/$SHA" ]] ||
  fail 'doctor --fix reaped a store entry a live keg references'

# With the keg row gone the same entry must still be reclaimable, or the
# sweep has been disarmed rather than narrowed.
sqlite3 "$PFX/db/malt.db" "DELETE FROM kegs WHERE store_sha256 = '$SHA';"
"$MALT_BIN" purge --store-orphans </dev/null >/dev/null 2>&1 || true
[[ ! -d "$PFX/store/$SHA" ]] ||
  fail 'a genuinely unreferenced store entry is no longer reclaimable'

printf 'PASS: store entries held by a live keg survive the orphan sweep\n'
