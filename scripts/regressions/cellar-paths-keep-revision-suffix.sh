#!/usr/bin/env bash
# Regression: several DB-row -> filesystem-path builders used the raw
# `kegs.version` column, but the on-disk Cellar dir is named by
# pkg_version (`<version>_<revision>` when revision > 0). For a revisioned
# keg this means:
#   * `purge --unused-deps` targeted Cellar/<name>/<version> (no suffix),
#     so the real <version>_<revision> dir was left orphaned on disk;
#   * `link <name>` pointed opt/<name> at the suffix-less path, creating a
#     dangling symlink that breaks dyld at runtime.
#
# Both scenarios are seeded with a revisioned keg whose dir carries the
# `_<revision>` suffix. After the fix autoremove deletes the real dir and
# `link` produces a resolvable opt symlink.
#
# Exits 0 when the bug is absent, non-zero (with a clear message) when
# present. No network required; finishes well under 30s once built.

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

PREFIX="$(mktemp -d)/malt-prefix"
export MALT_PREFIX="$PREFIX"
trap 'rm -rf "$(dirname "$PREFIX")"' EXIT

pass() { printf '  ✓ %s\n' "$*"; }
fail() {
  printf '  ✗ %s\n' "$*" >&2
  exit 1
}

DB="$PREFIX/db/malt.db"
mkdir -p "$PREFIX/db"

# Init the schema once via a no-op purge on a Cellar-free prefix.
: >"$DB"
"$BIN" purge --unused-deps -y >/dev/null 2>&1 || true
sqlite3 "$DB" "SELECT revision FROM kegs LIMIT 1;" >/dev/null 2>&1 ||
  fail "schema init did not create the kegs table with a revision column"

# ── Scenario 1: autoremove must delete the revisioned dir ────────────
# Orphan dependency keg: version 0.22, revision 1 -> dir 0.22_1.
mkdir -p "$PREFIX/Cellar/gettext/0.22_1/lib"
sqlite3 "$DB" \
  "INSERT INTO kegs(name,full_name,version,revision,store_sha256,cellar_path,install_reason) \
   VALUES('gettext','gettext','0.22',1,'sha','$PREFIX/Cellar/gettext/0.22_1','dependency');"

"$BIN" purge --unused-deps -y >/dev/null 2>&1 || fail "purge --unused-deps errored"
[[ ! -d "$PREFIX/Cellar/gettext/0.22_1" ]] ||
  fail "revisioned orphan dir Cellar/gettext/0.22_1 not removed by autoremove"
pass "autoremove deleted the revisioned keg's dir"

# ── Scenario 2: link must point opt/<name> at the real dir ───────────
mkdir -p "$PREFIX/Cellar/jq/1.7_2/bin"
: >"$PREFIX/Cellar/jq/1.7_2/bin/jq"
sqlite3 "$DB" \
  "INSERT INTO kegs(name,full_name,version,revision,store_sha256,cellar_path,install_reason) \
   VALUES('jq','jq','1.7',2,'sha','$PREFIX/Cellar/jq/1.7_2','direct');"

"$BIN" link jq >/dev/null 2>&1 || fail "link jq errored"
[[ -L "$PREFIX/opt/jq" ]] || fail "opt/jq symlink not created"
[[ -e "$PREFIX/opt/jq" ]] || fail "opt/jq is dangling (points at a suffix-less path)"
TARGET=$(readlink "$PREFIX/opt/jq")
case "$TARGET" in
*/jq/1.7_2) pass "opt/jq resolves to the revisioned dir" ;;
*) fail "opt/jq points at '$TARGET', expected the 1.7_2 dir" ;;
esac

printf '\n✔ cellar-paths keep-revision-suffix regression passed\n'
