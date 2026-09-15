#!/usr/bin/env bash
# Regression: a successful `mt rollback` invalidates `{cache}/outdated.json`.
#
# `mt outdated` (and the TUI Outdated tab, which runs the same command) serve
# a present, fresh snapshot without re-auditing. Pre-fix, rollback committed a
# downgrade and returned without touching the file, so a keg it had just moved
# below current stayed invisible to `mt outdated` until the TTL lapsed:
#
#   $ mt rollback wget      # wget rolled back to 1.20
#   $ mt outdated           # all clear — served from the pre-rollback snapshot
#
# `pruneSnapshot` (what `mt upgrade` calls) cannot fix this: it only drops
# entries, and a keg that was current when the snapshot was warmed has no
# entry to drop. With no fresh cached formula to say what current is (the
# case here), only deleting the file forces the next reader to re-audit.
#
# Two behaviours pinned, both hermetic (assert on the file, never on
# `mt outdated`, which would re-audit over HTTP once the file is gone):
#   1. `mt rollback --dry-run` changes nothing, so the snapshot stays
#      byte-identical.
#   2. A real `mt rollback` on a cold API cache removes the snapshot.
#
# Usage: scripts/regressions/rollback-invalidates-outdated-snapshot-rollback-never-invalidates-outdated-snapshot.sh
# Requirements: built `malt` at $MALT_BIN or zig-out/bin/malt,
# `sqlite3` on PATH. No network.

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

PREFIX="/tmp/mt_rb_snapshot_$$"
export MALT_PREFIX="$PREFIX"
export MALT_CACHE="$PREFIX/cache"
export NO_COLOR=1
export MALT_NO_EMOJI=1
unset MALT_OFFLINE MALT_OUTDATED_MAX_AGE
rm -rf "$PREFIX"
mkdir -p "$PREFIX/db" "$MALT_CACHE"
trap 'rm -rf "$PREFIX"' EXIT

pass() { printf '  \xe2\x9c\x93 %s\n' "$*"; }
fail() {
  printf '  \xe2\x9c\x97 %s\n' "$*" >&2
  exit 1
}
inconclusive() {
  printf '  ? %s\n' "$*" >&2
  exit 2
}

DB="$PREFIX/db/malt.db"
SNAP="$MALT_CACHE/outdated.json"

# Bootstrap the schema by letting malt open the DB once.
"$BIN" list --quiet >/dev/null 2>&1 || true
[[ -f "$DB" ]] || inconclusive "DB was not initialised by mt list"

# Seed a real installation of wget 1.22: Cellar tree, bin/ symlink, and
# the kegs + links rows that the swap walks.
KEG="$PREFIX/Cellar/wget/1.22"
mkdir -p "$KEG/bin" "$PREFIX/bin"
printf '#!/bin/sh\n' >"$KEG/bin/wget"
chmod +x "$KEG/bin/wget"
ln -s "$KEG/bin/wget" "$PREFIX/bin/wget"

sqlite3 "$DB" <<SQL
INSERT INTO kegs (name, full_name, version, revision, store_sha256, cellar_path, install_reason)
VALUES ('wget', 'wget', '1.22', 0, 'sha_cur', '$KEG', 'direct');
INSERT INTO links (keg_id, link_path, target)
VALUES (last_insert_rowid(), '$PREFIX/bin/wget', '$KEG/bin/wget');
SQL

# Seed a readable rollback target so materialize has something to copy.
# The store key must be a well-formed sha256 or materialize refuses it.
OLD="$PREFIX/store/$(printf "5e%.0s" {1..32})/wget/1.20"
mkdir -p "$OLD/bin"
printf '{}' >"$OLD/INSTALL_RECEIPT.json"
printf '#!/bin/sh\n' >"$OLD/bin/wget"
chmod +x "$OLD/bin/wget"

# A fresh "nothing outdated" snapshot: exactly what a reader serves as-is.
seed_fresh_snapshot() {
  printf '{"version":2,"generated_at_ms":%s,"formulas":[],"casks":[]}' \
    "$(($(date +%s) * 1000))" >"$SNAP"
}

# (1) a rollback that changes nothing must leave the cache alone.
seed_fresh_snapshot
before=$(shasum "$SNAP")
"$BIN" rollback --dry-run wget >/dev/null 2>&1 ||
  inconclusive "dry-run rollback exited non-zero"
[[ -e "$SNAP" ]] || fail "dry-run rollback deleted outdated.json"
[[ "$(shasum "$SNAP")" == "$before" ]] || fail "dry-run rollback rewrote outdated.json"
pass "dry-run rollback leaves the snapshot untouched"

# (2) a real rollback must invalidate it.
"$BIN" rollback wget >/dev/null 2>&1 ||
  inconclusive "rollback exited non-zero — the seed is broken"
[[ ! -e "$SNAP" ]] ||
  fail "outdated.json survived a successful rollback: mt outdated will serve the pre-rollback set until the TTL"
pass "successful rollback removes the snapshot"

echo "rollback invalidates the outdated snapshot: OK"
