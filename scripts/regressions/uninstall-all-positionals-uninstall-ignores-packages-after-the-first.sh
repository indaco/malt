#!/usr/bin/env bash
# Regression: `mt uninstall a b ...` removes every named package, checking
# them all before removing any.
#
# Pre-fix only the first positional was kept: `mt uninstall jq yq` removed
# jq, never mentioned yq and exited 0, and an unknown second name was
# silently ignored.
#
# Behaviours pinned:
#   1. a two-name uninstall removes both kegs
#   2. a batch containing an unknown name exits non-zero and removes nothing
#   3. a batch containing its own dependent removes both
#   4. a dry-run batch previews every name and keeps them all
#   5. a malformed MALT_CACHE is refused before a formula ahead of a cask goes
#
# Usage: scripts/regressions/uninstall-all-positionals-uninstall-ignores-packages-after-the-first.sh
# Requirements: built `malt` at $MALT_BIN or zig-out/bin/malt, `sqlite3` on
# PATH. No network.

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

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export NO_COLOR=1
export MALT_NO_EMOJI=1
export MALT_OFFLINE=1
export MALT_CACHE="$T/cache"
export MALT_PREFIX="$T/p"
mkdir -p "$MALT_PREFIX/db" "$MALT_CACHE"
DB="$MALT_PREFIX/db/malt.db"

# First run creates the DB through initSchema; "not installed" is expected.
"$BIN" uninstall x >/dev/null 2>&1 || true

seed() {
  for n; do
    sqlite3 "$DB" "INSERT INTO kegs (name,full_name,version,revision,store_sha256,cellar_path)
      VALUES ('$n','$n','1.0',0,'$n','Cellar/$n/1.0');"
    mkdir -p "$MALT_PREFIX/Cellar/$n/1.0"
  done
}
count() { sqlite3 "$DB" "SELECT count(*) FROM kegs"; }
fail() {
  echo "FAIL $1" >&2
  cat "$T/out" >&2 || true
  exit 1
}

seed jq yq
"$BIN" uninstall jq yq >"$T/out" 2>&1 || fail "two-name uninstall exited non-zero"
[[ "$(count)" == 0 ]] || fail "uninstall jq yq left $(count) keg(s): later names ignored"
[[ ! -d "$MALT_PREFIX/Cellar/yq" ]] || fail "uninstall jq yq kept Cellar/yq"
echo "ok: two-name uninstall removed both"

seed yq
rc=0
"$BIN" uninstall yq nosuch >"$T/out" 2>&1 || rc=$?
[[ $rc -ne 0 ]] || fail "unknown name in the batch exited 0"
grep -q 'nosuch is not installed' "$T/out" || fail "unknown name not reported"
[[ "$(count)" == 1 ]] || fail "batch with an unknown name removed yq before aborting"
echo "ok: unknown name aborts the batch before any removal"

seed a b
sqlite3 "$DB" "INSERT INTO dependencies (keg_id,dep_name,dep_type)
  SELECT id,'a','runtime' FROM kegs WHERE name='b';"
rc=0
"$BIN" uninstall a >"$T/out" 2>&1 || rc=$?
[[ $rc -ne 0 ]] || fail "a alone was removed although b depends on it"
"$BIN" uninstall --dry-run yq a b >"$T/out" 2>&1 || fail "dry-run batch exited non-zero"
[[ "$(grep -c 'would uninstall' "$T/out")" == 3 ]] || fail "dry-run batch did not preview every name"
[[ "$(count)" == 3 ]] || fail "dry-run batch removed a package"
echo "ok: dry-run batch previews every name and keeps them"

"$BIN" uninstall yq a b >"$T/out" 2>&1 || fail "batch refused a although its dependent b is in the batch"
[[ "$(count)" == 0 ]] || fail "batch with an internal dependent left $(count) keg(s)"
echo "ok: batch containing its own dependent removed both"

seed jq
sqlite3 "$DB" "INSERT INTO casks (token,name,version,url)
  VALUES ('foo','foo','1.0','https://example.invalid/foo.zip');"
rc=0
MALT_CACHE=relative/cache "$BIN" uninstall jq foo >"$T/out" 2>&1 || rc=$?
[[ $rc -eq 78 ]] || fail "malformed MALT_CACHE: exit $rc, expected 78"
[[ "$(count)" == 1 ]] || fail "malformed MALT_CACHE: jq removed before the cask's cache was checked"
echo "ok: malformed MALT_CACHE refused before any removal"

echo "ok: uninstall removes every named package"
