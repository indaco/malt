#!/usr/bin/env bash
# Regression: a full `mt upgrade --dry-run` warms the shared `outdated.json`
# snapshot from the would-upgrade set it just computed, so the TUI Outdated
# tab renders instantly instead of re-auditing the same kegs.
#
# Hermetic: the metadata mirror is HTTPS-only with no local injection seam, so
# the fake "upstream" is the on-disk API cache — a fresh `formula_<name>.json`
# under {prefix}/cache/api serves without a network round-trip. A keg seeded
# one version behind that cached formula makes the dry-run report a would-
# upgrade with zero network.
#
# Pins four contracts:
#   1. A full no-args `mt upgrade --dry-run` writes a version-2 outdated.json
#      whose entry matches the printed would-upgrade line.
#   2. A subsequent `mt outdated --json` serves that warmed snapshot.
#   3. A narrowed dry-run (`--cask`) leaves a pre-seeded snapshot untouched —
#      warming a partial audit would make the tab silently under-report.
#   4. A real (non-dry-run) upgrade never warms — the set is stale the instant
#      kegs mutate.
#
# Usage: scripts/regressions/upgrade-dry-run-warms-outdated-snapshot.sh
# Requirements: built malt at $MALT_BIN or zig-out/bin/malt; sqlite3 on PATH.
# No network access required.

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

PREFIX=$(mktemp -d -t malt_upgrade_warm.XXXXXX)
trap 'rm -rf "$PREFIX"' EXIT
export MALT_PREFIX="$PREFIX"
export NO_COLOR=1
export MALT_NO_EMOJI=1
unset MALT_OFFLINE MALT_OUTDATED_MAX_AGE MALT_CACHE CI

DB="$PREFIX/db/malt.db"
SNAP="$PREFIX/cache/outdated.json"
API="$PREFIX/cache/api"

pass() { printf '  \xe2\x9c\x93 %s\n' "$*"; }
fail() {
  printf '  \xe2\x9c\x97 %s\n' "$*" >&2
  exit 1
}

# Initialise the schema (mt list migrates only when db/ exists) and clear any
# kegs a prior case seeded, without re-running migrations.
reset_state() {
  mkdir -p "$PREFIX/db" "$API"
  "$BIN" list >/dev/null 2>&1 || true
  sqlite3 "$DB" "DELETE FROM kegs; DELETE FROM casks;" 2>/dev/null || true
  rm -f "$SNAP"
}

# Seed one installed formula keg (core path: tap is NULL).
seed_keg() {
  local name="$1" version="$2"
  sqlite3 "$DB" "INSERT INTO kegs (name, full_name, version, store_sha256, cellar_path)
    VALUES ('$name', '$name', '$version', 'seedsha', '/tmp/c/$name/$version');"
}

# Fake upstream: a fresh cached formula document at $stable. parseFormula only
# needs name + versions.stable to derive pkg_version.
seed_formula_cache() {
  local name="$1" stable="$2"
  printf '{"name":"%s","versions":{"stable":"%s"}}' "$name" "$stable" \
    >"$API/formula_$name.json"
}

# A bogus snapshot marker: if a case leaves it in place, no write happened.
seed_bogus_snapshot() {
  local gen_ms
  gen_ms=$(($(date +%s) * 1000))
  printf '{"version":2,"generated_at_ms":%s,"formulas":[{"name":"bogus","installed":"0","latest":"9"}],"casks":[]}' \
    "$gen_ms" >"$SNAP"
}

# --- 1. Full no-args dry-run warms the snapshot from its would-upgrade set ---
reset_state
seed_keg regfoo 1.0
seed_formula_cache regfoo 2.0

OUT=$("$BIN" upgrade --dry-run 2>&1 || true)
echo "$OUT" | grep -q "would upgrade regfoo 1.0 -> 2.0" ||
  fail "dry-run did not report the expected would-upgrade line; got:\n$OUT"
[[ -f "$SNAP" ]] || fail "full dry-run wrote no outdated.json (warm dropped)"
grep -q '"version":2' "$SNAP" || fail "warmed snapshot is not version 2; got: $(cat "$SNAP")"
grep -q '"name":"regfoo","installed":"1.0","latest":"2.0"' "$SNAP" ||
  fail "warmed entry does not match the printed set; got: $(cat "$SNAP")"
grep -q '"casks":\[\]' "$SNAP" || fail "warmed snapshot has unexpected casks; got: $(cat "$SNAP")"
pass "full dry-run warms a version-2 snapshot matching the would-upgrade set"

# --- 2. A subsequent `mt outdated --json` serves the warmed snapshot ---
JSON=$("$BIN" outdated --json 2>/dev/null || true)
echo "$JSON" | grep -q 'regfoo' ||
  fail "mt outdated --json did not serve the warmed snapshot; got: $JSON"
pass "mt outdated --json serves the warmed snapshot"

# --- 3. A narrowed dry-run must NOT warm (partial audit) ---
reset_state
seed_keg regfoo 1.0
seed_formula_cache regfoo 2.0
seed_bogus_snapshot
"$BIN" upgrade --cask --dry-run >/dev/null 2>&1 || true
grep -q '"name":"bogus"' "$SNAP" ||
  fail "narrowed (--cask) dry-run overwrote the snapshot — a partial audit was persisted"
pass "narrowed (--cask) dry-run leaves the snapshot untouched"

# --- 4. A real (non-dry-run) upgrade never warms ---
# Seed the keg already current so the real upgrade finds nothing to do (no
# network, no mutation) — the point is only that it writes no snapshot.
reset_state
seed_keg regfoo 2.0
seed_formula_cache regfoo 2.0
seed_bogus_snapshot
"$BIN" upgrade >/dev/null 2>&1 || true
grep -q '"name":"bogus"' "$SNAP" ||
  fail "a real upgrade warmed the snapshot — the pre-upgrade set is stale once kegs mutate"
pass "real upgrade leaves the snapshot untouched"

printf '\n\xe2\x9c\x94 upgrade dry-run warms-outdated-snapshot regression passed\n'
