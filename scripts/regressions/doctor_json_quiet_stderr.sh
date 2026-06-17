#!/usr/bin/env bash
# Lock `mt doctor --json` to a clean stream split: the versioned JSON
# document on stdout, nothing on stderr.
#
# `--json` is a machine-output mode. Before the fix it mirrored the full
# human report — the "Running health checks..." line, every check row, and
# the severity footer — onto stderr in parallel with the JSON on stdout, so
# an interactive run rendered both views at once.
#
# Pinned behaviour:
#   1. `--json` writes the versioned document to stdout and keeps stderr
#      empty (no progress line, no rows, no footer).
#   2. The severity-based exit code stays load-bearing: a seeded stale lock
#      warns, so the run still exits non-zero.
#   3. The human path is untouched: without `--json`, the rows still render
#      on stderr.
#
# Hermetic: MALT_OFFLINE short-circuits the network probe so no run needs
# the wire.
#
# Usage: scripts/regressions/doctor_json_quiet_stderr.sh

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

MALT_BIN=${MALT_BIN:-$ROOT/zig-out/bin/malt}
if [[ ! -x "$MALT_BIN" ]]; then
  printf 'FAIL: malt binary not found at %s — run "zig build" first.\n' "$MALT_BIN" >&2
  exit 1
fi

export MALT_OFFLINE=1

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

# A PID well outside the macOS range so the lock reads as stale (dead PID):
# guarantees one warn finding, so the severity exit code is observable.
DEAD_PID=999999

PFX=$(mktemp -d -t mt_doctor_json_quiet.XXXXXX)
export MALT_PREFIX="$PFX"
trap 'rm -rf "$PFX"' EXIT

# Seed the expected directory structure plus a seeded stale lock.
mkdir -p "$PFX/store" "$PFX/Cellar" "$PFX/Caskroom" "$PFX/opt" \
  "$PFX/bin" "$PFX/lib" "$PFX/tmp" "$PFX/cache" "$PFX/db"
printf '%s' "$DEAD_PID" >"$PFX/db/malt.lock"

OUT=$(mktemp -t mt_doctor_json_out.XXXXXX)
ERR=$(mktemp -t mt_doctor_json_err.XXXXXX)
trap 'rm -rf "$PFX" "$OUT" "$ERR"' EXIT

# ── 1. --json: JSON on stdout, stderr silent ───────────────────────────
set +e
"$MALT_BIN" doctor --json >"$OUT" 2>"$ERR"
json_code=$?
set -e

if [[ -s "$ERR" ]]; then
  printf 'stderr was:\n' >&2
  cat "$ERR" >&2
  fail '--json leaked the human report onto stderr (expected an empty stderr)'
fi

grep -q '"schema_version"' "$OUT" ||
  fail '--json did not write the versioned JSON document to stdout'
grep -q '"checks"' "$OUT" ||
  fail '--json stdout is missing the checks array'

# ── 2. severity exit code preserved (stale lock warns) ─────────────────
[[ "$json_code" -ne 0 ]] ||
  fail '--json exited zero despite a warning (severity exit code must hold)'

# ── 3. human path still renders rows on stderr ─────────────────────────
human_err=$("$MALT_BIN" doctor 2>&1 1>/dev/null || true)
printf '%s' "$human_err" | grep -q 'MALT_PREFIX' ||
  fail 'human doctor stopped rendering check rows on stderr'

printf 'PASS: doctor --json keeps stderr silent while preserving the exit code\n'
