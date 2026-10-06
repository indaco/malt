#!/usr/bin/env bash
# Regression: a --dry-run preview never creates, initialises or migrates the
# install database.
#
# Pre-fix every mutating command opened db/malt.db read-write-create and ran
# initSchema before its dry-run gate, so a preview left a fresh malt.db behind
# and committed the migration chain to an older-schema DB in place.
#
# Behaviours pinned:
#   1. with db/ present and no malt.db, each preview leaves db/ without malt.db
#      (or its -wal/-shm sidecars)
#   2. on an older-schema DB, a preview leaves the file bytes and
#      max(schema_version) unchanged and creates no sidecars
#   3. on a prefix that does not exist yet, install and bundle previews
#      create nothing at all
#   4. control: a real (non-preview) run still creates the DB, so the
#      absences above are not vacuous
#
# Usage: scripts/regressions/dry-run-leaves-db-untouched-dry-run-creates-and-initialises-the-db.sh
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

T=$(mktemp -d /tmp/malt-dryrun-db.XXXXXX)
trap 'rm -rf "$T"' EXIT
export NO_COLOR=1
export MALT_NO_EMOJI=1
export MALT_OFFLINE=1

fail() {
  echo "FAIL $1" >&2
  exit 1
}

# Run `malt <argv>` against the prefix rooted at $1, from inside it so a
# would-be backup file cannot land in the repo.
run_in() {
  local dir=$1
  shift
  # shellcheck disable=SC2068 # word-split on purpose: argv is a flag list
  (cd "$dir" && MALT_PREFIX="$dir/p" MALT_CACHE="$dir/c" "$BIN" $@ >/dev/null 2>&1) || true
}

fresh() {
  local d
  d=$(mktemp -d "$T/x.XXXXXX")
  mkdir -p "$d/p/db" "$d/c"
  echo "$d"
}

previews=(
  "link --dry-run foo"
  "link --isolate --dry-run foo"
  "unlink --dry-run foo"
  "uninstall --dry-run foo"
  "upgrade --dry-run --offline foo"
  "rollback --dry-run foo"
  "install --dry-run --offline foo"
  "backup --dry-run"
)

for argv in "${previews[@]}"; do
  d=$(fresh)
  run_in "$d" "$argv"
  for f in malt.db malt.db-wal malt.db-shm; do
    [[ ! -e "$d/p/db/$f" ]] || fail "'$argv' created db/$f"
  done
done
echo "ok: previews on an empty db/ create no database"

for argv in "install --dry-run --offline foo" "bundle install --dry-run BF" \
  "bundle import --dry-run BF" "bundle create --dry-run out"; do
  d=$(mktemp -d "$T/x.XXXXXX")
  mkdir -p "$d/c"
  echo '# empty' >"$d/BF"
  run_in "$d" "$argv"
  [[ ! -e "$d/p" ]] || fail "'$argv' created the prefix: $(cd "$d" && find p | tr '\n' ' ')"
done
echo "ok: previews on a missing prefix create nothing"

d=$(fresh)
run_in "$d" "link foo"
[[ -e "$d/p/db/malt.db" ]] || fail "control: a real link did not create db/malt.db"
echo "ok: control real run creates the database"

d=$(fresh)
DB="$d/p/db/malt.db"
run_in "$d" "list"
current=$(sqlite3 "$DB" 'SELECT max(version) FROM schema_version')
# Fake an older DB: drop the newest migrations and restore the column v16 removes.
sqlite3 "$DB" "ALTER TABLE store_refs ADD COLUMN refcount INTEGER NOT NULL DEFAULT 0;
  DELETE FROM schema_version WHERE version>=16;"
before=$(shasum -a 256 "$DB")
for argv in "link --dry-run foo" "uninstall --dry-run foo" "upgrade --dry-run --offline foo"; do
  run_in "$d" "$argv"
  [[ "$(shasum -a 256 "$DB")" == "$before" ]] || fail "'$argv' rewrote an older-schema DB"
  [[ "$(sqlite3 "$DB" 'SELECT max(version) FROM schema_version')" == 15 ]] || fail "'$argv' migrated an older-schema DB"
  for f in malt.db-wal malt.db-shm; do
    [[ ! -e "$d/p/db/$f" ]] || fail "'$argv' left db/$f behind"
  done
done
echo "ok: previews leave an older-schema DB at v15 (current is v$current)"

echo "ok: dry runs leave the database untouched"
