#!/usr/bin/env bash
# Regression: `mt upgrade <a> <b>` must process every named package, not
# just the first positional.
#
# The TUI Outdated tab builds `mt upgrade <name1> <name2> ...` for a
# select-all batch. A CLI defect kept only the first positional and
# silently dropped the rest, so a bulk upgrade touched exactly one
# package and the others reappeared as still-outdated on the next refetch.
#
# This proves both names reach the per-package upgrade path without any
# network. Two synthetic core kegs are seeded and a `.404` cache marker
# is planted for each, so every lookup fails offline with a deterministic
# "Could not fetch formula info for <name>" line. The pre-fix CLI emits
# that line for the first name only; the fixed CLI emits it for both.
# Asserting the SECOND name's error surfaces is exactly the
# dropped-positional signal.
#
# Usage: scripts/regressions/upgrade-multi-package-args.sh
# Requirements: built malt at $MALT_BIN or zig-out/bin/malt, sqlite3.

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
PREFIX="/tmp/mt_umpkg"
export MALT_PREFIX="$PREFIX"
export NO_COLOR=1
export MALT_NO_EMOJI=1
rm -rf "$PREFIX"
mkdir -p "$PREFIX"
trap 'rm -rf "$PREFIX"' EXIT

pass() { printf '  \xe2\x9c\x93 %s\n' "$*"; }
fail() {
  printf '  \xe2\x9c\x97 %s\n' "$*" >&2
  exit 1
}

# Bootstrap the schema the same way malt does: a `list` call opens and
# initialises the DB on a fresh prefix.
mkdir -p "$PREFIX/db"
"$BIN" list >/dev/null 2>&1 || true
DB="$PREFIX/db/malt.db"
[[ -f "$DB" ]] || fail "expected DB at $DB after a list call"

FIRST="wget"
SECOND="ffmpeg"

# Seed two core kegs (empty tap → core-API path, not tap routing).
sqlite3 "$DB" <<SQL || fail "could not seed kegs"
INSERT INTO kegs (name, full_name, version, revision, store_sha256, cellar_path, install_reason)
VALUES ('$FIRST', '$FIRST', '1', 0, '', '/c/$FIRST/1', 'direct'),
       ('$SECOND', '$SECOND', '1', 0, '', '/c/$SECOND/1', 'direct');
SQL

# Plant 404 markers so each lookup fails network-free with a stable line.
mkdir -p "$PREFIX/cache/api"
: >"$PREFIX/cache/api/formula_$FIRST.404"
: >"$PREFIX/cache/api/formula_$SECOND.404"

# The exact argv shape the TUI Outdated tab builds for a 2-row select-all.
LOG="$PREFIX/upgrade.log"
printf '\xe2\x96\xb8 mt upgrade %s %s (offline, expect both to be probed)\n' "$FIRST" "$SECOND"
"$BIN" upgrade "$FIRST" "$SECOND" >"$LOG" 2>&1 || true

# Sanity: the first positional is always processed.
grep -q "Could not fetch formula info for $FIRST" "$LOG" || {
  cat "$LOG" >&2
  fail "first package was not processed — harness is broken"
}
pass "first package processed"

# The defect: the second positional is silently dropped. Its error line
# appears only when every name reaches the per-package upgrade path.
grep -q "Could not fetch formula info for $SECOND" "$LOG" || {
  cat "$LOG" >&2
  fail "second package dropped — only the first positional was honored"
}
pass "second package processed"

printf '\n\xe2\x9c\x94 upgrade-multi-package-args regression passed\n'
