#!/usr/bin/env bash
# Regression: the persisted `outdated.json` a full `mt upgrade --dry-run` writes
# must follow the per-package fetch, not the bulk index. When the two skew for a
# `needs_upgrade` row (index says behind, the fetch says current, or the two name
# different targets), the snapshot must record the fetch's verdict, the same one
# the install decision, the printed line, and the NDJSON event already use.
#
# Hermetic, no network: the audit reads the on-disk versions index
# ({prefix}/cache/api/versions_<kind>.txt) while phase 2 reads the per-package
# document ({prefix}/cache/api/formula_<name>.json). Seeding the two with
# disagreeing versions reproduces the skew deterministically.
#
# Pins two contracts on the warmed snapshot:
#   1. A row the fetch reports current is absent from the snapshot, even when the
#      index lists it behind (pre-fix: the index target leaked in).
#   2. A row both agree is behind is recorded at the fetch's target, not the
#      index's, when the two differ.
#
# Usage: scripts/regressions/dry-run-snapshot-follows-fetch-collapse-compare-sites-onto-index.sh
# Requirements: built malt at $MALT_BIN or zig-out/bin/malt; sqlite3 on PATH.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BIN="${MALT_BIN:-$ROOT/zig-out/bin/malt}"
[[ -x "$BIN" ]] || {
  echo "build malt first: zig build" >&2
  exit 2
}
command -v sqlite3 >/dev/null 2>&1 || {
  echo "this regression needs sqlite3 on PATH" >&2
  exit 2
}

PREFIX=$(mktemp -d -t malt_snap_follows_fetch.XXXXXX)
trap 'rm -rf "$PREFIX"' EXIT
export MALT_PREFIX="$PREFIX"
export NO_COLOR=1
export MALT_NO_EMOJI=1
unset MALT_OFFLINE MALT_OUTDATED_MAX_AGE MALT_CACHE CI

DB="$PREFIX/db/malt.db"
SNAP="$PREFIX/cache/outdated.json"
API="$PREFIX/cache/api"

pass() { printf '  \xe2\x9c\x93 %s\n' "$*"; }
fail() {
  printf '  \xe2\x9c\x97 %s\n' "$*" >&2
  exit 1
}

mkdir -p "$PREFIX/db" "$API"
"$BIN" list >/dev/null 2>&1 || true
sqlite3 "$DB" "DELETE FROM kegs; DELETE FROM casks;" 2>/dev/null || true
rm -f "$SNAP"

seed_keg() {
  local name="$1" version="$2"
  sqlite3 "$DB" "INSERT INTO kegs (name, full_name, version, revision, store_sha256, cellar_path)
    VALUES ('$name', '$name', '$version', 0, 'seedsha', '/tmp/c/$name/$version');"
}

# Fake upstream, per-package fetch (phase 2 reads this).
seed_formula_cache() {
  local name="$1" stable="$2"
  printf '{"name":"%s","versions":{"stable":"%s"},"revision":0}' "$name" "$stable" \
    >"$API/formula_$name.json"
}

# Two installed core formulas, both at 1.0.
seed_keg current_row 1.0
seed_keg behind_row 1.0

# Bulk index (the audit's needs_upgrade source): both look behind.
printf 'current_row\t2.0\t0\nbehind_row\t4.0\t0\n' >"$API/versions_formula.txt"

# Per-package fetch (the authoritative install decision):
#   current_row -> 1.0  (agrees with installed: nothing to do)
#   behind_row  -> 3.0  (behind, but at a target the index does not name)
seed_formula_cache current_row 1.0
seed_formula_cache behind_row 3.0

"$BIN" upgrade --dry-run >/dev/null 2>&1 || true
[[ -f "$SNAP" ]] || fail "full dry-run wrote no outdated.json"

# Contract 1: the fetch says current_row is current, so it must not appear.
if grep -q '"name":"current_row"' "$SNAP"; then
  fail "snapshot advertises current_row, which the fetch reports current; got: $(cat "$SNAP")"
fi
pass "a fetch-current row is absent from the warmed snapshot"

# Contract 2: behind_row is recorded at the fetch's 3.0, not the index's 4.0.
grep -q '"name":"behind_row","installed":"1.0","latest":"3.0"' "$SNAP" ||
  fail "behind_row not recorded at the fetch target 3.0; got: $(cat "$SNAP")"
if grep -q '"latest":"4.0"' "$SNAP"; then
  fail "snapshot carries the stale index target 4.0; got: $(cat "$SNAP")"
fi
pass "a behind row is recorded at the fetch target, not the index target"

printf '\n\xe2\x9c\x94 dry-run snapshot follows the fetch regression passed\n'
