#!/usr/bin/env bash
# Regression: `mt doctor --fix` must never leave a store entry that is partially
# emptied on disk yet still claimed by a live `store_refs` row.
#
# The orphan reaper deleted the entry's directory tree in place and only cleared
# the ref row on full success. `deleteTree` is not atomic: an undeletable *child*
# left the earlier siblings gone while the row survived — a corrupt entry the DB
# still reports as valid, so a later link/verify reads truncated store content.
#
# This seeds a true refcount-0 orphan with two children, makes one *child*
# undeletable with the macOS immutable flag (root-proof, so it reproduces in any
# CI), runs `mt doctor --fix`, and asserts the consistent end-state: the entry is
# gone from the referenced path and its ref row is cleared.
#
# Usage: scripts/regressions/partial-deletetree-corrupt-referenced-store.sh
# Requirements: built `malt` at $MALT_BIN or zig-out/bin/malt, sqlite3 on PATH,
# macOS (chflags). Offline; finishes well under 30s.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

MALT_BIN=${MALT_BIN:-$ROOT/zig-out/bin/malt}
if [[ ! -x "$MALT_BIN" ]]; then
  printf 'FAIL: malt binary not found at %s — run "zig build" first.\n' "$MALT_BIN" >&2
  exit 1
fi
command -v sqlite3 >/dev/null 2>&1 || {
  printf 'SKIP: sqlite3 not on PATH — needed to seed the refcount-0 row.\n' >&2
  exit 2
}
command -v chflags >/dev/null 2>&1 || {
  printf 'SKIP: chflags not available — this guard needs macOS.\n' >&2
  exit 2
}

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

SHA="deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
PFX=$(mktemp -d -t mt_partial_deletetree.XXXXXX)
export MALT_PREFIX="$PFX"
# Clear the immutable flag before removing, or cleanup itself is blocked. The
# reaped child may end up under .malt-reap-*, so clear recursively.
trap 'chflags -R nouchg "$PFX" 2>/dev/null || true; rm -rf "$PFX"' EXIT

mkdir -p "$PFX/db" "$PFX/store/$SHA"
# Two children so a failure on one leaves the other behind — the partial state.
: >"$PFX/store/$SHA/a"
: >"$PFX/store/$SHA/b"

# Materialise the schema via the real initializer, then seed a refcount-0 row so
# the store dir is a true orphan the reaper will try to sweep.
"$MALT_BIN" purge --store-orphans </dev/null >/dev/null 2>&1 || true
sqlite3 "$PFX/db/malt.db" \
  "INSERT OR REPLACE INTO store_refs (store_sha256, refcount) VALUES ('$SHA', 0);"

# Undeletable child under a deletable parent: unlink of an immutable file fails.
chflags uchg "$PFX/store/$SHA/b"

"$MALT_BIN" doctor --fix </dev/null >/dev/null 2>&1 || true

# Bug present (pre-fix): the entry survives half-emptied (child 'a' gone) while
# its ref row lives on — corrupt-but-referenced.
# Bug absent (post-fix): the entry is gone from the referenced path and the row
# is cleared; the immutable bytes are left as unreferenced junk elsewhere.
row_count=$(sqlite3 "$PFX/db/malt.db" \
  "SELECT count(*) FROM store_refs WHERE store_sha256='$SHA';")

if [[ -d "$PFX/store/$SHA" ]]; then
  fail "store/$SHA survived the sweep (partial: 'a'=$([[ -e "$PFX/store/$SHA/a" ]] && echo present || echo gone)) while store_refs row count=$row_count"
fi
[[ "$row_count" == "0" ]] ||
  fail "store/$SHA was reaped but its store_refs row survived (count=$row_count) — corrupt-but-referenced"

printf 'PASS: orphan sweep leaves no partial store entry under a live ref row\n'
