#!/usr/bin/env bash
# Regression: `malt install <tap/formula> --force` must run the
# same three-phase cleanup (pre-materialize cellar wipe, post-
# materialize unlink + stale-row drop + orphan-dir sweep) as the
# JSON-pipeline path. Pre-fix, `materializeRubyFormula` ignored
# the force flag beyond the "already installed" skip-suppression,
# so:
#   - same-version --force could trip the linker's atomic-replace
#     fallback (no checkConflicts, but stale state could linger)
#   - revision/version bumps left the old keg + row on disk and
#     in the DB, surfacing as doctor "Relocation placeholders" later
#
# Drives the regression against the known-working `indaco/tap/sley`
# fixture (also used by `install_tap_tmp_cleanup.sh`).
#
# Usage: scripts/regressions/install_force_sweeps_tap.sh
# Requirements: built malt at $MALT_BIN or zig-out/bin/malt;
# network access to api.github.com / raw.githubusercontent.com.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BIN="${MALT_BIN:-$ROOT/zig-out/bin/malt}"
[[ -x "$BIN" ]] || {
  echo "build malt first: zig build" >&2
  exit 2
}

PREFIX=$(mktemp -d /tmp/mt.XXX)
export MALT_PREFIX="$PREFIX"
export NO_COLOR=1
export MALT_NO_EMOJI=1
mkdir -p "$PREFIX"
trap 'rm -rf "$PREFIX"' EXIT

pass() { printf '  ✓ %s\n' "$*"; }
skip() {
  printf '  - %s\n' "$*"
  exit 0
}
fail() {
  printf '  ✗ %s\n' "$*" >&2
  exit 1
}

SLUG="indaco/tap/sley"
NAME="sley"

# ── 1. Initial install via materializeRubyFormula ───────────────────
printf '▸ malt install %s (seed)\n' "$SLUG"
LOG="$PREFIX/install.log"
"$BIN" install "$SLUG" >"$LOG" 2>&1 || true
if ! grep -qE "installed$| installed " "$LOG"; then
  if grep -qE "rate limit|Network failure|Tap formula/cask not found" "$LOG"; then
    skip "$SLUG: transient classified failure; cannot exercise force-sweep"
  fi
  tail -30 "$LOG" >&2
  fail "$SLUG: initial install neither succeeded nor produced a known transient error"
fi
pass "$SLUG: initial install succeeded"

DB="$PREFIX/db/malt.db"
[[ -f "$DB" ]] || fail "DB missing after initial install: $DB"

VER=$(sqlite3 "$DB" "SELECT version FROM kegs WHERE name = '$NAME';")
[[ -n "$VER" ]] || fail "no kegs row for $NAME after initial install"
KEG_DIR="$PREFIX/Cellar/$NAME/$VER"
[[ -d "$KEG_DIR" ]] || fail "$KEG_DIR missing after initial install"
pass "seeded $NAME $VER at $KEG_DIR"

# ── 2. Same-version --force must succeed (linker atomic-replace path) ─
printf '▸ malt install %s --force (same version)\n' "$SLUG"
FORCE_LOG="$PREFIX/force.log"
"$BIN" install "$SLUG" --force >"$FORCE_LOG" 2>&1 || {
  tail -30 "$FORCE_LOG" >&2
  fail "same-version --force failed"
}
pass "same-version --force succeeded"

[[ -d "$KEG_DIR" ]] || fail "$KEG_DIR missing after same-version force"
ROW_COUNT=$(sqlite3 "$DB" "SELECT COUNT(*) FROM kegs WHERE name = '$NAME';")
[[ "$ROW_COUNT" == "1" ]] || fail "expected 1 $NAME row, got $ROW_COUNT"
pass "post-force state has exactly one $NAME row + cellar dir"

# ── 3. Seed a stale sibling version (the orphan-keg shape) and force ─
STALE_VER="${VER}-pre"
STALE_DIR="$PREFIX/Cellar/$NAME/$STALE_VER"
mkdir -p "$STALE_DIR/bin"
: >"$STALE_DIR/bin/marker"
sqlite3 "$DB" "INSERT INTO kegs (name, full_name, version, store_sha256, cellar_path) VALUES ('$NAME', '$NAME', '$STALE_VER', '$(printf '%064d' 0)', '$STALE_DIR');"
pass "seeded stale sibling at $STALE_DIR + kegs row"

ROW_COUNT_BEFORE=$(sqlite3 "$DB" "SELECT COUNT(*) FROM kegs WHERE name = '$NAME';")
[[ "$ROW_COUNT_BEFORE" == "2" ]] || fail "seed expected 2 rows, got $ROW_COUNT_BEFORE"

printf '▸ malt install %s --force (stale sibling present)\n' "$SLUG"
"$BIN" install "$SLUG" --force >"$FORCE_LOG" 2>&1 || {
  tail -30 "$FORCE_LOG" >&2
  fail "stale-sibling --force failed"
}
pass "stale-sibling --force succeeded"

[[ ! -d "$STALE_DIR" ]] || fail "$STALE_DIR survived --force — disk sweep missed the sibling"
pass "stale Cellar/$NAME/$STALE_VER swept"

ROW_COUNT_AFTER=$(sqlite3 "$DB" "SELECT COUNT(*) FROM kegs WHERE name = '$NAME';")
[[ "$ROW_COUNT_AFTER" == "1" ]] || fail "expected 1 $NAME row after sweep, got $ROW_COUNT_AFTER"
pass "stale kegs row dropped"

# ── 4. Doctor must be clean ──────────────────────────────────────────
DOCTOR_OUT=$("$BIN" doctor --verbose 2>&1 || true)
if echo "$DOCTOR_OUT" | grep -qE "keg\(s\) in DB but missing on disk"; then
  echo "$DOCTOR_OUT" >&2
  fail "doctor reports Missing kegs after tap-path force-sweep"
fi
if echo "$DOCTOR_OUT" | grep -qE "package\(s\) ship file\(s\) with unpatched @@HOMEBREW"; then
  echo "$DOCTOR_OUT" >&2
  fail "doctor reports relocation placeholders after tap-path force-sweep"
fi
pass "doctor reports no Missing kegs / placeholder offenders"

printf '\n✔ install-force-sweeps-tap regression passed\n'
