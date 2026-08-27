#!/usr/bin/env bash
# Regression: `mt upgrade` must run the formula's post-install phase for
# the freshly swapped keg.
#
# The bug: upgradeFormula materialised the new keg, swapped the DB rows,
# relinked, and finished — post-install never ran, for any hook form
# (`def post_install` Ruby or declarative `post_install_steps`). Effects
# that upstream regenerates on every install/upgrade (loader caches,
# compiled schema stores, service dirs) silently went stale or missing
# until the user happened to reinstall.
#
# The fix drives the shared post-install router after the swap, exactly
# like `mt install`: steps and DSL bodies run natively, the system-Ruby
# fallback stays a scoped opt-in via the new `--use-system-ruby=<name>`
# upgrade flag.
#
# This script seeds a real install of a steps-migrated, dependency-free
# formula, rewrites its DB row to an older version, deletes the step's
# artifact, and asserts the upgrade both routes post-install loudly and
# recreates the artifact. Needs network for the seeding install (same
# contract as the other upgrade regressions).

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

PREFIX=$(mktemp -d /tmp/mt.XXX)
export MALT_PREFIX="$PREFIX"
export NO_COLOR=1
export MALT_NO_EMOJI=1
mkdir -p "$PREFIX"
trap 'rm -rf "$PREFIX"' EXIT

pass() { printf '  \xe2\x9c\x93 %s\n' "$*"; }
fail() {
  printf '  \xe2\x9c\x97 %s\n' "$*" >&2
  exit 1
}

# daemontools: zero deps, one declarative step (mkdir_p etc/service).
SEED="daemontools"
DB="$PREFIX/db/malt.db"

printf '\xe2\x96\xb8 seeding prefix with mt install %s\n' "$SEED"
"$BIN" install "$SEED" >"$PREFIX/install.log" 2>&1 ||
  fail "seed install of $SEED failed — see $PREFIX/install.log"
[[ -d "$PREFIX/etc/service" ]] ||
  fail "install did not run the mkdir_p step — is the steps executor broken?"
pass "$SEED installed with its post-install artifact"

# Rewind the keg row to a fake older version and move the cellar dir to
# match, so the upgrade path sees a genuine version bump. Drop the step's
# artifact to prove the upgrade recreates it.
NEW_DIR=$(basename "$(find "$PREFIX/Cellar/$SEED" -mindepth 1 -maxdepth 1 -type d | head -1)")
mv "$PREFIX/Cellar/$SEED/$NEW_DIR" "$PREFIX/Cellar/$SEED/0.70"
sqlite3 "$DB" "UPDATE kegs SET version='0.70', revision=0, store_sha256='',
  cellar_path='$PREFIX/Cellar/$SEED/0.70' WHERE name='$SEED';" ||
  fail "could not rewind the keg row"
rm -rf "$PREFIX/etc/service"
pass "keg rewound to 0.70 and post-install artifact removed"

OUT=$("$BIN" upgrade "$SEED" 2>&1) || {
  printf '%s\n' "$OUT" >&2
  fail "upgrade failed"
}
printf '%s\n' "$OUT" | grep -q "post_install" ||
  fail "upgrade swapped the keg without any post_install routing output"
[[ -d "$PREFIX/etc/service" ]] ||
  fail "post-install artifact missing after upgrade — the step never ran"
pass "upgrade ran post-install and recreated the artifact"

echo "PASS: upgrade drives post-install for the swapped keg"
