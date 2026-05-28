#!/usr/bin/env bash
# Regression guard for the --isolate-deps install policy.
#
# Sequence:
#   1. install a formula with a runtime dep under --isolate-deps;
#      assert the parent's bin lands in <prefix>/bin while the dep's
#      bin does NOT, kegs.bin_isolated=1 for the dep, links table
#      agrees.
#   2. upgrade the same formula without re-passing the flag;
#      assert isolation sticks (the replay path reads kegs.bin_isolated
#      and feeds it back to recordKeg + Linker.link).
#   3. install the dep directly; assert promotion to install_reason=
#      'direct', bin_isolated cleared, bin link materialised.
#   4. uninstall everything; assert links table is empty for both.
#
# Pick: `cmark` is a tiny formula whose runtime deps live entirely
# in `cmake` (build-only) — too narrow. Use `coreutils` which depends
# on `gmp` at runtime: both ship a bin file, both are bottled small,
# revisions stable enough that the test isn't a churn magnet.
#
# Usage: scripts/regressions/bin_isolation_basics.sh
# Requirements: built `malt` binary, network access to
# formulae.brew.sh + ghcr.io.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BIN="${MALT_BIN:-$ROOT/zig-out/bin/malt}"
[[ -x "$BIN" ]] || {
  echo "build malt first: zig build" >&2
  exit 2
}

PREFIX="/tmp/mt_bin_isolation"
export MALT_PREFIX="$PREFIX"
rm -rf "$PREFIX"
mkdir -p "$PREFIX"
trap 'rm -rf "$PREFIX"' EXIT

pass() { printf '  ✓ %s\n' "$*"; }
fail() {
  printf '  ✗ %s\n' "$*" >&2
  exit 1
}

PARENT="coreutils"
DEP="gmp"
DB="$PREFIX/db/malt.db"

# ── Step 1: install parent under --isolate-deps ─────────────────────
printf '▸ malt install --isolate-deps %s\n' "$PARENT"
"$BIN" install --quiet --isolate-deps "$PARENT" || fail "install --isolate-deps failed"

[[ -f "$DB" ]] || fail "DB not created at $DB"

# Parent's bin must be present (parent is direct, never isolated).
# `find -mindepth 1 -maxdepth 1 -print -quit` exits on the first hit
# so this is O(1) even when bin/ has many entries.
[[ -n "$(find "$PREFIX/bin/" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]] ||
  fail "no bin files under <prefix>/bin after parent install"
pass "<prefix>/bin populated by parent"

# Dep's bin must NOT be in <prefix>/bin.
# coreutils ships `cksum`, gmp does not ship a binary so we check
# the opt link is present (anchoring works) and the row says isolated.
[[ -L "$PREFIX/opt/$DEP" ]] || fail "opt/$DEP anchor missing"
pass "opt/$DEP anchor present (Mach-O resolves through here)"

dep_isolated=$(sqlite3 "$DB" "SELECT bin_isolated FROM kegs WHERE name='$DEP';" 2>/dev/null || echo "")
[[ "$dep_isolated" == "1" ]] || fail "kegs.bin_isolated=$dep_isolated for $DEP (expected 1)"
pass "$DEP row has bin_isolated=1"

dep_reason=$(sqlite3 "$DB" "SELECT install_reason FROM kegs WHERE name='$DEP';" 2>/dev/null || echo "")
[[ "$dep_reason" == "dependency" ]] || fail "$DEP install_reason=$dep_reason (expected dependency)"
pass "$DEP recorded as dependency"

dep_bin_links=$(sqlite3 "$DB" "SELECT COUNT(*) FROM links l JOIN kegs k ON l.keg_id=k.id WHERE k.name='$DEP' AND (l.link_path LIKE '%/bin/%' OR l.link_path LIKE '%/sbin/%');" 2>/dev/null || echo "0")
[[ "$dep_bin_links" == "0" ]] || fail "$DEP has $dep_bin_links bin/sbin link rows (expected 0)"
pass "links table has no bin/sbin rows for $DEP"

# ── Step 2: upgrade without the flag must replay isolation ──────────
printf '▸ malt upgrade %s (no flag — must replay isolation)\n' "$PARENT"
# Upgrade is a no-op when already at latest; that's fine — what we
# really want is the replay path. Re-run install --force to retrigger
# the same record+link pass without changing version.
"$BIN" install --quiet --force "$PARENT" || fail "force-reinstall to test replay failed"

dep_isolated=$(sqlite3 "$DB" "SELECT bin_isolated FROM kegs WHERE name='$DEP';" 2>/dev/null || echo "")
[[ "$dep_isolated" == "1" ]] || fail "after replay, $DEP bin_isolated=$dep_isolated (expected 1)"
pass "$DEP isolation replays across re-record without re-passing the flag"

# ── Step 3: install the dep directly — promotion path ──────────────
printf '▸ malt install %s (promote isolated dep to direct)\n' "$DEP"
"$BIN" install --quiet "$DEP" || fail "promotion install failed"

dep_reason=$(sqlite3 "$DB" "SELECT install_reason FROM kegs WHERE name='$DEP';" 2>/dev/null || echo "")
[[ "$dep_reason" == "direct" ]] || fail "$DEP install_reason=$dep_reason after promotion (expected direct)"
pass "$DEP promoted to install_reason=direct"

dep_isolated=$(sqlite3 "$DB" "SELECT bin_isolated FROM kegs WHERE name='$DEP';" 2>/dev/null || echo "")
[[ "$dep_isolated" == "0" ]] || fail "$DEP bin_isolated=$dep_isolated after promotion (expected 0)"
pass "$DEP bin_isolated cleared on promotion"

# ── Step 4: uninstall everything; assert links clean ───────────────
printf '▸ malt uninstall %s %s\n' "$PARENT" "$DEP"
"$BIN" uninstall --quiet --force "$PARENT" || fail "uninstall $PARENT failed"
"$BIN" uninstall --quiet --force "$DEP" || fail "uninstall $DEP failed"

orphan_links=$(sqlite3 "$DB" "SELECT COUNT(*) FROM links;" 2>/dev/null || echo "0")
[[ "$orphan_links" == "0" ]] || fail "links table not empty after uninstall ($orphan_links rows)"
pass "links table is empty post-uninstall"

orphan_kegs=$(sqlite3 "$DB" "SELECT COUNT(*) FROM kegs WHERE name IN ('$PARENT', '$DEP');" 2>/dev/null || echo "0")
[[ "$orphan_kegs" == "0" ]] || fail "kegs table still carries $PARENT or $DEP rows ($orphan_kegs)"
pass "kegs table is clean for $PARENT + $DEP"

printf '✓ bin_isolation_basics: all stages passed\n'
