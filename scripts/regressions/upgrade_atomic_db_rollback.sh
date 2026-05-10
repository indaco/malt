#!/usr/bin/env bash
# Regression: `mt upgrade` rolls the DB back atomically when its kegs
# INSERT fails mid-flight, and surfaces the underlying SQLite category
# and message in the failure output.
#
# Pre-fix, the upgrade flow ran linker.unlink (DELETE FROM links) and
# recordKeg (INSERT INTO kegs) as separate implicit transactions with
# no outer wrapper. A failure of either produced a half-mutated DB
# (links gone, kegs row missing/wrong, or both) and a cryptic message:
#
#   ⚠ Could not remove old symlinks for <name>
#   ✗ Failed to record new version of <name> in database
#
# Cause: no atomic envelope; both call sites swallowed the typed
# `sqlite.SqliteError` so the user could not tell whether the failure
# was Busy, ExecFailed, ConstraintViolation, or something else.
#
# The fix wraps unlink → recordKeg → link → deleteKeg in a single
# `BEGIN IMMEDIATE`/`COMMIT`. On any failure inside, the txn rolls back
# (DB returns to pre-upgrade state) and the existing FS rollback
# rebuilds old symlinks + drops the new cellar dir. recordKeg now
# propagates the typed SqliteError, and the upgrade-side `output.err`
# calls include `@errorName(err)` and `db.errMsg()`.
#
# This script reproduces that contract end-to-end against three real
# zero-dep formulas. For each:
#   1. Install it via real `mt install`.
#   2. Rename its cellar dir to `<v>_99` and update kegs.revision +
#      cellar_path + links.target to match. This forces the upgrade
#      walker into a real attempt (revision 99 ≠ upstream 0) AND keeps
#      the old cellar dir at a path the rollback's `cellar_mod.remove`
#      will not target (which removes `<name>/<new_pkg_version>`).
#   3. Install a BEFORE INSERT trigger on `kegs` so recordKeg's INSERT
#      raises a deterministic SQLITE_CONSTRAINT_TRIGGER mapped to
#      ConstraintViolation. Trigger payload doubles as the errMsg
#      assertion target.
#   4. Run `mt upgrade <name>` and assert it exits non-zero with both
#      `ConstraintViolation` and the trigger message in stderr.
#   5. Drop the trigger and assert post-state: keg row + links count +
#      old cellar dir all bit-identical to the post-tamper snapshot.
#
# Usage: scripts/regressions/upgrade_atomic_db_rollback.sh
# Requirements: built `malt` at $MALT_BIN or zig-out/bin/malt,
# `sqlite3` on PATH, network access for the seeding install + the
# upgrade fetch (bottle download).

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

# MALT_PREFIX must be ≤ 13 bytes (Mach-O in-place patching budget).
PREFIX="/tmp/mt_atom"
export MALT_PREFIX="$PREFIX"
export NO_COLOR=1
export MALT_NO_EMOJI=1
rm -rf "$PREFIX"
mkdir -p "$PREFIX"
trap 'rm -rf "$PREFIX"' EXIT

pass() { printf '  \xe2\x9c\x93 %s\n' "$*"; }
fail() {
  printf '  \xe2\x9c\x97 %s\n' "$*" >&2
  exit 1
}

DB="$PREFIX/db/malt.db"

# Three zero-dep formulas — keeps the seed install in the seconds range
# while exercising the upgrade DB path on independent rows.
PACKAGES=(tree xz pkgconf)

INSTALL_LOG="$PREFIX/install.log"
printf '\xe2\x96\xb8 mt install %s (logs \xe2\x86\x92 %s)\n' "${PACKAGES[*]}" "$INSTALL_LOG"
"$BIN" install "${PACKAGES[@]}" >"$INSTALL_LOG" 2>&1 ||
  fail "seed install failed; see $INSTALL_LOG"
for P in "${PACKAGES[@]}"; do
  [[ -d "$PREFIX/Cellar/$P" ]] || fail "$P not in cellar after seed install"
done
pass "seeded ${#PACKAGES[@]} formulas"

# --- Per-package: tamper, force-fail, assert rollback ------------------
for P in "${PACKAGES[@]}"; do
  printf '\xe2\x96\xb8 %s\n' "$P"

  # 1. Sniff the actual installed version (whatever Homebrew shipped on
  #    the day this CI runs) and stash the cellar at `<v>_99`. The 99
  #    revision suffix decouples old_pkg_version from formula.pkg_version
  #    so the rollback's `cellar_mod.remove` (`<name>/<new_pkg_version>`)
  #    never targets the dir we want preserved.
  INSTALLED_DIR=$(find "$PREFIX/Cellar/$P" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1)
  [[ -n "$INSTALLED_DIR" ]] || fail "no version dir under $PREFIX/Cellar/$P"
  INSTALLED_VER=$(basename "$INSTALLED_DIR")
  STALE_VER="${INSTALLED_VER}_99"
  STALE_DIR="$PREFIX/Cellar/$P/$STALE_VER"
  mv "$INSTALLED_DIR" "$STALE_DIR" || fail "could not rename cellar dir for $P"

  # Drag the DB into agreement: bump revision to 99, repoint
  # cellar_path, and rewrite links.target so unlink and link both walk
  # the new dir. Use literal-substring REPLACE (the trailing slash
  # anchors the match) to avoid clobbering unrelated paths.
  sqlite3 "$DB" <<SQL || fail "could not retarget DB rows for $P"
