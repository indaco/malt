#!/usr/bin/env bash
# Lock the `mt doctor --fix <id>` per-finding selector end-to-end.
#
# Pinned behaviour:
#   1. `--fix <id>` applies only the named class (stale_lock here) and
#      leaves the other safe-class offenders (a broken symlink) in place.
#   2. `--fix` with no id stays apply-all: lock + symlink both go.
#   3. An unknown id exits non-zero and mutates nothing.
#   4. `--fix <id> --dry-run` plans but mutates nothing.
#
# `mt doctor` exits non-zero by design whenever any check still warns
# (the leftover broken symlink does), so the apply runs are captured with
# `|| true` and the lock/symlink state is what we actually assert.
#
# Usage: scripts/regressions/doctor_fix_selector.sh

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

MALT_BIN=${MALT_BIN:-$ROOT/zig-out/bin/malt}
if [[ ! -x "$MALT_BIN" ]]; then
  printf 'FAIL: malt binary not found at %s — run "zig build" first.\n' "$MALT_BIN" >&2
  exit 1
fi

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

# A PID well outside the macOS range so the lock reads as stale (dead PID).
DEAD_PID=999999

# Seed a prefix with one stale lock and one broken symlink — two distinct
# safe-fix classes so a targeted fix is observably narrower than apply-all.
seed_prefix() {
  local pfx="$1"
  mkdir -p "$pfx/db" "$pfx/bin"
  printf '%s' "$DEAD_PID" >"$pfx/db/malt.lock"
  ln -s /tmp/mt_doctor_fix_selector_vanished_target "$pfx/bin/dead"
}

# ── 1. --fix <id> applies only that class ──────────────────────────────
PFX=$(mktemp -d -t mt_doctor_fix_one.XXXXXX)
export MALT_PREFIX="$PFX"
seed_prefix "$PFX"

"$MALT_BIN" doctor --fix stale_lock >/dev/null 2>&1 || true
[[ ! -f "$PFX/db/malt.lock" ]] ||
  fail '--fix stale_lock did not remove the stale lock'
[[ -L "$PFX/bin/dead" ]] ||
  fail '--fix stale_lock also removed the broken symlink (should target only stale_lock)'
rm -rf "$PFX"

# ── 2. bare --fix stays apply-all ──────────────────────────────────────
PFX=$(mktemp -d -t mt_doctor_fix_all.XXXXXX)
export MALT_PREFIX="$PFX"
seed_prefix "$PFX"

"$MALT_BIN" doctor --fix >/dev/null 2>&1 || true
[[ ! -f "$PFX/db/malt.lock" ]] ||
  fail 'apply-all --fix did not remove the stale lock'
[[ ! -L "$PFX/bin/dead" ]] ||
  fail 'apply-all --fix did not remove the broken symlink'
rm -rf "$PFX"

# ── 3. unknown id → non-zero exit, no mutation ─────────────────────────
PFX=$(mktemp -d -t mt_doctor_fix_bad.XXXXXX)
export MALT_PREFIX="$PFX"
seed_prefix "$PFX"

set +e
out=$("$MALT_BIN" doctor --fix not_a_real_id 2>&1)
code=$?
set -e
[[ "$code" -ne 0 ]] ||
  fail 'unknown --fix id exited zero (expected a non-zero usage error)'
printf '%s' "$out" | grep -q "unknown --fix id 'not_a_real_id'" ||
  fail 'unknown --fix id did not surface a clear error naming the id'
[[ -f "$PFX/db/malt.lock" ]] ||
  fail 'unknown --fix id removed the stale lock (must mutate nothing)'
[[ -L "$PFX/bin/dead" ]] ||
  fail 'unknown --fix id removed the broken symlink (must mutate nothing)'
rm -rf "$PFX"

# ── 4. --fix <id> --dry-run plans but mutates nothing ──────────────────
PFX=$(mktemp -d -t mt_doctor_fix_dry.XXXXXX)
export MALT_PREFIX="$PFX"
seed_prefix "$PFX"

out=$("$MALT_BIN" doctor --fix stale_lock --dry-run 2>&1 || true)
printf '%s' "$out" | grep -qi 'would remove stale lock file' ||
  fail '--fix stale_lock --dry-run did not print the planned action'
[[ -f "$PFX/db/malt.lock" ]] ||
  fail '--fix stale_lock --dry-run removed the lock (dry-run must mutate nothing)'
rm -rf "$PFX"

printf 'PASS: doctor --fix <id> selector behaves correctly\n'
