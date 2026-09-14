#!/usr/bin/env bash
# Regression: `outdated.json` is only ever an all-clear when the database was
# actually read. Only an *absent* db/malt.db may look like "no rows"; any
# failure on a file that exists must be an error.
#
# The bug: `mt update --check` treated every `Database.open` failure as a
# fresh prefix and wrote an empty snapshot, and `loadKegRows` turned a failed
# `prepare` into zero rows. A corrupt DB, or a `kegs` table missing a column
# the SELECT names, therefore produced "Outdated snapshot refreshed." / "All
# packages are up to date." with rc 0 — and the persisted empty snapshot kept
# serving that false all-clear for the whole TTL, even after the DB was fixed.
#
# Three behaviours pinned, all hermetic (both failures short-circuit before
# any HTTP call; the fresh-prefix control has zero kegs to fetch):
#   1. Unopenable db/malt.db -> `update --check` exits non-zero, writes nothing.
#   2. kegs table missing a SELECTed column -> `outdated` and `update --check`
#      exit non-zero with the `mt doctor` diagnostic, write nothing.
#   3. db/ directory that cannot be looked into -> `update --check` exits
#      non-zero, writes nothing (skipped as root, who bypasses the perm wall).
#   4. A regular file where the db/ directory should be -> `update --check`
#      exits non-zero, writes nothing (ENOTDIR must not read as "absent").
#   5. Positive control: no db/ directory at all is a genuine fresh prefix ->
#      `update --check` still writes the empty snapshot with rc 0.
#
# Usage: scripts/regressions/outdated-snapshot-not-persisted-on-db-open-or-schema-failure-silent-db-degradation-persists-false-all-clear.sh
# Requirements: a built malt binary at $MALT_BIN or zig-out/bin/malt; sqlite3.
# No network access required.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BIN="${MALT_BIN:-$ROOT/zig-out/bin/malt}"
[[ -x "$BIN" ]] || {
  echo "build malt first: zig build" >&2
  exit 2
}
command -v sqlite3 >/dev/null || {
  echo "sqlite3 is required" >&2
  exit 2
}

PREFIX=$(mktemp -d -t malt_db_degradation.XXXXXX)
trap 'rm -rf "$PREFIX"' EXIT
export MALT_PREFIX="$PREFIX"
export MALT_CACHE="$PREFIX/cache"
unset MALT_OFFLINE MALT_OUTDATED_MAX_AGE NO_COLOR CI

SNAP="$MALT_CACHE/outdated.json"
DB="$PREFIX/db/malt.db"

pass() { printf '  \xe2\x9c\x93 %s\n' "$*"; }
fail() {
  printf '  \xe2\x9c\x97 %s\n' "$*" >&2
  exit 1
}

# Initialise the schema, then seed one keg so "zero rows" is never the truth.
mkdir -p "$PREFIX/db" "$MALT_CACHE/api"
"$BIN" list >/dev/null 2>&1 || true
sqlite3 "$DB" "INSERT INTO kegs (name, full_name, version, revision, store_sha256, cellar_path)
  VALUES ('behind_row', 'behind_row', '1.0', 0, 'x', '/tmp/c/behind_row/1.0');"
cp "$DB" "$PREFIX/db.bak"

# (1) Unopenable DB: a garbage header rather than chmod 000, so the check
# also holds when run as root.
printf 'not a sqlite header\n' >"$DB"
if out=$("$BIN" update --check 2>&1); then
  fail "update --check exited 0 on an unopenable DB: $out"
fi
[[ -e "$SNAP" ]] && fail "unopenable DB persisted a snapshot: $(cat "$SNAP")"
pass "unopenable DB refuses update --check and writes no snapshot"

# (2) Schema drift under a current version marker: initSchema passes
# (CREATE TABLE IF NOT EXISTS never checks columns), the SELECT does not.
cp "$PREFIX/db.bak" "$DB"
sqlite3 "$DB" "ALTER TABLE kegs RENAME COLUMN pinned TO pinned_x;"
if out=$(MALT_OFFLINE=1 "$BIN" outdated 2>&1); then
  fail "outdated exited 0 on a drifted kegs table: $out"
fi
grep -q 'All packages are up to date' <<<"$out" && fail "drifted DB reported all-clear: $out"
grep -q 'mt doctor' <<<"$out" || fail "drifted DB diagnostic missing: $out"
[[ -e "$SNAP" ]] && fail "drifted DB persisted a snapshot via outdated: $(cat "$SNAP")"
if out=$("$BIN" update --check 2>&1); then
  fail "update --check exited 0 on a drifted kegs table: $out"
fi
grep -q 'mt doctor' <<<"$out" || fail "update --check diagnostic missing: $out"
[[ -e "$SNAP" ]] && fail "drifted DB persisted a snapshot via update --check: $(cat "$SNAP")"
pass "drifted kegs table refuses outdated and update --check, writes no snapshot"

# (3) An unreadable db/ directory is not "nothing installed" either.
if [[ $EUID -ne 0 ]]; then
  chmod 000 "$PREFIX/db"
  if out=$("$BIN" update --check 2>&1); then
    chmod 755 "$PREFIX/db"
    fail "update --check exited 0 on an unreadable db/ directory: $out"
  fi
  chmod 755 "$PREFIX/db"
  [[ -e "$SNAP" ]] && fail "unreadable db/ persisted a snapshot: $(cat "$SNAP")"
  pass "unreadable db/ directory refuses update --check and writes no snapshot"
fi

# (4) A stray file in place of db/ is not "nothing installed" either.
rm -rf "$PREFIX/db"
printf 'x\n' >"$PREFIX/db"
if out=$("$BIN" update --check 2>&1); then
  fail "update --check exited 0 with a file in place of db/: $out"
fi
[[ -e "$SNAP" ]] && fail "stray db file persisted a snapshot: $(cat "$SNAP")"
pass "file in place of db/ refuses update --check and writes no snapshot"

# (5) Positive control: no db/ directory is a genuine fresh prefix.
rm -rf "$PREFIX/db"
"$BIN" update --check >/dev/null 2>&1 || fail "fresh prefix refused update --check"
[[ -e "$SNAP" ]] || fail "fresh prefix did not write the empty snapshot"
pass "fresh prefix still writes the empty snapshot"

echo "ok"
