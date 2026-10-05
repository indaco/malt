#!/usr/bin/env bash
# Regression: a bulk `mt upgrade` over an unreadable kegs or casks table
# reports the database failure and exits non-zero.
#
# Pre-fix, the audit's row-load error was mapped to an empty plan, so the run
# printed "No formulas installed." / "All casks are up to date." (nothing at
# all under --pinned), exited 0, and an unnarrowed --dry-run persisted an
# outdated.json listing nothing for the failed kind.
#
# A renamed column makes the row SELECT fail to prepare while the table still
# survives schema init - the same path a corrupt page or OOM takes.
#
# Usage: scripts/regressions/upgrade-unreadable-db-fails-loud-audit-failure-reported-as-no-formulas-installed.sh
# Requirements: built malt at $MALT_BIN or zig-out/bin/malt; sqlite3 on PATH.
# No network access required.

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

PREFIX=$(mktemp -d /tmp/mt.XXXXXX)
trap 'rm -rf "$PREFIX"' EXIT
export MALT_PREFIX="$PREFIX"
export MALT_CACHE="$PREFIX/cache"
export MALT_OFFLINE=1
export NO_COLOR=1

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# Empty the prefix in place; the mktemp dir itself stays ours.
reset() {
  rm -rf "${PREFIX:?}"/*
  mkdir -p "$PREFIX/db" "$MALT_CACHE"
}

# Fresh prefix with one row per kind; $1 is the SQL that drifts a table.
seed() {
  reset
  "$BIN" list >/dev/null
  sqlite3 "$PREFIX/db/malt.db" \
    "INSERT INTO kegs(name,full_name,version,store_sha256,cellar_path) VALUES('wget','wget','1.0','00','$PREFIX/Cellar/wget/1.0');" \
    "INSERT INTO casks(token,name,version,url) VALUES('box','Box','1.0','https://e/x.dmg');" \
    "$1"
}

# expect_loud <must-not-print> <args...>
expect_loud() {
  local empty=$1
  shift
  local out rc
  set +e
  out=$("$BIN" upgrade "$@" 2>&1)
  rc=$?
  set -e
  [[ $rc -ne 0 ]] || fail "upgrade $* exited 0 on an unreadable database"
  grep -q 'mt doctor' <<<"$out" || fail "upgrade $*: no unreadable-database diagnostic: $out"
  if grep -q "$empty" <<<"$out"; then fail "upgrade $*: reported '$empty'"; fi
}

seed "ALTER TABLE kegs RENAME COLUMN tap_rb_subtree TO tap_rb_subtree_x;"
expect_loud 'No formulas installed' --formula
expect_loud 'No formulas installed' --pinned --dry-run
expect_loud 'No formulas installed' --dry-run
[[ ! -e "$MALT_CACHE/outdated.json" ]] || fail "dry-run persisted a snapshot from a failed kegs audit"

seed "ALTER TABLE casks RENAME COLUMN pinned TO pinned_x;"
expect_loud 'All casks are up to date' --cask
expect_loud 'All casks are up to date' --dry-run
[[ ! -e "$MALT_CACHE/outdated.json" ]] || fail "dry-run persisted a snapshot from a failed casks audit"

# Control: a healthy empty prefix is still a clean no-op that warms the snapshot.
rm -rf "$PREFIX"
mkdir -p "$PREFIX/db" "$MALT_CACHE"
"$BIN" list >/dev/null
out=$("$BIN" upgrade --dry-run 2>&1) || fail "dry-run on a healthy empty prefix failed: $out"
grep -q 'No formulas installed' <<<"$out" || fail "healthy empty prefix lost its empty-install line"
[[ -e "$MALT_CACHE/outdated.json" ]] || fail "healthy empty dry-run no longer warms the snapshot"

echo "PASS: bulk upgrade reports an unreadable package database"
