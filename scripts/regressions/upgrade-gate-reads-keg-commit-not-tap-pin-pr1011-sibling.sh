#!/usr/bin/env bash
# Regression: the tap-formula upgrade gate must compare HEAD against the
# commit the KEG was installed from, not against the per-tap pin. Every pin
# writer (`mt upgrade <sibling>`, `mt tap <slug>` re-run, `mt tap --refresh`)
# advances the pin to HEAD without reinstalling the other kegs of that tap,
# so a gate that reads the pin prints "already at latest tap commit" for a keg
# that is still behind and exits 0 with the old version in place.
#
# Usage: scripts/regressions/upgrade-gate-reads-keg-commit-not-tap-pin-pr1011-sibling.sh
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

# `mt tap` on a fresh prefix pins HEAD - exactly the state a sibling upgrade
# or a tap re-run leaves the rest of the tap in.
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

HEAD_SHA=$(sqlite3 "$DB" "SELECT IFNULL(commit_sha,'') FROM taps WHERE name='${TAP}';")
[[ ${#HEAD_SHA} -eq 40 ]] || fail "${TAP}: tap registration did not pin a sha (fixture broken)"

sqlite3 "$DB" "INSERT INTO kegs (name, full_name, version, tap, store_sha256, cellar_path)
  VALUES ('${NAME}','${TAP}/${NAME}','0.0.0','${TAP}','sha-old','${PREFIX}/Cellar/${NAME}/0.0.0');"
# The invariant under test: the keg's own commit, not the tap pin, is what the
# gate reads. Before the column existed this UPDATE has nothing to write and
# the gate falls back to the pin (== HEAD); the skip line below is the tell.
sqlite3 "$DB" "UPDATE kegs SET tap_commit_sha='${STALE_SHA}' WHERE name='${NAME}';" 2>/dev/null || true
pass "${TAP}: seeded tap pin at HEAD (${HEAD_SHA:0:8}) with ${NAME} installed-from ${STALE_SHA:0:8}"

# The observable: the upgrade must re-attempt, not report success. Its install
# leg may fail; only the absence of the skip line is asserted.
UPGRADE_LOG="$PREFIX/upgrade.log"
printf '\xe2\x96\xb8 mt upgrade %s (logs \xe2\x86\x92 %s)\n' "$NAME" "$UPGRADE_LOG"
"$BIN" upgrade "$NAME" >"$UPGRADE_LOG" 2>&1 || true
if is_network_blip "$UPGRADE_LOG"; then
  skip "upgrade hit a classified network condition; cannot assert the re-attempt"
  exit 0
fi
line=$(grep 'already at latest tap commit' "$UPGRADE_LOG") && fail "${NAME}: gate read the tap pin, not the keg: $line"
# Positive witness that the gate let the upgrade through: the tap resolve is
# the first thing the install leg prints, before anything that can fail.
grep -q "Resolving tap ${TAP}/${NAME}" "$UPGRADE_LOG" || {
  tail -20 "$UPGRADE_LOG" >&2
  fail "${NAME}: upgrade never reached the install leg"
}
pass "${NAME}: upgrade re-attempted a keg behind the tap pin"

printf '\n\xe2\x9c\x94 upgrade gate reads the keg commit, not the tap pin regression passed\n'
