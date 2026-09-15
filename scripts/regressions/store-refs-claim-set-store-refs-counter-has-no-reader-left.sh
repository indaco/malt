#!/usr/bin/env bash
# Regression: `store_refs` is a claim set, not a counter.
#
# Once `kegs` became the authority on which store bytes are still owned,
# `store_refs.refcount` had writers but no reader. A column the product
# never consults invites the next reader to assume it still gates reclaim
# — the assumption that produced the inflated-row bug. The row itself must
# survive: a row with no keg is an orphan, no row is a bottle never claimed.
#
# Property under test: a fresh DB has no `refcount` column and sits at
# schema 16; a v15 DB migrates with its claim rows intact; a row a live
# keg references is not listed by the orphan sweep.
#
# Usage: scripts/regressions/store-refs-claim-set-store-refs-counter-has-no-reader-left.sh
# Requirements: built `malt` at $MALT_BIN or zig-out/bin/malt, sqlite3. Offline.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

BIN="${MALT_BIN:-$ROOT/zig-out/bin/malt}"
if [[ ! -x "$BIN" ]]; then
  printf 'FAIL: malt binary not found at %s — run "zig build" first.\n' "$BIN" >&2
  exit 1
fi
if ! command -v sqlite3 >/dev/null; then
  echo "SKIP: sqlite3 not on PATH" >&2
  exit 0
fi

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

PFX=$(mktemp -d -t mt_store_refs_claim_set.XXXXXX)
export MALT_PREFIX="$PFX" NO_COLOR=1 MALT_NO_EMOJI=1 MALT_OFFLINE=1
trap 'rm -rf "$PFX"' EXIT

db() { sqlite3 "$PFX/db/malt.db" "$1"; }
SHA=$(printf 'a%.0s' {1..64})

# (1) fresh DB: no counter column, schema 16. A dry run creates the schema
#     without touching the store.
mkdir -p "$PFX/db"
"$BIN" purge --store-orphans --dry-run </dev/null >/dev/null 2>&1 || true
[[ -f "$PFX/db/malt.db" ]] || fail "no DB was created under $PFX/db"
! db "PRAGMA table_info(store_refs);" | grep -q refcount ||
  fail "fresh DB still carries store_refs.refcount"
[[ "$(db 'SELECT MAX(version) FROM schema_version;')" == 16 ]] ||
  fail "fresh DB did not reach schema 16"

# (2) a v15-shaped DB migrates and keeps its claim rows. Seeded as v15 on
#     purpose so the real migration chain drops the column.
rm -rf "$PFX/db" && mkdir -p "$PFX/db"
db "CREATE TABLE store_refs (store_sha256 TEXT PRIMARY KEY, refcount INTEGER NOT NULL DEFAULT 1);
    CREATE TABLE schema_version (version INTEGER PRIMARY KEY);
    INSERT INTO schema_version VALUES (1),(2),(3),(4),(5),(6),(7),(8),(9),(10),(11),(12),(13),(14),(15);
    INSERT INTO store_refs VALUES ('$SHA', 3);"
"$BIN" purge --store-orphans --dry-run </dev/null >/dev/null 2>&1 || true
! db "PRAGMA table_info(store_refs);" | grep -q refcount ||
  fail "v15 -> v16 left the counter column behind"
[[ "$(db 'SELECT count(*) FROM store_refs;')" == 1 ]] ||
  fail "v15 -> v16 lost a claim row"

# (3) a referenced row is a claim, not an orphan.
mkdir -p "$PFX/store/$SHA" "$PFX/Cellar/probe/1.0"
db "INSERT INTO kegs (name, full_name, version, revision, store_sha256, cellar_path)
     VALUES ('probe','probe','1.0',0,'$SHA','$PFX/Cellar/probe/1.0');"
! "$BIN" purge --store-orphans --dry-run </dev/null 2>&1 | grep -q "$SHA" ||
  fail "a store entry a live keg references was listed as an orphan"

printf 'PASS: store_refs is a claim set on a v16 schema\n'
