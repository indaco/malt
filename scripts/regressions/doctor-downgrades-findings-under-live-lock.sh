#!/usr/bin/env bash
# Regression: `mt doctor` must downgrade filesystem-vs-DB findings to an
# informational "operation in progress" note while an install/upgrade holds
# the prefix lock — and only then. The transients it would otherwise flag
# (a kegs row recorded before its cellar dir materialises; a symlink dangling
# during an upgrade's keg swap) are expected intermediate states of a correct
# operation, not health defects, so reporting them as err/warn produces the
# "doctor was angry last night, fine this morning" false positive.
#
# The downgrade must be gated on a *live* lock holder: a stale lock from a
# dead PID must NOT mask real findings. This seeds both transient shapes, then
# checks doctor with a live lock present (findings downgraded to `info`) and
# again with the lock gone (findings back at their real `err`/`warn`).
#
# Uses `--json` so the per-finding severity is asserted deterministically, and
# MALT_OFFLINE=1 so the API-reachable probe never reaches the network.
#
# Usage: scripts/regressions/doctor-downgrades-findings-under-live-lock.sh
# Requirements: built `malt` at $MALT_BIN or zig-out/bin/malt, sqlite3. Offline.

set -uo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT" || exit 1

MALT_BIN=${MALT_BIN:-$ROOT/zig-out/bin/malt}
if [[ ! -x "$MALT_BIN" ]]; then
  printf 'FAIL: malt binary not found at %s — run "zig build" first.\n' "$MALT_BIN" >&2
  exit 1
fi
command -v sqlite3 >/dev/null 2>&1 || {
  printf 'SKIP: sqlite3 not on PATH — needed to seed the missing-keg row.\n' >&2
  exit 2
}

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

PFX=$(mktemp -d -t mt_doctor_live_lock.XXXXXX)
export MALT_PREFIX="$PFX"
export MALT_OFFLINE=1
SLEEPER=""
cleanup() {
  [[ -n "$SLEEPER" ]] && kill "$SLEEPER" 2>/dev/null
  rm -rf "$PFX"
}
trap cleanup EXIT

# A structurally complete prefix so the seeded transients are the findings
# under test, not missing-dir noise.
for d in store Cellar Caskroom opt bin lib sbin tmp cache db; do mkdir -p "$PFX/$d"; done

# Initialise the schema, then seed the two transient shapes.
"$MALT_BIN" list >/dev/null 2>&1 || true
# Missing keg: a kegs row whose cellar_path does not exist on disk.
sqlite3 "$PFX/db/malt.db" \
  "INSERT INTO kegs (name, full_name, version, store_sha256, cellar_path, pinned)
   VALUES ('ghost', 'ghost', '1.0', 'sha', '$PFX/Cellar/ghost/1.0', 0);"
# Broken symlink: a dangling link under bin/.
ln -s "$PFX/Cellar/ghost/1.0/bin/ghost" "$PFX/bin/ghost"

sev_of() { # sev_of <json> <finding-id> → prints the finding's severity token
  printf '%s' "$1" | grep -o "\"id\":\"$2\",\"severity\":\"[a-z]*\"" | grep -o '"severity":"[a-z]*"' | grep -o '[a-z]*"$' | tr -d '"'
}

# ── live lock: an install is "in flight" ────────────────────────────────
sleep 300 &
SLEEPER=$!
printf '%s' "$SLEEPER" >"$PFX/db/malt.lock"

live=$("$MALT_BIN" doctor --json 2>/dev/null || true)
[[ "$(sev_of "$live" missing_kegs)" == "info" ]] ||
  fail "missing-keg finding not downgraded to info under a live lock (got '$(sev_of "$live" missing_kegs)')"
[[ "$(sev_of "$live" broken_symlinks)" == "info" ]] ||
  fail "broken-symlink finding not downgraded to info under a live lock (got '$(sev_of "$live" broken_symlinks)')"

# ── lock gone: the downgrade must lift, real severities return ───────────
kill "$SLEEPER" 2>/dev/null
wait "$SLEEPER" 2>/dev/null
SLEEPER=""
rm -f "$PFX/db/malt.lock"

dead=$("$MALT_BIN" doctor --json 2>/dev/null || true)
[[ "$(sev_of "$dead" missing_kegs)" == "err" ]] ||
  fail "missing-keg finding not restored to err without a lock (got '$(sev_of "$dead" missing_kegs)') — downgrade is not lock-gated"
[[ "$(sev_of "$dead" broken_symlinks)" == "warn" ]] ||
  fail "broken-symlink finding not restored to warn without a lock (got '$(sev_of "$dead" broken_symlinks)')"

printf 'PASS: doctor downgrades fs-vs-DB findings only while a live lock is held\n'
