#!/usr/bin/env bash
# Regression: `mt upgrade` on a same-version revision-bump.
#
# Up to v0.10.1, an upgrade where Homebrew bumped only the formula's
# revision suffix (e.g. libgit2 1.9.2 → 1.9.2_2, python@3.14 3.14.4 →
# 3.14.4_1) failed inside recordKeg with:
#
#   ✗ Failed to record new version of <name> in database
#
# Cause: the kegs table carried `UNIQUE(name, version)`, and
# upgradeFormula INSERTs the new keg row before deleting the old, so
# two rows with the same upstream `version` collided. The old row
# stayed put, the upgrade silently rolled back, and the same two
# packages re-appeared as outdated on every subsequent `mt upgrade`.
#
# The fix is schema migration v4 → v5, which broadens the UNIQUE to
# `UNIQUE(name, version, revision)`. This script verifies the migration
# landed AND that the new constraint accepts the bug's exact data
# pattern while still rejecting genuine duplicates.
#
# Usage: scripts/regressions/upgrade_revision_bump.sh
# Requirements: built `malt` binary at $MALT_BIN or zig-out/bin/malt,
# `sqlite3` on PATH, network access for the seeding install.

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

PREFIX="/tmp/mt_revb"
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

# Light formula: pulls no deps, lands fast, just enough to materialise
# a malt prefix with an initialised DB so the migration ladder runs.
SEED="${SEED:-tree}"
DB="$PREFIX/db/malt.db"

# --- 1. Seed a real malt install so the DB exists and migrations ran ---
printf '\xe2\x96\xb8 seeding prefix with mt install %s\n' "$SEED"
"$BIN" install "$SEED" >"$PREFIX/install.log" 2>&1 ||
  fail "seed install of $SEED failed — see $PREFIX/install.log"
pass "$SEED installed"

[[ -f "$DB" ]] || fail "expected DB at $DB after install"

# --- 2. schema_version reached v5 -------------------------------------
# The contract this regression locks down is the v4→v5 broaden-UNIQUE
# migration. Later schema bumps keep that migration in place, so any
# version ≥ 5 satisfies it. Pinning to a single value goes stale on
# every bump and masks real regressions in this gate.
SCHEMA_VER=$(sqlite3 "$DB" "SELECT MAX(version) FROM schema_version;")
[[ "$SCHEMA_VER" =~ ^[0-9]+$ && "$SCHEMA_VER" -ge 5 ]] ||
  fail "schema_version is $SCHEMA_VER, expected ≥5 (v4→v5 migration did not run)"
pass "schema_version = $SCHEMA_VER (≥5)"

# --- 3. kegs table carries the broadened UNIQUE -----------------------
# The UNIQUE shape is preserved verbatim in sqlite_master.sql by SQLite,
# so a substring probe is exact.
KEGS_SQL=$(sqlite3 "$DB" "SELECT sql FROM sqlite_master WHERE type='table' AND name='kegs';")
echo "$KEGS_SQL" | grep -q "UNIQUE(name, version, revision)" ||
  fail "kegs UNIQUE shape is not (name, version, revision); got:\n$KEGS_SQL"
pass "kegs UNIQUE = (name, version, revision)"

# Negative: the old (name, version) two-column shape must NOT linger.
# The trailing `[^,]` rules out a substring match against the new
# three-column shape `UNIQUE(name, version, revision)`.
if echo "$KEGS_SQL" | grep -qE "UNIQUE\(name, version\)[^,]"; then
  fail "kegs still carries old UNIQUE(name, version); migration was a no-op"
fi
pass "old UNIQUE(name, version) is gone"

# --- 4. The exact bug pattern now succeeds -----------------------------
# Replay the libgit2 1.9.2 → 1.9.2_2 case directly: two rows with the
# same upstream version, different revisions, must coexist briefly
# (this is what upgradeFormula's "INSERT new, then DELETE old" needs).
sqlite3 "$DB" <<'SQL' || fail "INSERT pair for revision-bump rejected"
INSERT INTO kegs (name, full_name, version, revision, store_sha256, cellar_path)
VALUES ('regtest_libgit2', 'regtest_libgit2', '1.9.2', 0, 'sha-old', '/tmp/c/regtest_libgit2/1.9.2');
INSERT INTO kegs (name, full_name, version, revision, store_sha256, cellar_path)
VALUES ('regtest_libgit2', 'regtest_libgit2', '1.9.2', 2, 'sha-new', '/tmp/c/regtest_libgit2/1.9.2_2');
SQL
pass "two rows with same name+version, different revisions, coexist"

# --- 5. Exact (name, version, revision) duplicate is still rejected ---
DUP_OUT=$(
  sqlite3 "$DB" <<'SQL' 2>&1 || true
INSERT INTO kegs (name, full_name, version, revision, store_sha256, cellar_path)
VALUES ('regtest_libgit2', 'regtest_libgit2', '1.9.2', 2, 'sha-dup', '/tmp/c/regtest_libgit2/dup');
SQL
)
echo "$DUP_OUT" | grep -qi "UNIQUE constraint failed" ||
  fail "exact (name, version, revision) duplicate slipped through; got: $DUP_OUT"
pass "exact (name, version, revision) duplicate rejected"

# Cleanup the synthetic rows so a subsequent `mt list` doesn't surface them.
sqlite3 "$DB" "DELETE FROM kegs WHERE name='regtest_libgit2';"

printf '\n\xe2\x9c\x94 upgrade-revision-bump regression passed\n'
