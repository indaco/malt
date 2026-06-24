#!/usr/bin/env bash
# Regression: `mt doctor` and `mt purge --store-orphans` must share one
# definition of "orphaned store entry", with no dependence on timing.
#
# A store directory committed without a `store_refs` row is a warm /
# in-flight commit: `mt install --download-only` leaves one deliberately,
# and any install interrupted between the bottle commit and `incrementRef`
# leaves one accidentally. `mt purge --store-orphans` is DB-driven
# (`WHERE refcount <= 0`) and structurally cannot see such an entry.
#
# Pre-fix, doctor's disk-driven check counted a no-row entry as an orphan
# and printed "Run: mt purge --store-orphans" — a command that can never
# clear it. The warning then survived the recommended remediation: a
# dead-end loop. This script pins that the entry doctor routes to purge is
# one purge can actually remove, i.e. doctor no longer flags warm bytes.
#
# Property under test: run doctor; if it routes the no-row entry to
# `mt purge --store-orphans`, that command must clear it. The bug makes
# the warning persist after the purge with the entry still on disk.
#
# Usage: scripts/regressions/doctor-purge-orphan-definition-parity.sh
# Requirements: built `malt` at $MALT_BIN or zig-out/bin/malt. Offline.

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

# The string doctor prints only when it routes a store entry at the
# purge-orphans remediation. Never appears on the OK line.
REMEDIATION='Run: mt purge --store-orphans'

PFX=$(mktemp -d -t mt_doctor_orphan_parity.XXXXXX)
export MALT_PREFIX="$PFX"
trap 'rm -rf "$PFX"' EXIT

# A store dir with no `store_refs` row — a warm / interrupted commit.
SHA="deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
mkdir -p "$PFX/db" "$PFX/store/$SHA"

# Materialise the schema (store_refs table) via the real initializer so
# doctor's row lookup runs against a valid table; the empty store has no
# orphan, so this removes nothing.
"$MALT_BIN" purge --store-orphans </dev/null >/dev/null 2>&1 || true

out1=$("$MALT_BIN" doctor </dev/null 2>&1 || true)

if printf '%s' "$out1" | grep -qF "$REMEDIATION"; then
  # Doctor routed the no-row entry to purge. Take it at its word.
  "$MALT_BIN" purge --store-orphans </dev/null >/dev/null 2>&1 || true
  out2=$("$MALT_BIN" doctor </dev/null 2>&1 || true)
  if printf '%s' "$out2" | grep -qF "$REMEDIATION" && [[ -d "$PFX/store/$SHA" ]]; then
    fail "doctor recommends 'purge --store-orphans' for a no-row entry that command cannot remove"
  fi
fi

printf 'PASS: doctor and purge --store-orphans agree on the orphan definition\n'
