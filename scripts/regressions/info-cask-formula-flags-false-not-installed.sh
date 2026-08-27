#!/usr/bin/env bash
# Regression: `mt info --cask --formula <pkg>` must report an installed
# package as installed. The two kind-flags are inclusive selectors
# (mirroring `search`): passing both reads the same as passing neither.
# When they were modelled as exclusion guards, both-set suppressed every
# lookup and a present package printed "not installed".
#
# Hermetic: a seeded keg row in a throwaway prefix, MALT_OFFLINE=1 so the
# local-lookup hit is the only thing under test — no live Homebrew metadata.
#
# Usage: scripts/regressions/info-cask-formula-flags-false-not-installed.sh
# Requirements: built `malt` at $MALT_BIN or zig-out/bin/malt, sqlite3 on PATH.

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

PREFIX=$(mktemp -d /tmp/mt.XXX)
export MALT_PREFIX="$PREFIX"
export NO_COLOR=1
export MALT_NO_EMOJI=1
export MALT_OFFLINE=1
mkdir -p "$PREFIX/db"
trap 'rm -rf "$PREFIX"' EXIT

pass() { printf '  \xe2\x9c\x93 %s\n' "$*"; }
fail() {
  printf '  \xe2\x9c\x97 %s\n' "$*" >&2
  exit 1
}

DB="$PREFIX/db/malt.db"

# Bootstrap schema by letting malt open the DB once.
"$BIN" list --quiet >/dev/null 2>&1 || true
[[ -f "$DB" ]] || fail "DB was not initialised by mt list"

sqlite3 "$DB" <<SQL
INSERT INTO kegs (name, full_name, version, revision, store_sha256, cellar_path, install_reason)
VALUES ('wget', 'wget', '1.24.5', 0, 'sha_cur', '$PREFIX/Cellar/wget/1.24.5', 'direct');
SQL
mkdir -p "$PREFIX/Cellar/wget/1.24.5"

# 1. Both kind-flags set: the installed record, not "not installed".
BOTH_OUT="$PREFIX/both.out"
"$BIN" info --cask --formula wget >"$BOTH_OUT" 2>&1 ||
  fail "mt info --cask --formula wget exited non-zero (see $BOTH_OUT)"
grep -q 'not installed' "$BOTH_OUT" &&
  fail "both flags reported an installed package as not installed (see $BOTH_OUT)"
grep -q '^wget:' "$BOTH_OUT" ||
  fail "both flags did not emit the installed record header (see $BOTH_OUT)"
pass "mt info --cask --formula <pkg> shows the installed record"

# 2. Both kind-flags --json: installed:true root for the present package.
BOTH_JSON="$PREFIX/both.json"
"$BIN" --json info --cask --formula wget >"$BOTH_JSON" 2>&1 ||
  fail "mt --json info --cask --formula wget exited non-zero (see $BOTH_JSON)"
grep -q '"installed":true' "$BOTH_JSON" ||
  fail "both flags --json did not emit installed:true (see $BOTH_JSON)"
pass "mt info --cask --formula <pkg> --json pins installed:true"

# 3. Single-flag paths still narrow correctly.
"$BIN" info --formula wget | grep -q '^wget:' ||
  fail "--formula regressed: installed formula no longer shown"
pass "mt info --formula <pkg> still resolves the installed formula"

printf '\n\xe2\x9c\x94 info both-kind-flags regression passed\n'
