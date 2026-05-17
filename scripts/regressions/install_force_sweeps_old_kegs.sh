#!/usr/bin/env bash
# Regression guard for the orphan-keg bug uncovered on a live machine.
#
# When a user has `<prefix>/Cellar/<name>/<old_version>/` on disk (e.g.
# from a prior install before a revision bump landed) and runs
# `malt install <name> --force`, the resolver picks the new revision
# and materializes it at `<prefix>/Cellar/<name>/<old>_<rev>/`.
# Before the fix, `pruneCellarForReinstall` only wiped the resolved
# version dir; the old version dir was orphaned and `malt doctor`
# would flag it as an unpatched Mach-O placeholder offender forever.
# The fix adds `pruneOtherCellarVersionsForReinstall` which sweeps
# any sibling version dirs under `Cellar/<name>/` when `--force`
# fires.
#
# This script seeds the bug shape: pre-existing `Cellar/pcre2/<ver>/`
# with a marker file, then runs `malt install pcre2 --force`, then
# asserts the sibling is gone and the new revision is present.
#
# Usage: scripts/regressions/install_force_sweeps_old_kegs.sh
# Requirements: built `malt` binary, network access to
# formulae.brew.sh + ghcr.io.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BIN="${MALT_BIN:-$ROOT/zig-out/bin/malt}"
[[ -x "$BIN" ]] || {
  echo "build malt first: zig build" >&2
  exit 2
}

PREFIX="/tmp/mt_force_sweep"
export MALT_PREFIX="$PREFIX"
rm -rf "$PREFIX"
mkdir -p "$PREFIX"
trap 'rm -rf "$PREFIX"' EXIT

pass() { printf '  ✓ %s\n' "$*"; }
fail() {
  printf '  ✗ %s\n' "$*" >&2
  exit 1
}
skip() {
  printf '  ⊘ %s\n' "$*"
  exit 0
}

# ── Resolve current pcre2 version + revision from the live API ──────
get_rev() {
  curl -fsSL "https://formulae.brew.sh/api/formula/pcre2.json" |
    python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('revision',0))"
}
get_ver() {
  curl -fsSL "https://formulae.brew.sh/api/formula/pcre2.json" |
    python3 -c "import sys,json; d=json.load(sys.stdin); print(d['versions']['stable'])"
}

REV=$(get_rev)
VER=$(get_ver)
if [[ "$REV" == "0" ]]; then
  skip "pcre2 currently has revision 0 — rerun once a revision bump lands; nothing to sweep"
fi

KEEP="${VER}_${REV}"
STALE="$VER"
printf '▸ target: pcre2  (resolver picks %s; seeded stale = %s)\n' "$KEEP" "$STALE"

# ── Seed pcre2 first so we have a real DB row + linker state at the
# stale version, then surgically patch the row to claim it lives at
# the plain-version dir. This mirrors the production shape: prior
# install before a revision bump, with the kegs row still pointing at
# /Cellar/<name>/<plain_version>/ (no `_<rev>` suffix). Pure mkdir +
# manual INSERT cannot exercise the linker cleanup the way an actual
# row tied to a linked keg does.
printf '▸ malt install pcre2 (seed real DB row + symlinks)\n'
"$BIN" install --quiet pcre2 || fail "seed install of pcre2 failed"

DB="$PREFIX/db/malt.db"
[[ -f "$DB" ]] || fail "seed failed: $DB missing"

STALE_DIR="$PREFIX/Cellar/pcre2/$STALE"
KEEP_DIR="$PREFIX/Cellar/pcre2/$KEEP"
[[ -d "$KEEP_DIR" ]] || fail "seed install did not produce $KEEP_DIR"

# Physically move the materialized keg to the plain-version path and
# rewrite the DB row + every links row to point at it. We are
# manufacturing the state a v4-era machine would have: kegs row +
# real symlinks + cellar dir all pointing at /Cellar/pcre2/$STALE.
mv "$KEEP_DIR" "$STALE_DIR"
sqlite3 "$DB" "UPDATE kegs SET cellar_path = '$STALE_DIR' WHERE name = 'pcre2';"
sqlite3 "$DB" "UPDATE links SET target = REPLACE(target, '/$KEEP/', '/$STALE/') WHERE keg_id IN (SELECT id FROM kegs WHERE name = 'pcre2');"
# Repoint the opt symlink so the next install's linker conflict check
# sees the stale keg as the live owner.
rm -f "$PREFIX/opt/pcre2"
ln -s "$STALE_DIR" "$PREFIX/opt/pcre2"
pass "seeded Cellar/pcre2/$STALE + kegs row + links"

