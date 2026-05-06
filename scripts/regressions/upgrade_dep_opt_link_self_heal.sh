#!/usr/bin/env bash
# Regression: `mt upgrade` self-heals a transitive dep whose opt link
# was wiped from disk.
#
# Pre-fix, `collectMissingDepNames` consulted the DB only via
# `isFormulaInstalled`, so a dep with a healthy `kegs` row but a
# missing `opt/<name>` symlink was reported as installed. The upgrade
# walker skipped it and the new bottle linked dylibs that still
# pointed at a dead symlink. The install path's `deps.resolve` used
# the strict probe (cellar dir + opt link) and would have queued a
# re-link — the asymmetry meant `mt install` self-healed but
# `mt upgrade` did not.
#
# This script reproduces the asymmetry end-to-end:
#   1. Install a real formula with a transitive dep (`jq` + `oniguruma`).
#   2. Synthesize a stale version on the top-level row so the upgrade
#      walker actually runs (versions match → short-circuit, no dep walk).
#   3. Wipe `$PREFIX/opt/oniguruma` while leaving the cellar dir and
#      DB row intact — the exact pre-fix invisible-rot state.
#   4. Run `mt upgrade jq` and assert the opt link is rebuilt and
#      resolves into the oniguruma cellar.
#
# Usage: scripts/regressions/upgrade_dep_opt_link_self_heal.sh
# Requirements: built malt at $MALT_BIN or zig-out/bin/malt, sqlite3
# on PATH, network access for the seeding install + upgrade fetch.

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

# MALT_PREFIX must be <= 13 bytes (Mach-O in-place patching budget).
PREFIX="/tmp/mt_n9"
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

# `jq` carries exactly one runtime dep (`oniguruma`) and ships small
# bottles for both arches — keeps the network/disk cost of this
# regression in the seconds range.
TOP="jq"
DEP="oniguruma"
DB="$PREFIX/db/malt.db"

# --- 1. Seed a real install so both kegs land on disk -----------------
INSTALL_LOG="$PREFIX/install.log"
printf '\xe2\x96\xb8 mt install %s (logs \xe2\x86\x92 %s)\n' "$TOP" "$INSTALL_LOG"
"$BIN" install "$TOP" >"$INSTALL_LOG" 2>&1 ||
  fail "seed install of $TOP failed; see $INSTALL_LOG"
pass "$TOP + $DEP installed"

# Sanity: both opt links must exist before we start tampering.
[[ -L "$PREFIX/opt/$TOP" ]] || fail "$PREFIX/opt/$TOP missing after install"
[[ -L "$PREFIX/opt/$DEP" ]] || fail "$PREFIX/opt/$DEP missing after install"

# --- 2. Synthesise an outdated version on the top-level row -----------
# The upgrade walker short-circuits when installed pkg_version matches
# upstream's; lying on `version` forces it to take the dep-walk branch
# regardless of where Homebrew's stable jq actually sits today.
sqlite3 "$DB" \
  "UPDATE kegs SET version='0.0' WHERE name='$TOP';" ||
  fail "could not bump down $TOP's version"
pass "synthesised stale version='0.0' on $TOP"

# --- 3. Nuke the dep's opt symlink (DB row + cellar dir survive) ------
DEP_CELLAR=$(sqlite3 "$DB" \
  "SELECT cellar_path FROM kegs WHERE name='$DEP' LIMIT 1;")
[[ -d "$DEP_CELLAR" ]] || fail "$DEP cellar dir missing before tamper: $DEP_CELLAR"

rm -f "$PREFIX/opt/$DEP"
[[ ! -L "$PREFIX/opt/$DEP" ]] || fail "could not remove $PREFIX/opt/$DEP"
pass "wiped \$PREFIX/opt/$DEP (cellar dir + DB row preserved)"

# --- 4. Trigger the upgrade and assert the dep self-heals -------------
UPGRADE_LOG="$PREFIX/upgrade.log"
printf '\xe2\x96\xb8 mt upgrade %s (logs \xe2\x86\x92 %s)\n' "$TOP" "$UPGRADE_LOG"
if ! "$BIN" upgrade "$TOP" >"$UPGRADE_LOG" 2>&1; then
  tail -30 "$UPGRADE_LOG" >&2
  fail "$TOP upgrade aborted; see $UPGRADE_LOG"
fi

# Pre-fix, the walker would have left $PREFIX/opt/$DEP wiped after the
# upgrade because the nuked link was treated as "still installed". The
# fix walks every transitive dep through `deps.ensureOptLink` before
# the dep BFS, so the symlink is rebuilt regardless of whether the
# downstream install fast-path elects to re-fetch.
[[ -L "$PREFIX/opt/$DEP" ]] ||
  fail "\$PREFIX/opt/$DEP not restored after upgrade — pre-fix asymmetry returned"
RESOLVED=$(readlink -f "$PREFIX/opt/$DEP" 2>/dev/null || readlink "$PREFIX/opt/$DEP")
[[ -d "$RESOLVED" ]] ||
  fail "\$PREFIX/opt/$DEP points at a non-existent target: $RESOLVED"
case "$RESOLVED" in
*"/Cellar/$DEP/"*) ;;
*) fail "\$PREFIX/opt/$DEP resolves outside the $DEP cellar: $RESOLVED" ;;
esac
pass "\$PREFIX/opt/$DEP rebuilt and resolves into the $DEP cellar"

printf '\n\xe2\x9c\x94 upgrade-dep-opt-link-self-heal regression passed\n'
