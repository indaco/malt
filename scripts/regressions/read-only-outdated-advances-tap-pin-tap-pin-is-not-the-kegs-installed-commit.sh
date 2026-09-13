#!/usr/bin/env bash
# Regression: `mt outdated` is read-only and must leave the tap pin (commit_sha
# AND head_etag) exactly as it found it. The pin is the upgrade gate's
# "installed at" proxy, so a read-only check that advances it to HEAD makes the
# next `mt upgrade <name>` print "already at latest tap commit" and exit 0 with
# the keg still at the old version.
#
# Usage: scripts/regressions/read-only-outdated-advances-tap-pin-tap-pin-is-not-the-kegs-installed-commit.sh
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

# MALT_PREFIX must be <= 13 bytes (Mach-O in-place patching budget).
PREFIX=$(mktemp -d /tmp/mt.XXX)
export MALT_PREFIX="$PREFIX"
export NO_COLOR=1
export MALT_NO_EMOJI=1
export MALT_GITHUB_TOKEN="${MALT_GITHUB_TOKEN:-$(gh auth token 2>/dev/null || true)}"
unset MALT_OFFLINE MALT_OUTDATED_MAX_AGE CI
trap 'rm -rf "$PREFIX"' EXIT

pass() { printf '  \xe2\x9c\x93 %s\n' "$*"; }
skip() { printf '  \xe2\x8a\x98 SKIP: %s\n' "$*"; }
fail() {
  printf '  \xe2\x9c\x97 %s\n' "$*" >&2
  exit 1
}

is_network_blip() { grep -qE "rate limit|Network failure|Could not resolve|timed out" "$1"; }

# A stable third-party tap whose formula malt is known to fetch + parse.
TAP="aeroxy/tap"
NAME="ast-outline"
STALE_SHA="0000000000000000000000000000000000000000"

TAP_LOG="$PREFIX/tap.log"
if ! "$BIN" tap "$TAP" >"$TAP_LOG" 2>&1; then
  if is_network_blip "$TAP_LOG"; then
    skip "${TAP}: tap registration hit a classified network condition"
    exit 0
  fi
  tail -20 "$TAP_LOG" >&2
  fail "${TAP}: tap registration failed for an unclassified reason"
fi

# `mt list` bootstraps the schema; the keg row is seeded directly so no real
# install (and no Cellar contents) is needed.
DB="$PREFIX/db/malt.db"
"$BIN" list >/dev/null 2>&1 || true
[[ -f "$DB" ]] || fail "expected DB at $DB after tap + list"
sqlite3 "$DB" "INSERT INTO kegs (name, full_name, version, tap, store_sha256, cellar_path)
  VALUES ('${NAME}','${TAP}/${NAME}','0.0.0','${TAP}','sha-old','${PREFIX}/Cellar/${NAME}/0.0.0');"

# The write under test only fires when the host returns an ETag; `mt tap` just
# stored one, so prove the host does before rewinding or the run is vacuous.
[[ -n $(sqlite3 "$DB" "SELECT IFNULL(head_etag,'') FROM taps WHERE name='${TAP}';") ]] ||
  fail "${TAP}: host returned no ETag; the write path cannot be exercised"

# Stale sha stands in for "upstream moved after install"; NULL etag forces the
# 200 branch, the only one that can write.
sqlite3 "$DB" "UPDATE taps SET commit_sha='${STALE_SHA}', head_etag=NULL WHERE name='${TAP}';"
pass "${TAP}: seeded a tap-owned keg with a stale pin (sha rewound, etag cleared)"

OUTDATED_LOG="$PREFIX/outdated.log"
printf '\xe2\x96\xb8 mt outdated (read-only, logs \xe2\x86\x92 %s)\n' "$OUTDATED_LOG"
"$BIN" outdated >"$OUTDATED_LOG" 2>&1 || true
if is_network_blip "$OUTDATED_LOG"; then
  skip "outdated hit a classified network condition; cannot exercise the resolve"
  exit 0
fi
grep -q "$NAME" "$OUTDATED_LOG" || {
  tail -20 "$OUTDATED_LOG" >&2
  fail "${NAME}: outdated did not list the seeded keg (fixture broken)"
}
pass "${NAME}: outdated listed the seeded keg"

# The invariant: a read-only command leaves the pin exactly as it found it.
ROW=$(sqlite3 "$DB" "SELECT IFNULL(commit_sha,'')||'|'||IFNULL(head_etag,'') FROM taps WHERE name='${TAP}';")
[[ "$ROW" == "${STALE_SHA}|" ]] ||
  fail "${TAP}: read-only outdated advanced the tap row to '${ROW}' (expected '${STALE_SHA}|')"
pass "${TAP}: pin survived outdated (sha and etag both untouched)"

# The observable: the upgrade that follows must re-attempt, not report success.
# Its install leg may fail; only the absence of the skip line is asserted.
UPGRADE_LOG="$PREFIX/upgrade.log"
printf '\xe2\x96\xb8 mt upgrade %s (logs \xe2\x86\x92 %s)\n' "$NAME" "$UPGRADE_LOG"
"$BIN" upgrade "$NAME" >"$UPGRADE_LOG" 2>&1 || true
if is_network_blip "$UPGRADE_LOG"; then
  skip "upgrade hit a classified network condition; cannot assert the re-attempt"
  exit 0
fi
line=$(grep 'already at latest tap commit' "$UPGRADE_LOG") && fail "${NAME}: upgrade short-circuited: $line"
pass "${NAME}: upgrade re-attempted after a read-only check"

printf '\n\xe2\x9c\x94 read-only outdated leaves the tap pin alone regression passed\n'
