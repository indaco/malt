#!/usr/bin/env bash
# Regression: a tap-formula `mt upgrade` whose install leg fails must leave the
# tap pin (commit_sha AND head_etag) at its pre-upgrade value, so the very next
# `mt upgrade <name>` re-attempts instead of printing "already at latest tap
# commit" and exiting 0 with the keg still at the old version.
#
# Usage: scripts/regressions/failed-tap-upgrade-reports-already-at-latest-commit.sh
# Requirements: built malt at $MALT_BIN or zig-out/bin/malt; sqlite3 on PATH;
# network access to the tap HEAD + its `.rb` + tarball.

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
# The Cellar is made read-only mid-run; restore it before the wipe.
trap 'chmod -R u+w "$PREFIX" 2>/dev/null || true; rm -rf "$PREFIX"' EXIT

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

# Stale sha so the gate does not fire; NULL etag forces the 200 branch, so run 1
# stamps a real etag and a sha-only restore (retry 304s, reads current) fails.
sqlite3 "$DB" "UPDATE taps SET commit_sha='${STALE_SHA}', head_etag=NULL WHERE name='${TAP}';"
pass "${TAP}: seeded a tap-owned keg with a stale pin (sha rewound, etag cleared)"

# Inject the install failure after the pin write: Cellar/<name> must not exist
# yet, so the read-only Cellar makes its creation fail.
mkdir -p "$PREFIX/Cellar"
chmod 500 "$PREFIX/Cellar"

RUN1_LOG="$PREFIX/upgrade_run1.log"
printf '\xe2\x96\xb8 mt upgrade %s (install leg sabotaged, logs \xe2\x86\x92 %s)\n' "$NAME" "$RUN1_LOG"
set +e
"$BIN" upgrade "$NAME" >"$RUN1_LOG" 2>&1
run1_exit=$?
set -e
chmod 755 "$PREFIX/Cellar"

if is_network_blip "$RUN1_LOG"; then
  skip "run 1 hit a classified network condition; cannot exercise the failure path"
  exit 0
fi
[[ $run1_exit -ne 0 ]] || {
  tail -20 "$RUN1_LOG" >&2
  fail "${NAME}: install leg unexpectedly succeeded against a read-only Cellar"
}
grep -q "Failed to upgrade tap formula" "$RUN1_LOG" || {
  tail -20 "$RUN1_LOG" >&2
  fail "${NAME}: run 1 failed before the install leg"
}
pass "${NAME}: run 1 failed in the install leg (exit ${run1_exit})"

# The invariant: a failed upgrade leaves the pin exactly as it found it.
ROW=$(sqlite3 "$DB" "SELECT IFNULL(commit_sha,'')||'|'||IFNULL(head_etag,'') FROM taps WHERE name='${TAP}';")
[[ "$ROW" == "${STALE_SHA}|" ]] ||
  fail "${TAP}: tap row advanced to '${ROW}' after a failed upgrade (expected '${STALE_SHA}|')"
pass "${TAP}: pin survived the failed run (sha and etag both untouched)"

# The observable: the retry must re-attempt, not report success.
RUN2_LOG="$PREFIX/upgrade_run2.log"
printf '\xe2\x96\xb8 mt upgrade %s (retry, logs \xe2\x86\x92 %s)\n' "$NAME" "$RUN2_LOG"
"$BIN" upgrade "$NAME" >"$RUN2_LOG" 2>&1 || true
if is_network_blip "$RUN2_LOG"; then
  skip "run 2 hit a classified network condition; cannot assert the retry"
  exit 0
fi
line=$(grep 'already at latest tap commit' "$RUN2_LOG") && fail "${NAME}: retry short-circuited: $line"
pass "${NAME}: retry re-attempted the upgrade"

printf '\n\xe2\x9c\x94 failed tap upgrade retry regression passed\n'
