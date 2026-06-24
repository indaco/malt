#!/usr/bin/env bash
# Regression: `mt doctor --fix` must explain why it could not sweep an
# orphaned store entry, instead of silently reporting nothing.
#
# The orphan reaper skipped any entry whose directory could not be removed
# (permissions, a held file, an immutable flag) and never incremented its
# swept count — so a blocked fix printed no "swept" line at all, exactly
# like a clean prefix. A user watching `--fix` do nothing could not tell
# "already clean" from "tried and could not".
#
# This seeds a true refcount-0 orphan, makes its directory undeletable with
# the macOS immutable flag, runs `mt doctor --fix`, and asserts the output
# names the blocker. The flag also makes the case root-proof: an immutable
# entry resists removal even for the superuser, so the bug reproduces in any
# CI environment.
#
# Usage: scripts/regressions/doctor-fix-orphan-blocked-reports-reason.sh
# Requirements: built `malt` at $MALT_BIN or zig-out/bin/malt, sqlite3 on
# PATH, macOS (chflags). Offline.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

MALT_BIN=${MALT_BIN:-$ROOT/zig-out/bin/malt}
if [[ ! -x "$MALT_BIN" ]]; then
  printf 'FAIL: malt binary not found at %s — run "zig build" first.\n' "$MALT_BIN" >&2
  exit 1
fi
command -v sqlite3 >/dev/null 2>&1 || {
  printf 'SKIP: sqlite3 not on PATH — needed to seed the refcount-0 row.\n' >&2
  exit 2
}
command -v chflags >/dev/null 2>&1 || {
  printf 'SKIP: chflags not available — this guard needs macOS.\n' >&2
  exit 2
}

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

SHA="deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
PFX=$(mktemp -d -t mt_doctor_fix_blocked.XXXXXX)
export MALT_PREFIX="$PFX"
# Clear the immutable flag before removing, or cleanup itself is blocked.
trap 'chflags -R nouchg "$PFX" 2>/dev/null || true; rm -rf "$PFX"' EXIT

mkdir -p "$PFX/db" "$PFX/store/$SHA"

# Materialise the schema via the real initializer, then seed a refcount-0
# row so the store dir is a true orphan the reaper will try to sweep.
"$MALT_BIN" purge --store-orphans </dev/null >/dev/null 2>&1 || true
sqlite3 "$PFX/db/malt.db" \
  "INSERT OR REPLACE INTO store_refs (store_sha256, refcount) VALUES ('$SHA', 0);"

# Make the entry undeletable: rmdir of an immutable dir fails with EPERM.
chflags uchg "$PFX/store/$SHA"

out=$("$MALT_BIN" doctor --fix </dev/null 2>&1 || true)

# Bug present (pre-fix): the blocked entry is silently skipped — no "swept"
# line, no diagnostic — so the run looks identical to a clean prefix.
# Bug absent (post-fix): the run names the blocker.
printf '%s' "$out" | grep -qi "could not sweep" ||
  fail "doctor --fix did not explain why it could not sweep the blocked orphan"

# Sanity: the undeletable entry is in fact still present.
[[ -d "$PFX/store/$SHA" ]] ||
  fail "expected the immutable orphan dir to survive the blocked sweep"

printf 'PASS: doctor --fix surfaces a reason when an orphan cannot be swept\n'
