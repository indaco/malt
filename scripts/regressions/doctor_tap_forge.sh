#!/usr/bin/env bash
# Lock the `mt doctor` registered-taps forge/host report end-to-end, no network.
#
# Pinned behaviour:
#   1. With taps registered, `mt doctor` lists each one as `<name> [<host>]`
#      under a "Registered taps" block — github and off-github alike.
#   2. `mt doctor --json` carries a `{"taps":[{"name","host"},...]}` payload.
#   3. On a prefix with no taps, the block is silent (no "Registered taps").
#
# Registration and doctor render never touch the network, so this runs offline.
# `mt doctor` exits non-zero by design on a bare prefix (e.g. missing CA
# bundle), so every doctor call is captured with `|| true`.
#
# Usage: scripts/regressions/doctor_tap_forge.sh

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

# ── 1 & 2. taps registered → doctor surfaces forge/host (human + json) ──
PREFIX=$(mktemp -d -t mt_doctor_forge.XXXXXX)
mkdir -p "$PREFIX/db"
export MALT_PREFIX="$PREFIX"

"$MALT_BIN" tap zach/ast --repo aeroxy/ast-outline >/dev/null 2>&1 ||
  fail 'mt tap --repo (prefixless github) exited non-zero'
"$MALT_BIN" tap grp/tap --host gitlab.com --repo grp/tap >/dev/null 2>&1 ||
  fail 'mt tap --host gitlab.com --repo grp/tap exited non-zero'

human=$("$MALT_BIN" doctor 2>&1 || true)
printf '%s' "$human" | grep -q '> Registered taps:' ||
  fail 'doctor human output missing the "Registered taps" block'
printf '%s' "$human" | grep -q 'zach/ast \[github.com\]' ||
  fail 'doctor did not list the github tap with its host'
printf '%s' "$human" | grep -q 'grp/tap \[gitlab.com\]' ||
  fail 'doctor did not list the gitlab tap with its host'

json=$("$MALT_BIN" doctor --json 2>/dev/null || true)
printf '%s' "$json" | grep -q '{"taps":\[' ||
  fail 'doctor --json missing the taps payload'
printf '%s' "$json" | grep -q '"name":"grp/tap","host":"gitlab.com"' ||
  fail 'doctor --json did not carry the gitlab tap name+host'

rm -rf "$PREFIX"

# ── 3. no taps → the block is silent ───────────────────────────────────
EMPTY=$(mktemp -d -t mt_doctor_forge_empty.XXXXXX)
mkdir -p "$EMPTY/db"
export MALT_PREFIX="$EMPTY"

empty_out=$("$MALT_BIN" doctor 2>&1 || true)
if printf '%s' "$empty_out" | grep -q 'Registered taps:'; then
  fail 'doctor printed a "Registered taps" block on a prefix with no taps'
fi

rm -rf "$EMPTY"

printf 'OK: mt doctor surfaces each tap forge/host, and stays silent with no taps.\n'
