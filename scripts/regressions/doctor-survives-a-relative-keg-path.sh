#!/usr/bin/env bash
# Regression: `mt doctor` must not abort on a `kegs` row whose `cellar_path`
# is relative.
#
# The missing-keg check probed each recorded path with `accessAbsolute`, which
# asserts its argument is absolute. A legacy or hand-edited row carrying a
# relative path therefore killed the whole doctor run with an "unreachable"
# panic, taking every other check down with it. A relative path names no keg
# on disk, so the check now counts it as missing and keeps going.
#
# Usage: scripts/regressions/doctor-survives-a-relative-keg-path.sh
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

PFX=$(mktemp -d -t mt_doctor_relative_keg.XXXXXX)
export MALT_PREFIX="$PFX"
trap 'rm -rf "$PFX"' EXIT

mkdir -p "$PFX/db"

# Materialise the schema with the real initializer, then seed the bad row.
"$MALT_BIN" purge --store-orphans </dev/null >/dev/null 2>&1 || true
sqlite3 "$PFX/db/malt.db" \
  "INSERT INTO kegs (name, full_name, version, revision, store_sha256, cellar_path)
     VALUES ('probe','probe','1.0',0,'aa','Cellar/probe/1.0');"

out=$("$MALT_BIN" doctor </dev/null 2>&1 || true)

# A panic aborts the process; the run never reaches its own summary line.
printf '%s' "$out" | grep -q 'reached unreachable code' &&
  fail 'doctor panicked on a relative cellar_path'
printf '%s' "$out" | grep -qi 'keg' ||
  fail 'doctor produced no keg check output; it likely died early'

printf 'PASS: doctor reports a relative keg path instead of aborting\n'
