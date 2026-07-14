#!/usr/bin/env bash
# Regression: a `mt upgrade --dry-run` whose only "would-refresh" tap keg is
# actually version-current (its tap HEAD moved without a version bump) no
# longer poisons the whole snapshot warm. The dry-run resolves the tap's
# `.rb` version, sees it matches the installed version, and warms a snapshot
# that simply omits that keg — instead of tainting and discarding every
# collected core/cask row.
#
# Pre-fix behaviour (the coverage gap this closes): the tap path decided
# purely by repo HEAD sha, had no `.rb` version in scope, and set a
# sink-wide taint. One tap keg vetoed the entire warm, so a box with any
# third-party-tap keg got no warmed snapshot at all.
#
# Pins four contracts against a real tap (the tap HEAD + one `.rb` GET are
# the only network the bug inherently needs; a classified network condition
# skips-loud rather than failing):
#   1. The full dry-run writes an outdated.json (the tap keg did NOT taint).
#   2. That snapshot contains the genuinely-outdated core keg (coverage
#      delivered — the valid rows are no longer collateral of the taint).
#   3. That snapshot does NOT list the version-current tap keg (no
#      over-report of a sha-only tap move).
#   4. `mt outdated --json` (version truth) also omits the tap keg.
#
# Usage: scripts/regressions/upgrade-tap-formula-taint-upgrade-formula-taint.sh
# Requirements: built malt at $MALT_BIN or zig-out/bin/malt; sqlite3 on PATH;
# network access to the tap HEAD + its `.rb`.

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

PREFIX=$(mktemp -d -t malt_tap_warm.XXXXXX)
trap 'rm -rf "$PREFIX"' EXIT
export MALT_PREFIX="$PREFIX"
export NO_COLOR=1
export MALT_NO_EMOJI=1
unset MALT_OFFLINE MALT_OUTDATED_MAX_AGE MALT_CACHE CI

DB="$PREFIX/db/malt.db"
SNAP="$PREFIX/cache/outdated.json"
API="$PREFIX/cache/api"
mkdir -p "$PREFIX/db" "$API"

# A stable third-party tap whose formula malt is known to fetch + parse
# (URL-derived version, proven by tap_formula_url_version.sh).
TAP="aeroxy/tap"
NAME="ast-outline"
CORE="regcore" # core keg seeded outdated via the on-disk API cache

pass() { printf '  \xe2\x9c\x93 %s\n' "$*"; }
skip() { printf '  - %s\n' "$*"; }
fail() {
  printf '  \xe2\x9c\x97 %s\n' "$*" >&2
  exit 1
}

is_network_blip() { grep -qE "rate limit|Network failure|Could not resolve|timed out" "$1"; }

# --- Register the tap (real; writes owner/repo/url correctly) -------------
"$BIN" list >/dev/null 2>&1 || true
TAP_LOG="$PREFIX/tap.log"
if ! "$BIN" tap "$TAP" >"$TAP_LOG" 2>&1; then
  if is_network_blip "$TAP_LOG"; then
    skip "${TAP}: tap registration hit a classified network condition"
    exit 0
  fi
  tail -20 "$TAP_LOG" >&2
  fail "${TAP}: tap registration failed for an unclassified reason"
fi
[[ -f "$DB" ]] || fail "expected DB at $DB after tap"

# --- Seed the tap keg impossibly old, learn the real upstream version -----
sqlite3 "$DB" "INSERT INTO kegs (name, full_name, version, revision, tap, store_sha256, cellar_path) \
  VALUES ('${NAME}', '${TAP}/${NAME}', '0.0.0', 0, '${TAP}', 'sha', '${PREFIX}/Cellar/${NAME}/0.0.0');"

PROBE_LOG="$PREFIX/probe.log"
PROBE_JSON=$("$BIN" outdated --json 2>"$PROBE_LOG" || true)
if is_network_blip "$PROBE_LOG"; then
  skip "outdated probe hit a classified network condition"
  exit 0
fi
# Extract the tap keg's upstream `latest` from the outdated JSON.
V=$(printf '%s' "$PROBE_JSON" |
  grep -oE "\"name\":\"${NAME}\"[^}]*\"latest\":\"[^\"]*\"" |
  grep -oE '"latest":"[^"]*"' | head -1 | sed 's/.*:"//; s/"$//')
[[ -n "$V" ]] || {
  skip "could not learn ${NAME} upstream version from outdated (tap shape changed?)"
  exit 0
}

# --- Reseed the tap keg current (installed == upstream) -------------------
sqlite3 "$DB" "UPDATE kegs SET version='${V}' WHERE name='${NAME}';"

# --- Seed a core keg that is genuinely outdated (offline via API cache) ----
sqlite3 "$DB" "INSERT INTO kegs (name, full_name, version, store_sha256, cellar_path) \
  VALUES ('${CORE}', '${CORE}', '1.0', 'seedsha', '${PREFIX}/Cellar/${CORE}/1.0');"
printf '{"name":"%s","versions":{"stable":"2.0"}}' "$CORE" >"$API/formula_${CORE}.json"

# --- Force the tap HEAD to look moved -------------------------------------
# Bogus cached sha so the real HEAD differs; stale etag so the conditional
# GET returns 200 (a fresh real sha) instead of 304 (which would fall back
# to the bogus cached sha and read as unchanged).
sqlite3 "$DB" "UPDATE taps SET commit_sha='0000000000000000000000000000000000000000', head_etag='W/\"stale-force-200\"' WHERE name='${TAP}';"

# --- The run under test ---------------------------------------------------
rm -f "$SNAP"
UP_LOG="$PREFIX/upgrade.log"
"$BIN" upgrade --dry-run >"$UP_LOG" 2>&1 || true
if is_network_blip "$UP_LOG"; then
  skip "upgrade --dry-run hit a classified network condition"
  exit 0
fi

# Invariant 1: the tap keg did not taint the warm — a snapshot was written.
[[ -f "$SNAP" ]] ||
  fail "dry-run warmed no snapshot: a version-current tap keg still taints the whole warm"
pass "dry-run warmed a snapshot despite a sha-only tap move"

# Invariant 2: the genuinely-outdated core keg made it into the warm.
grep -q "\"name\":\"${CORE}\"" "$SNAP" ||
  fail "warmed snapshot dropped the outdated core keg ${CORE}; got: $(cat "$SNAP")"
pass "warmed snapshot covers the outdated core keg ${CORE}"

# Invariant 3: the version-current tap keg is NOT over-reported in the warm.
grep -q "\"name\":\"${NAME}\"" "$SNAP" &&
  fail "warmed snapshot over-reports the sha-only-moved tap keg ${NAME} (installed==${V})"
pass "warmed snapshot omits the version-current tap keg ${NAME}"

# Invariant 4: version-truth outdated also omits the tap keg.
OUT_JSON=$("$BIN" outdated --json 2>/dev/null || true)
printf '%s' "$OUT_JSON" | grep -q "\"name\":\"${NAME}\"" &&
  fail "outdated over-reports the sha-only-moved tap keg ${NAME}"
pass "outdated omits the version-current tap keg ${NAME}"

printf '\n\xe2\x9c\x94 tap-formula snapshot-warm regression passed\n'
