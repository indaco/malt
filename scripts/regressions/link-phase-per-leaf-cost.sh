#!/usr/bin/env bash
# Regression: the link phase cost ~0.19 ms per symlinked leaf because the
# per-leaf loop paid four filesystem syscalls (an unconditional mkdir -p of
# the leaf's parent, an unlink of a temp name that never existed, a symlink
# and a rename) plus one prepare/step/finalize INSERT in autocommit, i.e.
# one WAL commit with its own fsync per linked file. A keg with a large
# include/ or share/ tree therefore linked in seconds: openssl@3 (7616
# leaves) took 1.30s.
#
# The assertion is on cost per leaf, measured against a synthetic keg of
# known leaf count, so it is about malt's link loop and not about bottle
# size or network weather. No network is used at all.
#
# Measured before the fix: 0.183 ms/leaf (ReleaseSafe), 0.226 (Debug).
# After: 0.058 (ReleaseSafe), 0.073 (Debug). The ceiling sits between the
# two bands with room for a loaded box. It guards against the
# autocommit-per-leaf shape returning, not a microbenchmark.
#
# Exits 0 when the bug is absent, non-zero (with the measured figure) when
# present. Finishes well under 30s once built.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BIN="${MALT_BIN:-$ROOT/zig-out/bin/malt}"
[[ -x "$BIN" ]] || {
  echo "build malt first: zig build" >&2
  exit 2
}
command -v sqlite3 >/dev/null || {
  echo "sqlite3 required" >&2
  exit 2
}
command -v python3 >/dev/null || {
  echo "python3 required" >&2
  exit 2
}

LEAVES=2000
CEILING_MS=0.130

PREFIX="$(mktemp -d)/malt-prefix"
export MALT_PREFIX="$PREFIX"
export NO_COLOR=1 MALT_NO_EMOJI=1
trap 'rm -rf "$(dirname "$PREFIX")"' EXIT

pass() { printf '  ✓ %s\n' "$*"; }
fail() {
  printf '  ✗ %s\n' "$*" >&2
  exit 1
}

DB="$PREFIX/db/malt.db"
mkdir -p "$PREFIX/db"

# Init the schema with a benign command against the empty DB file.
: >"$DB"
"$BIN" link __absent__ >/dev/null 2>&1 || true
sqlite3 "$DB" "SELECT 1 FROM kegs LIMIT 1;" >/dev/null 2>&1 ||
  fail "schema init did not create the kegs table"

# Synthetic keg: one flat directory of many leaves. Flat is the honest
# shape here: the fix caches the leaf's parent dir, and a deep tree would
# flatter it.
KEG="$PREFIX/Cellar/synth/1.0"
mkdir -p "$KEG/include"
i=0
while [[ $i -lt $LEAVES ]]; do
  : >"$KEG/include/h$i.h"
  i=$((i + 1))
done

sqlite3 "$DB" \
  "INSERT INTO kegs(name,full_name,version,store_sha256,cellar_path) \
   VALUES('synth','synth','1.0','deadbeef','$KEG');"

start=$(python3 -c 'import time; print(time.time())')
"$BIN" link synth >/dev/null 2>&1 || fail "malt link errored"
elapsed=$(python3 -c "import time; print(time.time() - $start)")

rows=$(sqlite3 "$DB" "SELECT count(*) FROM links;")
[[ "$rows" == "$LEAVES" ]] ||
  fail "linked $rows of $LEAVES leaves - the cost assertion below is meaningless"
pass "all $LEAVES leaves linked and recorded"

per_leaf=$(python3 -c "print('%.4f' % ($elapsed / $LEAVES * 1000))")
awk -v v="$per_leaf" -v c="$CEILING_MS" 'BEGIN { exit !(v > c) }' &&
  fail "link phase costs ${per_leaf} ms/leaf, ceiling ${CEILING_MS} ms/leaf"
pass "link phase costs ${per_leaf} ms/leaf (ceiling ${CEILING_MS})"

printf '\n✔ link-phase per-leaf cost regression passed\n'