UPDATE kegs
   SET revision=99,
       cellar_path='$STALE_DIR'
 WHERE name='$P';
UPDATE links
   SET target=REPLACE(target,
                      '/Cellar/$P/$INSTALLED_VER/',
                      '/Cellar/$P/$STALE_VER/')
 WHERE keg_id IN (SELECT id FROM kegs WHERE name='$P');
SQL

  # 2. Snapshot the post-tamper state. The rollback contract says
  #    these values must be bit-identical after the failed upgrade.
  PRE_KEG_ROW=$(sqlite3 -separator '|' "$DB" \
    "SELECT id, version, revision, store_sha256, cellar_path FROM kegs WHERE name='$P';")
  PRE_LINK_COUNT=$(sqlite3 "$DB" \
    "SELECT COUNT(*) FROM links l JOIN kegs k ON l.keg_id=k.id WHERE k.name='$P';")
  [[ -n "$PRE_KEG_ROW" ]] || fail "$P keg row vanished after tamper"

  # 3. Install a deterministic recordKeg-failure trigger. Scoped by
  #    `NEW.name` so unrelated INSERTs (none expected for these
  #    formulas, but cheap insurance) keep working.
  TRIG="block_${P//[^A-Za-z0-9]/_}_insert"
  TRIG_MSG="regression: forced recordKeg failure for $P"
  sqlite3 "$DB" "CREATE TRIGGER $TRIG BEFORE INSERT ON kegs WHEN NEW.name = '$P'
    BEGIN SELECT RAISE(ABORT, '$TRIG_MSG'); END;" ||
    fail "could not install $TRIG"

  # 4. Drive the upgrade. Must fail; stderr must name both the typed
  #    SqliteError category and the trigger message (the latter
  #    arrives via `db.errMsg()`).
  UPGRADE_LOG="$PREFIX/upgrade_$P.log"
  if "$BIN" upgrade "$P" >"$UPGRADE_LOG" 2>&1; then
    sqlite3 "$DB" "DROP TRIGGER IF EXISTS $TRIG;"
    fail "$P upgrade unexpectedly succeeded with trigger active; see $UPGRADE_LOG"
  fi

  grep -q "ConstraintViolation" "$UPGRADE_LOG" ||
    fail "$P upgrade error did not name ConstraintViolation; see $UPGRADE_LOG"
  grep -qF "$TRIG_MSG" "$UPGRADE_LOG" ||
    fail "$P upgrade error did not surface db.errMsg() trigger payload; see $UPGRADE_LOG"
  pass "$P upgrade error names SQLite category + message"

  # 5. Drop the trigger before the post-check so the eventual cleanup
  #    DELETEs don't trip an unrelated fire path.
  sqlite3 "$DB" "DROP TRIGGER IF EXISTS $TRIG;"

  POST_KEG_ROW=$(sqlite3 -separator '|' "$DB" \
    "SELECT id, version, revision, store_sha256, cellar_path FROM kegs WHERE name='$P';")
  POST_LINK_COUNT=$(sqlite3 "$DB" \
    "SELECT COUNT(*) FROM links l JOIN kegs k ON l.keg_id=k.id WHERE k.name='$P';")

  [[ "$POST_KEG_ROW" == "$PRE_KEG_ROW" ]] ||
    fail "$P keg row drifted across rollback:
       pre:  $PRE_KEG_ROW
       post: $POST_KEG_ROW"
  [[ "$POST_LINK_COUNT" == "$PRE_LINK_COUNT" ]] ||
    fail "$P link count drifted across rollback: $PRE_LINK_COUNT -> $POST_LINK_COUNT"

  # The recorded cellar_path must still exist on disk — the FS-side
  # rollback complement to the DB rollback proves the user-visible
  # state is fully consistent (old keg still resolvable).
  [[ -d "$STALE_DIR" ]] ||
    fail "$P old cellar dir missing after rollback: $STALE_DIR"
  pass "$P kegs+links+cellar preserved after rolled-back upgrade"
done

printf '\n\xe2\x9c\x94 upgrade-atomic-db-rollback regression passed\n'
