#!/usr/bin/env bash
# Regression: a successful `mt uninstall` removes exactly its own entry from
# `{cache}/outdated.json` and nothing else.
#
# `mt outdated` refutes a row-less entry against the DB before printing, but
# the TUI warm paint reads the file raw. Pre-fix, uninstall committed the keg
# row delete and returned without touching the file, so the removed keg kept
# its entry (and its Outdated-tab row) until the TTL lapsed:
#
#   $ mt uninstall wget     # row gone
#   $ cat outdated.json     # still names wget 1.20 ≠ 1.22
#
# Deleting the whole file would fix the lie at the cost of every other keg's
# valid audit, so the fix edits the one entry in place and keeps the lease.
#
# Behaviours pinned, all hermetic (MALT_OFFLINE=1, assert on the file):
#   1. An aborted uninstall (package not installed) leaves the file alone.
#   2. A real uninstall drops only its own formula entry: the sibling
#      formula, the cask array and `generated_at_ms` survive.
#   3. The CLI reader agrees with the file: neither names the removed keg.
#
# Usage: scripts/regressions/uninstall-reconciles-outdated-snapshot-outdated-snapshot-targeted-mutation.sh
# Requirements: built `malt` at $MALT_BIN or zig-out/bin/malt,
# `sqlite3` and `jq` on PATH. No network.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BIN="${MALT_BIN:-$ROOT/zig-out/bin/malt}"
[[ -x "$BIN" ]] || {
  echo "build malt first: zig build" >&2
  exit 2
}
for tool in sqlite3 jq; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "this regression needs $tool on PATH" >&2
    exit 2
  }
done

PREFIX="/tmp/mt_un_snapshot_$$"
export MALT_PREFIX="$PREFIX"
export MALT_CACHE="$PREFIX/cache"
export NO_COLOR=1
export MALT_NO_EMOJI=1
export MALT_OFFLINE=1
unset MALT_OUTDATED_MAX_AGE
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

# wget gets a real Cellar tree + bin symlink so the teardown has something
# to walk; jq only needs its row to stay recorded.
KEG="$PREFIX/Cellar/wget/1.20"
mkdir -p "$KEG/bin" "$PREFIX/bin"
printf '#!/bin/sh\n' >"$KEG/bin/wget"
chmod +x "$KEG/bin/wget"
ln -s "$KEG/bin/wget" "$PREFIX/bin/wget"

sqlite3 "$DB" <<SQL
INSERT INTO kegs (name, full_name, version, revision, store_sha256, cellar_path, install_reason)
VALUES ('wget', 'wget', '1.20', 0, 'sha_wget', '$KEG', 'direct');
INSERT INTO links (keg_id, link_path, target)
VALUES (last_insert_rowid(), '$PREFIX/bin/wget', '$KEG/bin/wget');
INSERT INTO kegs (name, full_name, version, revision, store_sha256, cellar_path, install_reason)
VALUES ('jq', 'jq', '1.7', 0, 'sha_jq', '$PREFIX/Cellar/jq/1.7', 'direct');
SQL

# A fresh snapshot naming both kegs plus a cask, so the edit has neighbours
# that must survive it.
G=$(($(date +%s) * 1000))
printf '{"version":2,"generated_at_ms":%s,"formulas":[{"name":"wget","installed":"1.20","latest":"1.22"},{"name":"jq","installed":"1.7","latest":"1.8"}],"casks":[{"name":"foo","installed":"1","latest":"2"}]}' \
  "$G" >"$SNAP"
before=$(shasum "$SNAP")

# (1) an uninstall that changes nothing must leave the cache alone.
"$BIN" uninstall nope >/dev/null 2>&1 && inconclusive "uninstalling an absent package succeeded"
[[ "$(shasum "$SNAP")" == "$before" ]] || fail "aborted uninstall rewrote the snapshot"
pass "aborted uninstall leaves the snapshot untouched"

# (2) a real uninstall drops only wget.
"$BIN" uninstall wget >/dev/null 2>&1 || inconclusive "uninstall exited non-zero — the seed is broken"
[[ -f "$SNAP" ]] || fail "uninstall deleted the whole snapshot instead of dropping one entry"
jq -e '.formulas | map(.name) == ["jq"]' "$SNAP" >/dev/null ||
  fail "outdated.json still names the uninstalled keg (or lost jq): $(cat "$SNAP")"
jq -e '.casks | length == 1' "$SNAP" >/dev/null || fail "the casks array did not survive a formula uninstall"
jq -e ".generated_at_ms == $G" "$SNAP" >/dev/null || fail "uninstall re-stamped the snapshot lease"
pass "uninstall drops only its own entry and keeps the lease"

# (3) reader agreement: the CLI must not list wget either.
"$BIN" outdated 2>/dev/null | grep -q wget && fail "mt outdated lists an uninstalled keg"
pass "mt outdated agrees with the reconciled file"

echo "uninstall reconciles the outdated snapshot: OK"
