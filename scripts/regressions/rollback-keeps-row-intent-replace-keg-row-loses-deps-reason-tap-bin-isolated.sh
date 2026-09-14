#!/usr/bin/env bash
# Regression: a completed `mt rollback` keeps everything about the keg that
# is not the version being swapped.
#
# Pre-fix, the row swap was `DELETE FROM kegs` + `INSERT`: the delete cascaded
# the `dependencies` edges away and the insert re-bound only the columns it
# knew about, so `install_reason` became 'direct', `tap` and `bin_isolated`
# fell back to defaults, and the new keg was linked as if not isolated.
#
# Usage: scripts/regressions/rollback-keeps-row-intent-replace-keg-row-loses-deps-reason-tap-bin-isolated.sh
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

PREFIX="/tmp/mt_rb_row_intent_$$"
export MALT_PREFIX="$PREFIX"
export NO_COLOR=1
export MALT_NO_EMOJI=1
mkdir -p "$PREFIX/db"
trap 'rm -rf "$PREFIX"' EXIT

pass() { printf '  \xe2\x9c\x93 %s\n' "$*"; }
fail() {
  printf '  \xe2\x9c\x97 %s\n' "$*" >&2
  exit 1
}

DB="$PREFIX/db/malt.db"

# Bootstrap the schema by letting malt open the DB once.
"$BIN" list --quiet >/dev/null 2>&1 || true
[[ -f "$DB" ]] || fail "DB was not initialised by mt list"

# Seed a bin-isolated tap keg installed as a dependency, with two runtime
# edges - every column the old swap used to rewrite, set to a non-default.
KEG="$PREFIX/Cellar/wget/1.22"
mkdir -p "$KEG/bin" "$PREFIX/bin"
printf '#!/bin/sh\n' >"$KEG/bin/wget"
chmod +x "$KEG/bin/wget"

sqlite3 "$DB" <<SQL
INSERT INTO kegs (name, full_name, version, revision, store_sha256, cellar_path,
                  install_reason, bin_isolated, tap)
VALUES ('wget', 'someone/tap/wget', '1.22', 0, 'sha_cur', '$KEG',
        'dependency', 1, 'someone/tap');
INSERT INTO dependencies (keg_id, dep_name, dep_type)
VALUES ((SELECT id FROM kegs WHERE name = 'wget'), 'openssl@3', 'runtime'),
       ((SELECT id FROM kegs WHERE name = 'wget'), 'libidn2', 'runtime');
SQL

# Seed the rollback target with a binary, so a swap that forgets the
# isolation bit has something to link into bin/.
# Store keys must look like a sha256 or materialize refuses them.
OLD="$PREFIX/store/5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e/wget/1.20"
mkdir -p "$OLD/bin"
printf '{}\n' >"$OLD/INSTALL_RECEIPT.json"
printf '#!/bin/sh\n' >"$OLD/bin/wget"
chmod +x "$OLD/bin/wget"

"$BIN" rollback wget >/dev/null 2>&1 || fail "rollback did not complete"
pass "rollback completed"

col() { sqlite3 "$DB" "SELECT $1 FROM kegs WHERE name='wget';"; }
keep() {
  [[ "$(col "$1")" == "$2" ]] || fail "$1 is '$(col "$1")' (want $2)"
  pass "$1 is $2"
}

keep version 1.20
keep install_reason dependency
keep tap someone/tap
keep bin_isolated 1

DEPS=$(sqlite3 "$DB" "SELECT group_concat(dep_name, ',') FROM (SELECT d.dep_name FROM dependencies d JOIN kegs k ON k.id = d.keg_id WHERE k.name='wget' ORDER BY d.dep_name);")
[[ "$DEPS" == "libidn2,openssl@3" ]] ||
  fail "dependency edges changed to '$DEPS' (want libidn2,openssl@3)"
pass "dependency edges survived"

[[ ! -L "$PREFIX/bin/wget" && ! -e "$PREFIX/bin/wget" ]] ||
  fail "rollback linked bin/wget for a bin-isolated keg"
pass "bin/ left alone for the isolated keg"

echo "rollback keeps the keg's intent, tap and dependency edges: OK"
