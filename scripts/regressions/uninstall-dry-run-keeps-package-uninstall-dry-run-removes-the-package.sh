#!/usr/bin/env bash
# Regression: `mt uninstall --dry-run` previews the removal and keeps the
# package, for both a formula and a cask.
#
# Pre-fix the global --dry-run flag was never consulted by uninstall, so a
# preview stopped services, deleted the DB row and removed the Cellar /
# Caskroom entry, then printed "uninstalled" and exited 0.
#
# Behaviours pinned:
#   1. dry-run formula -> rc 0, "would uninstall" printed, row + Cellar intact
#   2. dry-run cask    -> rc 0, "would uninstall" printed, row + Caskroom intact
#   3. a mistyped preview (-n, a --dry-run after --) is refused, not run
#   4. a malformed MALT_CACHE fails the cask preview as it fails the real run
#   5. control: a real uninstall of the same fixture removes the keg row, so
#      the survivals above are not vacuous
#
# Usage: scripts/regressions/uninstall-dry-run-keeps-package-uninstall-dry-run-removes-the-package.sh
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

sqlite3 "$DB" "INSERT INTO kegs (name,full_name,version,revision,store_sha256,cellar_path)
  VALUES ('yq','yq','1.0',0,'yq','Cellar/yq/1.0');
  INSERT INTO casks (token,name,version,url)
  VALUES ('foo','foo','1.0','https://example.invalid/foo.zip');"
mkdir -p "$MALT_PREFIX/Cellar/yq/1.0" "$MALT_PREFIX/Caskroom/foo/1.0"

fail() {
  echo "FAIL $1" >&2
  cat "$T/out" >&2 || true
  exit 1
}

for pkg in yq foo; do
  rc=0
  "$BIN" uninstall --dry-run "$pkg" >"$T/out" 2>&1 || rc=$?
  [[ $rc -eq 0 ]] || fail "dry-run $pkg: exit $rc"
  grep -q 'would uninstall' "$T/out" || fail "dry-run $pkg: no preview line"
  if grep -q 'uninstalled' "$T/out"; then fail "dry-run $pkg: reported a real removal"; fi
  echo "ok: dry-run $pkg output"
done

[[ "$(sqlite3 "$DB" "SELECT count(*) FROM kegs WHERE name='yq'")" == 1 ]] || fail "dry-run deleted the keg row"
[[ "$(sqlite3 "$DB" "SELECT count(*) FROM casks WHERE token='foo'")" == 1 ]] || fail "dry-run deleted the cask row"
[[ -d "$MALT_PREFIX/Cellar/yq/1.0" ]] || fail "dry-run removed the Cellar entry"
[[ -d "$MALT_PREFIX/Caskroom/foo/1.0" ]] || fail "dry-run removed the Caskroom entry"
echo "ok: dry-run kept both packages"

for argv in "-n yq" "yq -- --dry-run"; do
  rc=0
  # shellcheck disable=SC2086 # word-split on purpose: argv is a flag list
  "$BIN" uninstall $argv >"$T/out" 2>&1 || rc=$?
  [[ $rc -ne 0 ]] || fail "'$argv': exit 0"
  [[ "$(sqlite3 "$DB" "SELECT count(*) FROM kegs WHERE name='yq'")" == 1 ]] || fail "'$argv': removed the keg"
done
echo "ok: mistyped previews refused"

rc=0
MALT_CACHE=relative/cache "$BIN" uninstall --dry-run foo >"$T/out" 2>&1 || rc=$?
[[ $rc -eq 78 ]] || fail "malformed MALT_CACHE: cask preview exit $rc, real run exits 78"
echo "ok: cask preview refuses a malformed MALT_CACHE"

"$BIN" uninstall yq >"$T/out" 2>&1 || fail "control: real uninstall failed"
[[ "$(sqlite3 "$DB" "SELECT count(*) FROM kegs WHERE name='yq'")" == 0 ]] || fail "control: real uninstall kept yq"
echo "ok: control uninstall removed yq"

echo "ok: uninstall --dry-run keeps the package"
