#!/usr/bin/env bash
# Regression: relocation rewrites a bottle's embedded paths in place, so a
# string can shrink but never grow. A malt prefix longer than the prefix baked
# into the bottle leaves those slots byte-identical — the keg keeps live
# references to the build prefix and the package reads its config from a tree
# malt does not own. fontconfig hit this: fc-cache read /opt/homebrew/etc/fonts
# and failed on a cache dir it could not write.
#
# The patcher already detected this (`rewriteCstringSlot` returns `.skipped`
# when the replacement is longer) and the count was discarded. Both halves of
# the fix are pinned here:
#   1. install warns, naming the keg and the prefix-length cause;
#   2. `mt doctor` reports the affected package for a keg already on disk.
#
# Driven with a synthetic keg rather than a real install: no network, and the
# embedded string is a fixture instead of whatever a bottle happens to ship.
#
# Exits 0 when both signals are present, non-zero (naming the missing one)
# when either is absent. Finishes well under 30s.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BIN="${MALT_BIN:-$ROOT/zig-out/bin/malt}"
[[ -x "$BIN" ]] || {
  echo "build malt first: zig build" >&2
  exit 2
}

PREFIX=$(mktemp -d)/malt-prefix
mkdir -p "$PREFIX"
trap 'rm -rf "$(dirname "$PREFIX")"' EXIT

export MALT_PREFIX="$PREFIX" NO_COLOR=1 MALT_NO_EMOJI=1 MALT_OFFLINE=1

pass() { printf '  ✓ %s\n' "$*"; }
fail() {
  printf '  ✗ %s\n' "$*" >&2
  exit 1
}

# Relocation records its own verdict in a keg sidecar. Whether a bottle was
# even eligible for the absolute rewrite depends on its `cellar` type, which
# is not persisted, and the surviving strings look identical either way — so
# the recorded verdict is what doctor reads, and what this seeds.
KEG="$PREFIX/Cellar/probe/1.0"
mkdir -p "$KEG/bin" "$PREFIX/store" "$PREFIX/opt" "$PREFIX/bin" "$PREFIX/db"
printf '3\n' >"$KEG/.malt-unrelocated"

# ── doctor reports the keg ───────────────────────────────────────────
HUMAN=$("$BIN" doctor --verbose 2>&1 1>/dev/null || true)
printf '%s' "$HUMAN" | grep -q 'Relocated prefix paths' ||
  fail "doctor drew no 'Relocated prefix paths' row for a keg holding the build prefix"
printf '%s' "$HUMAN" | grep -q 'probe 1.0' ||
  fail "doctor's relocated-prefix row did not name the affected package"
pass "doctor reports the package that kept the build prefix"

JSON=$("$BIN" doctor --json 2>/dev/null || true)
printf '%s' "$JSON" | grep -q '"id":"relocated_prefix_paths","severity":"warn"' ||
  fail "doctor --json did not serialize a warn finding for relocated_prefix_paths"
pass "doctor --json serializes the finding"

# ── a keg relocation handled cleanly stays silent ────────────────────
# Most bottles are `:any`, where the absolute rewrite is skipped by design
# and nothing is ever dropped. Those must not be reported, however long the
# prefix is — the earlier heuristic flagged jq and ripgrep here.
rm -f "$KEG/.malt-unrelocated"
CLEAN=$("$BIN" doctor --verbose 2>&1 1>/dev/null || true)
if printf '%s' "$CLEAN" | grep -q 'Relocated prefix paths .*build prefix'; then
  fail "a keg with no dropped paths was still reported"
fi
pass "a keg relocation handled cleanly stays silent"

printf '\n✔ unrelocatable prefix paths are surfaced, not silently dropped\n'