ROW_COUNT_BEFORE=$(sqlite3 "$DB" "SELECT COUNT(*) FROM kegs WHERE name = 'pcre2';")
[[ "$ROW_COUNT_BEFORE" == "1" ]] || fail "expected 1 pcre2 row before force; got $ROW_COUNT_BEFORE"

# ── Run the actual force-install through the full pipeline ──────────
printf '▸ malt install pcre2 --force (resolver picks %s, must sweep %s)\n' "$KEEP" "$STALE"
"$BIN" install --force --quiet pcre2 || fail "force-install of pcre2 failed"
pass "force-install of pcre2 completed"

# ── Assert: stale dir + stale DB row both gone ──────────────────────
[[ ! -d "$STALE_DIR" ]] ||
  fail "Cellar/pcre2/$STALE still on disk after --force — disk sweep did not fire"
pass "Cellar/pcre2/$STALE swept (disk)"

ROW_COUNT_AFTER=$(sqlite3 "$DB" "SELECT COUNT(*) FROM kegs WHERE name = 'pcre2';")
[[ "$ROW_COUNT_AFTER" == "1" ]] ||
  fail "expected 1 pcre2 row after force; got $ROW_COUNT_AFTER (stale row not deleted)"
pass "kegs has exactly one pcre2 row after force"

STALE_ROW_PRESENT=$(sqlite3 "$DB" "SELECT COUNT(*) FROM kegs WHERE name = 'pcre2' AND cellar_path = '$STALE_DIR';")
[[ "$STALE_ROW_PRESENT" == "0" ]] ||
  fail "kegs row still points at swept dir $STALE_DIR — DB sweep did not fire"
pass "no kegs row references the swept dir"

[[ -d "$KEEP_DIR" ]] ||
  fail "Cellar/pcre2/$KEEP missing after force-install (got: $(ls -1 "$PREFIX/Cellar/pcre2" 2>/dev/null || echo '(missing)'))"
pass "Cellar/pcre2/$KEEP present (resolved version kept)"

# ── Doctor must NOT flag the package anymore ────────────────────────
DOCTOR_OUT=$("$BIN" doctor --verbose 2>&1 || true)
if echo "$DOCTOR_OUT" | grep -qE "pcre2 ${STALE}( |$)"; then
  echo "$DOCTOR_OUT" >&2
  fail "doctor still flags pcre2 $STALE — sweep slipped through"
fi
if echo "$DOCTOR_OUT" | grep -qE "keg\(s\) in DB but missing on disk"; then
  echo "$DOCTOR_OUT" >&2
  fail "doctor reports Missing kegs after sweep — DB cleanup did not run"
fi
pass "doctor reports neither stale placeholder nor missing kegs"

# ── Same-version --force must not bounce on the linker conflict ─────
# Reproducer for the linker-side gap: with pcre2 freshly installed at
# the resolved version, `--force` on the same version owns symlinks
# under <prefix>/{bin,lib,...} pointing at the keg we are about to
# re-materialize. Without `unlinkSameVersionKegLinks`, checkConflicts
# fires and the install bails with "Use --force to overwrite" — even
# though --force is already on.
printf '▸ malt install pcre2 --force (same version, must overwrite linker state)\n'
"$BIN" install --force --quiet pcre2 || fail "same-version force-install hit the linker conflict trap"
pass "same-version force-install completed"

[[ -d "$PREFIX/Cellar/pcre2/$KEEP" ]] ||
  fail "Cellar/pcre2/$KEEP missing after same-version force"
pass "Cellar/pcre2/$KEEP still present after same-version force"

DOCTOR_OUT=$("$BIN" doctor --verbose 2>&1 || true)
# Match the warn-row body, not the "✓ Broken symlinks" check label.
if echo "$DOCTOR_OUT" | grep -qE "broken symlink\(s\)"; then
  echo "$DOCTOR_OUT" >&2
  fail "doctor reports broken symlinks after same-version force"
fi
pass "doctor clean after same-version force"

printf '\n✔ install-force-sweeps-old-kegs regression passed\n'
