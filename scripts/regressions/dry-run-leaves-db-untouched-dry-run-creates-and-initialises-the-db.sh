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
#   2. on an older-schema DB, each preview leaves the file bytes and
#      max(schema_version) unchanged and creates no sidecars
#   3. on a prefix that does not exist yet, install and bundle previews
#      create nothing at all
#   4. every preview is paired with its real run, which must create or migrate
#      the DB, so a preview refused before it reaches the database cannot pass
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
# would-be backup or bundle file cannot land in the repo. Output goes to $1/out.
run_in() {
  local dir=$1
  shift
  # shellcheck disable=SC2068 # word-split on purpose: argv is a flag list
  (cd "$dir" && MALT_PREFIX="$dir/p" MALT_CACHE="$dir/c" "$BIN" $@ >"$dir/out" 2>&1 </dev/null) || true
}

# Fresh prefix with db/ but no malt.db; $2=v15 seeds an older-schema DB.
fresh() {
  local d
  d=$(mktemp -d "$T/x.XXXXXX")
  mkdir -p "$d/p/db" "$d/c"
  echo '# empty' >"$d/BF"
  if [[ "${1:-}" == v15 ]]; then
    run_in "$d" list
    # Drop the newest migrations and restore the column v16 removes.
    sqlite3 "$d/p/db/malt.db" "ALTER TABLE store_refs ADD COLUMN refcount INTEGER NOT NULL DEFAULT 0;
      DELETE FROM schema_version WHERE version>=16;"
  fi
  echo "$d"
}

version() { sqlite3 "$1/p/db/malt.db" 'SELECT max(version) FROM schema_version'; }

# "preview|control": the control is the same command for real.
pairs=(
  "link --dry-run foo|link foo"
  "link --isolate --dry-run foo|link --isolate foo"
  "unlink --dry-run foo|unlink foo"
  "uninstall --dry-run foo|uninstall foo"
  "upgrade --dry-run --offline foo|upgrade --offline foo"
  "rollback --dry-run foo|rollback foo"
  "install --dry-run --offline foo|install --offline foo"
  "backup --dry-run|backup"
  "tap --dry-run --offline x/y|tap --offline x/y"
  "untap --dry-run x/y|untap x/y"
  "doctor --dry-run|doctor"
  "doctor --fix --dry-run|doctor --fix"
  "purge --store-orphans --dry-run|purge --store-orphans"
  "purge --unused-deps --dry-run|purge --unused-deps"
  "purge --stale-casks --dry-run|purge --stale-casks"
  "purge --old-versions --dry-run|purge --old-versions --yes"
  "bundle install --dry-run BF|bundle install BF"
  "bundle import --dry-run BF|bundle import BF"
  "bundle create --dry-run out|bundle create out"
  "bundle cleanup --dry-run BF|bundle cleanup BF"
  "bundle remove --dry-run work|bundle remove work"
)

for pair in "${pairs[@]}"; do
  preview=${pair%%|*} control=${pair#*|}
  d=$(fresh)
  run_in "$d" "$control"
  [[ -e "$d/p/db/malt.db" ]] || fail "control '$control' never reached the database: $(cat "$d/out")"
  d=$(fresh)
  run_in "$d" "$preview"
  for f in malt.db malt.db-wal malt.db-shm; do
    [[ ! -e "$d/p/db/$f" ]] || fail "'$preview' created db/$f"
  done
done
echo "ok: previews on an empty db/ create no database"

# reinstall answers "not installed" on an empty db/ without opening it, so it
# only has something to migrate here.
pairs+=("reinstall --dry-run foo|reinstall foo")
for pair in "${pairs[@]}"; do
  preview=${pair%%|*} control=${pair#*|}
  d=$(fresh v15)
  run_in "$d" "$control"
  [[ "$(version "$d")" -gt 15 ]] || fail "control '$control' never migrated the database: $(cat "$d/out")"
  d=$(fresh v15)
  before=$(shasum -a 256 "$d/p/db/malt.db")
  run_in "$d" "$preview"
  [[ "$(shasum -a 256 "$d/p/db/malt.db")" == "$before" ]] || fail "'$preview' rewrote an older-schema DB"
  [[ "$(version "$d")" == 15 ]] || fail "'$preview' migrated an older-schema DB"
  for f in malt.db-wal malt.db-shm; do
    [[ ! -e "$d/p/db/$f" ]] || fail "'$preview' left db/$f behind"
  done
done
echo "ok: previews leave an older-schema DB at v15"

# `update --check` refuses offline before opening anything; its preview stops
# right after the schema step, so it needs no network to get there.
for seed in "" v15; do
  d=$(fresh $seed)
  before=$(shasum -a 256 "$d/p/db/malt.db" 2>/dev/null || true)
  (
    unset MALT_OFFLINE
    run_in "$d" "update --check --dry-run"
  )
  grep -q 'would refresh the outdated snapshot' "$d/out" || fail "update --check --dry-run never reached the database: $(cat "$d/out")"
  [[ "$(shasum -a 256 "$d/p/db/malt.db" 2>/dev/null || true)" == "$before" ]] || fail "update --check --dry-run changed the database (${seed:-empty db/})"
done
echo "ok: update --check --dry-run leaves the database untouched"

for argv in "install --dry-run --offline foo" "bundle install --dry-run BF" \
  "bundle import --dry-run BF" "bundle create --dry-run out"; do
  d=$(mktemp -d "$T/x.XXXXXX")
  mkdir -p "$d/c"
  echo '# empty' >"$d/BF"
  run_in "$d" "$argv"
  [[ ! -e "$d/p" ]] || fail "'$argv' created the prefix: $(cd "$d" && find p | tr '\n' ' ')"
done
echo "ok: previews on a missing prefix create nothing"

echo "ok: dry runs leave the database untouched"
